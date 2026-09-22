#!/usr/bin/env bash
# islet.dev.sh [name] [workspace] — config-driven dev runner.
#
# Arguments are detected by type (order-free):
#   - an existing directory => the workspace
#   - anything else         => the agent name from config.json
#
# The agent's `preinstall` dependencies are baked into a per-agent derived
# image (built once, cached), and `environment` vars from the config are
# passed to the container on every run — so both survive container rebuilds.

set -Eeuo pipefail

ISLET_CONFIG_DIR="${ISLET_CONFIG_DIR:-${HOME}/.config/islet}"
ISLET_CONFIG="${ISLET_CONFIG_DIR}/config.json"
OPENCODE_IMAGE="ghcr.io/anomalyco/opencode:latest"
BASE_CONFIG_DIR="${HOME}/.config/opencode"

die() {
  echo "Error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."
}

require_cmd docker
require_cmd jq

WORKSPACE=""
AGENT_NAME=""

# --- Argument type detection (order-free) ------------------------------------
if (($#)); then
  for arg in "$@"; do
    if [[ "$arg" == -* ]]; then
      die "unknown option: $arg (no subcommands; usage: $0 [name] [workspace])"
    elif [[ -d "$arg" ]]; then
      WORKSPACE="$arg"
    elif [[ -z "$AGENT_NAME" ]]; then
      AGENT_NAME="$arg"
    else
      die "unexpected argument: $arg"
    fi
  done
fi
WORKSPACE="${WORKSPACE:-$PWD}"
WORKSPACE="$(cd "$WORKSPACE" && pwd)"

# --- Load config --------------------------------------------------------------
if [[ ! -s "$ISLET_CONFIG" ]]; then
  die "config not found at $ISLET_CONFIG — run install.sh first."
fi

AGENT_KEY=""
if [[ -n "$AGENT_NAME" ]] \
  && jq -e --arg n "$AGENT_NAME" '.agent[$n] != null' "$ISLET_CONFIG" >/dev/null; then
  AGENT_KEY="$AGENT_NAME"
else
  # Fall back to the configured default agent, if it exists.
  DEFAULT_AGENT="$(jq -r '.container // empty' "$ISLET_CONFIG")"
  if [[ -n "$DEFAULT_AGENT" ]] \
    && jq -e --arg n "$DEFAULT_AGENT" '.agent[$n] != null' "$ISLET_CONFIG" >/dev/null; then
    AGENT_KEY="$DEFAULT_AGENT"
  else
    die "agent '${AGENT_NAME:-$DEFAULT_AGENT}' not found in $ISLET_CONFIG"
  fi
fi

CFG_IMAGE="$(jq -r --arg k "$AGENT_KEY" '.agent[$k].image // ""' "$ISLET_CONFIG")"
CFG_CONTAINER_NAME="$(jq -r --arg k "$AGENT_KEY" '.agent[$k].container_name // ""' "$ISLET_CONFIG")"
CFG_NETWORK="$(jq -r --arg k "$AGENT_KEY" '.agent[$k].network // "host"' "$ISLET_CONFIG")"
CFG_AGENT_CONFIG_DIR="$(jq -r --arg k "$AGENT_KEY" '.agent[$k].agent_config_dir // ""' "$ISLET_CONFIG")"
CFG_AGENT_CONFIG_MOUNT="$(jq -r --arg k "$AGENT_KEY" '.agent[$k].agent_config_mount // ""' "$ISLET_CONFIG")"
mapfile -t CFG_PORTS < <(jq -r --arg k "$AGENT_KEY" '.agent[$k].ports[]?' "$ISLET_CONFIG")
mapfile -t CFG_PREINSTALL < <(jq -r --arg k "$AGENT_KEY" '.agent[$k].preinstall[]?' "$ISLET_CONFIG")

IMAGE="${CFG_IMAGE:-$OPENCODE_IMAGE}"
CONFIG_DIR="${CFG_AGENT_CONFIG_DIR/#\~/$HOME}"
CONFIG_DIR="${CONFIG_DIR:-$BASE_CONFIG_DIR}"
CONFIG_MOUNT="${CFG_AGENT_CONFIG_MOUNT:-/root/.config/opencode}"
CONTAINER_NAME="${CFG_CONTAINER_NAME:-}"

mkdir -p "$CONFIG_DIR"

echo "Agent:     $AGENT_KEY"
echo "Workspace: $WORKSPACE"

# --- Bake preinstalled dependencies into a derived image -------------------------
# Image tag: islet-pre:<agent>-<hash(base image + dep list)>. Docker caches it,
# so it is only rebuilt when the dep list or the base image changes — and the
# installed dependencies stay in place after every container rebuild.
build_preinstall_image() {
  local pkg hash tag depkey
  local -a pkgs=() npm_pkgs=()
  for pkg in "${CFG_PREINSTALL[@]}"; do
    case "$pkg" in
      Node.js) pkgs+=(nodejs npm) ;;
      Go)      pkgs+=(golang-go) ;;
      Java)    pkgs+=(default-jdk) ;;
      Python)  pkgs+=(python3 python3-pip) ;;
      Rust)    pkgs+=(rustc cargo) ;;
      Ruby)    pkgs+=(ruby) ;;
      C/C++)   pkgs+=(build-essential) ;;
      Pi)      npm_pkgs+=('@earendil-works/pi-coding-agent') ;;
      *)       echo "Warning: unknown preinstall dep '$pkg' — skipped." >&2 ;;
    esac
  done
  if ((${#pkgs[@]} == 0 && ${#npm_pkgs[@]} == 0)); then
    printf '%s' "$IMAGE"
    return 0
  fi

  depkey="$(printf '%s|%s' "$IMAGE" "${CFG_PREINSTALL[*]}" | sha256sum | cut -c1-10)"
  tag="islet-pre:${AGENT_KEY}-${depkey}"

  if docker image inspect "$tag" >/dev/null 2>&1; then
    echo "Using preinstalled image: $tag (cached)" >&2
    printf '%s' "$tag"
    return 0
  fi

  echo "Building preinstalled image: $tag" >&2
  {
    printf 'FROM %s\n' "$IMAGE"
    if ((${#pkgs[@]} > 0)); then
      printf 'RUN apt-get update && apt-get install -y --no-install-recommends'
      for pkg in "${pkgs[@]}"; do
        printf ' %s' "$pkg"
      done
      printf ' \\\n  && rm -rf /var/lib/apt/lists/*\n'
    fi
    if ((${#npm_pkgs[@]} > 0)); then
      printf 'RUN npm install -g --ignore-scripts'
      for pkg in "${npm_pkgs[@]}"; do
        printf ' %s' "$pkg"
      done
      printf '\n'
    fi
  } | docker build -t "$tag" -f - . >/dev/null

  printf '%s' "$tag"
}

if ((${#CFG_PREINSTALL[@]})); then
  new_image="$(build_preinstall_image)"
  IMAGE="$new_image"
fi

# --- docker run arguments --------------------------------------------------------
CMD=(docker run --rm -it --workdir /workspace --volume "$WORKSPACE:/workspace")

if [[ -n "$CONTAINER_NAME" ]]; then
  CMD+=(--name "$CONTAINER_NAME")
fi

case "$CFG_NETWORK" in
  bridge)
    CMD+=(--network bridge)
    for p in "${CFG_PORTS[@]}"; do
      CMD+=(-p "$p")
    done
    ;;
  *) CMD+=(--network host) ;;
esac

CMD+=(--volume "$CONFIG_DIR:$CONFIG_MOUNT")

# Environment variables from the config — applied on every container run.
while IFS=$'\t' read -r k v; do
  [[ -n "$k" ]] && CMD+=(-e "$k=$v")
done < <(jq -r --arg k "$AGENT_KEY" \
  '.agent[$k].environment // {} | to_entries[] | .key + "\t" + (.value|tostring)' \
  "$ISLET_CONFIG")

CMD+=("$IMAGE")
exec "${CMD[@]}"

#!/usr/bin/env bash
set -Eeuo pipefail

# islet-dev.sh — development version of islet.
# Runs an AI agent harness in an isolated Docker container.
# Currently supports opencode; more agents will be added in the future.
#
# The config file is created by install.sh.

SCRIPT_NAME="$(basename "$0")"

ISLET_CONFIG_DIR="${ISLET_CONFIG_DIR:-${HOME}/.config/islet}"
ISLET_CONFIG="${ISLET_CONFIG_DIR}/config.json"

# Colors (only when stdout is a terminal).
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_CYAN=''
fi

die() {
  printf '%sError:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."
}

print_help() {
  cat <<EOF
islet (dev) — run AI agents in isolated Docker containers

Usage:
  $SCRIPT_NAME [name] [workspace]   Run an agent from config
  $SCRIPT_NAME ps                   List running islet containers
  $SCRIPT_NAME rm [name]            Remove an agent, or uninstall islet
  $SCRIPT_NAME --help               Show this help message

Arguments:
  name        agent name (default: the "container" from config)
  workspace   directory to mount at /workspace (default: current dir)
  Arguments are detected by type: an existing directory is the
  workspace, anything else is the agent name. Order-free.

Config:
  ~/.config/islet/config.json — agent definitions (image, network, ports, ...)
  Created by install.sh.
  Override the location with the ISLET_CONFIG_DIR environment variable.

Sessions:
  Agent sessions and auth are stored in the agent data dir on the host
  (default ~/.local/share/opencode) and mounted into the container, so
  they persist across runs even though the container itself is removed
  on exit (--rm). Resume a previous session from the agent's session
  list the next time you run it in the same workspace.

Examples:
  $SCRIPT_NAME                       # default agent, current directory
  $SCRIPT_NAME .                     # same as above
  $SCRIPT_NAME opencode ~/project    # "opencode" agent, ~/project mounted
  $SCRIPT_NAME rm opencode           # remove the "opencode" agent entry
  $SCRIPT_NAME rm                    # uninstall: remove config + islet command
EOF
}

cfg_get() {
  jq -r "$@" "$ISLET_CONFIG"
}

# run_ps — list running containers of agents configured in config.json.
run_ps() {
  require_cmd jq
  [[ -f "$ISLET_CONFIG" ]] \
    || die "config not found: $ISLET_CONFIG — run 'install.sh' first"

  local -a names=()
  mapfile -t names < <(
    cfg_get '.agent // {} | to_entries[]
             | (.value.container_name // "" | select(length > 0) // .key)'
  )

  # docker ps --filter name= accepts a regex; match our containers precisely.
  if ((${#names[@]} > 0)); then
    local regex="^($(IFS='|'; echo "${names[*]}"))\$"
    docker ps --filter "name=$regex" \
      --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
  else
    docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
  fi
}

# run_rm [name] — remove things islet has installed.
#   rm <name> — delete only that agent's piece from config.json
#   rm        — clean everything: the config, and the islet command(s)
#               installed into ~/.local/bin
run_rm() {
  local name="${1:-}"

  if [[ -n "$name" ]]; then
    # --- remove a single agent entry ---------------------------------------
    require_cmd jq
    [[ -f "$ISLET_CONFIG" ]] \
      || die "config not found: $ISLET_CONFIG — run 'install.sh' first"

    if ! jq -e --arg b "$name" '.agent | has($b)' "$ISLET_CONFIG" >/dev/null; then
      local available
      available="$(cfg_get '.agent // {} | keys | join(", ")')"
      die "unknown agent: $name (available: $available)"
    fi

    local tmp="${ISLET_CONFIG}.tmp"
    jq --arg b "$name" '
      .agent |= delpaths([[$b]])
      | if (.agent // {}) == {} then del(."$schema", .container, .agent) else . end
    ' "$ISLET_CONFIG" > "$tmp" && mv "$tmp" "$ISLET_CONFIG"
    printf '%s✔ Agent %s%s%s removed from %s%s\n' \
      "$C_GREEN" "$C_BOLD" "$name" "$C_RESET" "$ISLET_CONFIG" "$C_RESET"
    return 0
  fi

  # --- full uninstall ------------------------------------------------------
  require_cmd jq
  local ans
  printf '%sRemove the islet config and the installed islet command? (y/N)%s ' \
    "$C_YELLOW" "$C_RESET" >&2
  read -r ans || ans=''
  if [[ ! "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    echo 'Aborted.'
    return 0
  fi

  # Remove the whole config folder (config.json included).
  if [[ -f "$ISLET_CONFIG" ]]; then
    rm -f "$ISLET_CONFIG"
    rmdir "$ISLET_CONFIG_DIR" 2>/dev/null || true
  fi

  # Clean all islet commands from ~/.local/bin.
  local bin_dir="${HOME}/.local/bin"
  local cmd
  for cmd in islet islet-dev; do
    if [[ -f "$bin_dir/$cmd" || -L "$bin_dir/$cmd" ]]; then
      rm -f "$bin_dir/$cmd"
      printf '  removed %s\n' "$bin_dir/$cmd" >&2
    fi
  done

  printf '%s✔ islet uninstalled%s\n' "$C_GREEN" "$C_RESET"
  return 0
}

run_agent() {
  local name='' workspace=''

  # Flexible arguments: an existing directory is the workspace,
  # anything else is treated as an agent name. Order doesn't matter.
  local arg
  for arg in "$@"; do
    if [[ -d "$arg" ]]; then
      [[ -z "$workspace" ]] || die "multiple workspaces given: '$workspace' and '$arg'"
      workspace="$arg"
    else
      [[ -z "$name" ]] || die "multiple agent names given: '$name' and '$arg'"
      name="$arg"
    fi
  done
  workspace="${workspace:-$PWD}"

  require_cmd jq
  [[ -f "$ISLET_CONFIG" ]] \
    || die "config not found: $ISLET_CONFIG — run 'install.sh' first"

  jq -e '."$schema" and .agent' "$ISLET_CONFIG" >/dev/null \
    || die "invalid config format: $ISLET_CONFIG — run 'install.sh' to recreate it"

  # Resolve agent name: argument, or the default container from config.
  if [[ -z "$name" ]]; then
    name="$(cfg_get '.container // empty')"
    [[ -n "$name" ]] || die "no default container set in $ISLET_CONFIG"
  fi

  if ! jq -e --arg b "$name" '.agent | has($b)' "$ISLET_CONFIG" >/dev/null; then
    local available
    available="$(cfg_get '.agent | keys | join(", ")')"
    die "unknown agent: $name (available: $available)"
  fi

  local image container_name network agent_config_dir agent_config_mount
  local agent_data_dir agent_data_mount
  image="$(cfg_get --arg b "$name" '.agent[$b].image')"
  container_name="$(cfg_get --arg b "$name" '.agent[$b].container_name // ""')"
  network="$(cfg_get --arg b "$name" '.agent[$b].network // "host"')"
  agent_config_dir="$(cfg_get --arg b "$name" '.agent[$b].agent_config_dir')"
  agent_config_mount="$(cfg_get --arg b "$name" '.agent[$b].agent_config_mount')"
  # Sessions and auth live in the agent's data dir — mount it so they
  # survive the ephemeral (--rm) container.
  agent_data_dir="$(cfg_get --arg b "$name" '.agent[$b].agent_data_dir // "~/.local/share/opencode"')"
  agent_data_mount="$(cfg_get --arg b "$name" '.agent[$b].agent_data_mount // "/root/.local/share/opencode"')"

  # Expand a leading ~ in host-side paths.
  agent_config_dir="${agent_config_dir/#\~/$HOME}"
  agent_data_dir="${agent_data_dir/#\~/$HOME}"

  [[ -d "$workspace" ]] || die "workspace directory does not exist: $workspace"
  workspace="$(cd "$workspace" && pwd)"
  mkdir -p "$agent_config_dir" "$agent_data_dir"

  require_cmd docker

  # Build the docker command line.
  local -a docker_args=(run --rm -it)
  if [[ -n "$container_name" ]]; then
    docker_args+=(--name "$container_name")
  fi

  if [[ "$network" == 'host' ]]; then
    docker_args+=(--network host)
  else
    local port
    while IFS= read -r port; do
      docker_args+=(--publish "$port")
    done < <(cfg_get --arg b "$name" '.agent[$b].ports // [] | .[]')
  fi

  local env_pair
  while IFS= read -r env_pair; do
    docker_args+=(--env "$env_pair")
  done < <(cfg_get --arg b "$name" '.agent[$b].environment // {} | to_entries[] | "\(.key)=\(.value)"')

  docker_args+=(
    --workdir /workspace
    --volume "$workspace:/workspace"
    --volume "$agent_config_dir:$agent_config_mount"
    --volume "$agent_data_dir:$agent_data_mount"
    "$image"
  )

  echo "Agent:     $name"
  echo "Image:     $image"
  echo "Workspace: $workspace"

  exec docker "${docker_args[@]}"
}

main() {
  case "${1:-}" in
    -h|--help|help)
      print_help
      ;;
    ps)
      shift
      run_ps "$@"
      ;;
    rm)
      shift
      run_rm "$@"
      ;;
    *)
      run_agent "$@"
      ;;
  esac
}

main "$@"

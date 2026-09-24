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

# Default image used by `islet setup`.
OPENCODE_IMAGE_DEFAULT='ghcr.io/anomalyco/opencode:latest'

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
  $SCRIPT_NAME create [file]        Create a Dockerfile (agent + preinstall env)
  $SCRIPT_NAME build [file]         Build an agent image from a Dockerfile
  $SCRIPT_NAME setup                Add a new agent entry to config.json
  $SCRIPT_NAME [name] [workspace]   Run an agent from config
  $SCRIPT_NAME ps                   List running islet containers
  $SCRIPT_NAME rm [name]            Remove an agent, or uninstall islet
  $SCRIPT_NAME --help               Show this help message

setup:
  Five steps, each with a default (agent name, image, agent config volume,
  network, environment); the entry is merged into config.json.
  Then build it and add the image to config.json:
    $SCRIPT_NAME create opencode.Dockerfile
    $SCRIPT_NAME build opencode.Dockerfile
  (see README "Adding an agent to config.json")

build:
  docker build -t islet/<agent>:latest -f <file> <dir>

Run:
  name        agent name (default: the "container" from config)
  workspace   directory to mount at /workspace (default: current dir);
              arguments are order-free
  Volumes persisted across runs (from config.json):
    volume_libs    — installed libs (apk cache)
    volume_config  — agent config, default ~/.config/<agent-name>
    Sessions/auth are saved to ~/.local/share/islet/<agent-name>-sessions
    on the host (override with "volume_sessions" in config.json) and
    mounted at /root/.local/share/<agent-name>, so they survive --rm runs.

Examples:
  $SCRIPT_NAME create my.dockerfile  # generate a Dockerfile
  $SCRIPT_NAME build my.dockerfile   # docker build
  $SCRIPT_NAME                       # default agent, current directory
  $SCRIPT_NAME opencode ~/project    # run the "opencode" agent
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
  mapfile -t names < <(cfg_get '.agent // {} | to_entries[] | .key')

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

  local image volume_libs volume_config volume_sessions network
  local container_name=''
  image="$(cfg_get --arg b "$name" '.agent[$b].image')"
  network="$(cfg_get --arg b "$name" '.agent[$b].network // "host"')"
  # Volume for installed libs (apk cache) — one dir per agent, shared across
  # runs so downloaded packages/libs survive container and docker restarts.
  volume_libs="$(cfg_get --arg b "$name" '.agent[$b].volume_libs // ""')"
  volume_libs="${volume_libs:-${HOME}/.local/share/islet/${name}-libs}"
  # Volume for agent's own config (~/.config/<agent-name> by default).
  volume_config="$(cfg_get --arg b "$name" '.agent[$b].volume_config // ""')"
  volume_config="${volume_config:-${HOME}/.config/${name}}"
  # Volume for saved sessions/auth (the agent's data dir, e.g. opencode's
  # .local/share/opencode) — persists across --rm container runs.
  volume_sessions="$(cfg_get --arg b "$name" '.agent[$b].volume_sessions // ""')"
  volume_sessions="${volume_sessions:-${HOME}/.local/share/islet/${name}-sessions}"
  volume_libs="${volume_libs/#\~/$HOME}"
  volume_config="${volume_config/#\~/$HOME}"
  volume_sessions="${volume_sessions/#\~/$HOME}"

  [[ -d "$workspace" ]] || die "workspace directory does not exist: $workspace"
  workspace="$(cd "$workspace" && pwd)"
  mkdir -p "$volume_libs" "$volume_config" "$volume_sessions"

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
    --volume "$volume_config:/root/.config/${name}"
    --volume "$volume_sessions:/root/.local/share/${name}"
    --volume "$volume_libs:/var/cache/apk"
    "$image"
  )

  echo "Agent:     $name"
  echo "Image:     $image"
  echo "Workspace: $workspace"

  exec docker "${docker_args[@]}"
}

# ask [prompt] [default] — prompt on stderr, one line from stdin.
ask() {
  local prompt="$1" default="${2:-}" input
  if [[ -n "$default" ]]; then
    printf '%s [%s]: ' "$prompt" "$default" >&2
  else
    printf '%s: ' "$prompt" >&2
  fi
  read -r input || input=''
  printf '%s' "${input:-$default}"
}

# ui_box — boxed TUI header, same style as install.sh.
hr() {
  local s
  printf -v s '%*s' "$1" ''
  printf '%s' "${s// /─}"
}

ui_box() {
  local w=0 l
  for l in "$@"; do
    if ((${#l} > w)); then w=${#l}; fi
  done
  printf '%s╭%s╮%s\n' "$C_CYAN" "$(hr $((w + 4)))" "$C_RESET"
  for l in "$@"; do
    printf '%s│%s  %-*s  %s│%s\n' "$C_CYAN" "$C_RESET" "$w" "$l" "$C_CYAN" "$C_RESET"
  done
  printf '%s╰%s╯%s\n' "$C_CYAN" "$(hr $((w + 4)))" "$C_RESET"
}

# step_header <num> <title> — boxed header for the setup wizard steps (1-5).
step_header() {
  printf '\n'
  ui_box "setup - step $1/5" "$2"
}

# dep_icon <dep> — icon shown for each preinstall environment entry.
dep_icon() {
  case "$1" in
    Node.js) printf '⬢' ;;
    Go)      printf '🐹' ;;
    Java)    printf '☕' ;;
    Python)  printf '🐍' ;;
    Rust)    printf '🦀' ;;
    Ruby)    printf '💎' ;;
    C/C++)   printf '🔧' ;;
    *)       printf '•' ;;
  esac
}

# multichoice <out-array> <item>... — interactive multi-select list
# (↑/↓ or j/k move, Tab/Space toggle, Enter confirm). When stdin or stderr
# is not a TTY this falls back to numbered toggles: one line per exchange,
# space-separated numbers toggle items, an empty line confirms.
multichoice() {
  local -n _out=$1; shift
  local items=("$@")
  local -a state=()
  local i n input cur=0 key
  for ((i = 0; i < ${#items[@]}; i++)); do state[i]=0; done

  if [[ -t 0 && -t 2 ]]; then
    # --- interactive TUI ---------------------------------------------------
    printf '%s↑/↓ move · Tab select · Enter confirm%s\n' "$C_DIM" "$C_RESET" >&2
    printf '\033[?25l' >&2   # hide cursor
    trap 'printf "\033[?25h" >&2; exit 130' INT

    while true; do
      for ((i = 0; i < ${#items[@]}; i++)); do
        local mark=' ' pointer=' ' line
        if ((state[i])); then mark='x'; fi
        if ((i == cur)); then pointer='❯'; fi
        printf -v line '%s [%s] %s %s' \
          "$pointer" "$mark" "$(dep_icon "${items[i]}")" "${items[i]}"
        if ((i == cur)); then
          printf '\r\033[2K%s%s%s\n' "$C_CYAN" "$line" "$C_RESET" >&2
        else
          printf '\r\033[2K%s\n' "$line" >&2
        fi
      done

      IFS= read -rsn1 key || key=''
      if [[ "$key" == $'\x1b' ]]; then
        local k2='' k3=''
        IFS= read -rsn1 -t 0.05 k2 || true
        IFS= read -rsn1 -t 0.05 k3 || true
        case "$k2$k3" in
          '[A') key='up' ;;
          '[B') key='down' ;;
          *)    key='ignore' ;;
        esac
      fi
      case "$key" in
        up|k)      cur=$(( (cur - 1 + ${#items[@]}) % ${#items[@]} )) ;;
        down|j)    cur=$(( (cur + 1) % ${#items[@]} )) ;;
        $'\t'|' ') state[cur]=$((1 - state[cur])) ;;
        ''|$'\r')  break ;;   # Enter
      esac
      printf '\033[%dA' "${#items[@]}" >&2   # move cursor up to redraw
    done

    printf '\033[?25h' >&2   # show cursor
    trap - INT
  else
    # --- plain fallback (piped stdin, CI) ----------------------------------
    while true; do
      for ((i = 0; i < ${#items[@]}; i++)); do
        if ((state[i])); then
          printf '  %s%d) [x] %s %s%s\n' \
            "$C_GREEN" $((i + 1)) "$(dep_icon "${items[i]}")" "${items[i]}" "$C_RESET"
        else
          printf '  %s%d) [ ] %s %s%s\n' \
            "$C_DIM" $((i + 1)) "$(dep_icon "${items[i]}")" "${items[i]}" "$C_RESET"
        fi
      done
      printf 'Toggle numbers (space-separated), Enter to confirm: ' >&2
      read -r input || input=''
      [[ -z "$input" ]] && break
      for n in $input; do
        if [[ "$n" =~ ^[0-9]+$ ]] && ((n >= 1 && n <= ${#items[@]})); then
          state[$((n - 1))]=$((1 - state[n - 1]))
        fi
      done
      printf '\n' >&2
    done
  fi

  _out=()
  for ((i = 0; i < ${#items[@]}; i++)); do
    if ((state[i])); then
      _out+=("${items[i]}")
    fi
  done
  return 0
}

# preinstall_pkgs <dep>... — maps preinstall environment items to the
# Alpine package names baked into the generated Dockerfile.
preinstall_pkgs() {
  local out='' dep
  for dep in "$@"; do
    case "$dep" in
      Node.js) out+=' nodejs npm' ;;
      Go)      out+=' go' ;;
      Java)    out+=' openjdk17' ;;
      Python)  out+=' python3' ;;
      Rust)    out+=' cargo rust' ;;
      Ruby)    out+=' ruby' ;;
      C/C++)   out+=' build-base' ;;
      Git)     out+=' git' ;;
    esac
  done
  printf '%s' "${out# }"
}

# dockerfile_for <agent> [extra-apk-packages] — print a Dockerfile for the
# supported agents (Alpine base: opencode and hermes runtime installs, pi on
# node:24-alpine). Selected preinstall deps are baked in as apk packages, so
# the environment survives every container restart.
dockerfile_for() {
  local extra_pkgs
  extra_pkgs="$(preinstall_pkgs "${@:2}")"

  case "$agent" in
    opencode)
      cat <<EOF
# opencode agent harness — Alpine, runtime setup baked at build time.
FROM alpine:latest

RUN apk add --no-cache \\
      bash curl wget jq tar unzip git ripgrep ca-certificates tzdata${extra_pkgs:+ \\
      $extra_pkgs}

# Install the opencode binary.
# SHELL must be set — the installer expands ${SHELL:?} (unset under busybox).
ENV SHELL=/bin/sh
RUN curl -fsSL https://opencode.ai/install | sh
ENV PATH="/root/.opencode/bin:\${PATH}"

RUN mkdir -p /workspace /root/.config/opencode
WORKDIR /workspace

ENTRYPOINT ["opencode"]
EOF
      ;;
    pi)
      cat <<EOF
# pi coding agent — Alpine, Node.js runtime.
FROM node:24-alpine

RUN apk add --no-cache bash ca-certificates git ripgrep${extra_pkgs:+ $extra_pkgs}

RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent

RUN mkdir -p /workspace /root/.config/pi
WORKDIR /workspace

ENTRYPOINT ["pi"]
EOF
      ;;
    hermes)
      cat <<EOF
# hermes agent harness (Nous Research) — Alpine, runtime install.
FROM alpine:latest

RUN apk add --no-cache \\
      bash curl wget jq tar unzip git ripgrep ca-certificates tzdata${extra_pkgs:+ \\
      $extra_pkgs}

RUN curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
ENV PATH="/root/.hermes/bin:\${PATH}"

RUN mkdir -p /workspace /root/.config/hermes
WORKDIR /workspace

ENTRYPOINT ["hermes"]
EOF
      ;;
    *) die "unsupported agent: $agent (supported: opencode, pi, hermes)" ;;
  esac
}

# run_create [file] — two interactive steps:
#   1. choose the agent (pi/opencode/hermes)
#   2. multi-select the preinstall environment (Git, Node.js, Go, Java,
#      Python, Rust, Ruby, C/C++) — baked into the image as apk packages,
#      so the environment survives every container restart.
#   The Dockerfile is written to the given location: <file> is treated as
#   a directory -> <dir>/<agent>.Dockerfile, or a filename -> used as-is.
run_create() {
  local target="${1:-}"

  local agent
  printf '%s==>%s Create Dockerfile\n' "$C_BOLD" "$C_RESET"

  printf '%sStep 1: agent%s\n' "$C_BOLD" "$C_RESET" >&2
  printf '  %s1)%s opencode\n' "$C_GREEN" "$C_RESET"
  printf '  %s2)%s pi\n' "$C_GREEN" "$C_RESET"
  printf '  %s3)%s hermes\n' "$C_GREEN" "$C_RESET"
  local choice
  choice="$(ask 'Select agent' '1')"
  case "$choice" in
    1) agent='opencode' ;;
    2) agent='pi' ;;
    3) agent='hermes' ;;
    *) die "invalid choice: $choice" ;;
  esac

  printf '%sStep 2: preinstall environment%s\n' "$C_BOLD" "$C_RESET" >&2
  local -a preinstall=()
  multichoice preinstall 'Git' 'Node.js' 'Go' 'Java' 'Python' 'Rust' 'Ruby' 'C/C++'

  local file="$target"
  if [[ -z "$file" ]]; then
    file="./${agent}.Dockerfile"
  elif [[ -d "$file" ]]; then
    file="${file%/}/${agent}.Dockerfile"
  elif [[ ! "$file" =~ /[^/]+$ || "$file" =~ /$ ]]; then
    die "invalid path: $target"
  fi

  mkdir -p "$(cd "$(dirname "$file")" && pwd)"
  dockerfile_for "$agent" "${preinstall[@]}" > "$file"
  printf '%s✔ Dockerfile written to %s%s\n' "$C_GREEN" "$file" "$C_RESET"
  ((${#preinstall[@]})) && printf '  preinstall: %s\n' "${preinstall[*]}"
  printf '  next: %s build %s\n' "$SCRIPT_NAME" "$file"
  return 0
}

# run_build [file] — docker build the given Dockerfile and tag the image
# after the Dockerfile name (without .Dockerfile suffix): islet/<agent>:last.
run_build() {
  local file="${1:-}"
  [[ -n "$file" ]] || die "usage: $SCRIPT_NAME build <path-to-Dockerfile>"
  [[ -f "$file" ]] || die "Dockerfile not found: $file"

  require_cmd docker

  local agent tag dir
  agent="$(basename "$file")"
  agent="${agent%.Dockerfile}"
  agent="${agent%.dockerfile}"
  tag="islet/${agent}:latest"
  dir="$(cd "$(dirname "$file")" && pwd)"

  docker build -t "$tag" -f "$(cd "$dir" && realpath "$file")" "$dir"
  printf '%s✔ Image built: %s%s%s\n' "$C_GREEN" "$C_BOLD" "$tag" "$C_RESET"
}

# run_setup — interactive wizard adding a new agent entry into config.json:
#   step 1: agent name           (default: agent)
#   step 2: image                (default: ghcr.io/anomalyco/opencode:latest)
#   step 3: agent config volume  (default: ~/.config/<agent-name>)
#   step 4: network              (default: host)
#   step 5: environment          (KEY=VALUE,KEY=VALUE; default: none)
# volume_libs defaults to ~/.local/share/islet/<agent-name>-libs; ports []
# unless edited by hand (see README).
run_setup() {
  require_cmd jq

  step_header 1 'Agent name'
  local name
  name="$(ask 'Agent name' 'agent')"

  step_header 2 'Image'
  local image
  image="$(ask 'Docker image' "$OPENCODE_IMAGE_DEFAULT")"

  step_header 3 'Agent config volume'
  local volume_config
  volume_config="$(ask 'Agent config volume' "~/.config/$name")"

  step_header 4 'Network'
  printf '  %s1)%s host (default)\n' "$C_GREEN" "$C_RESET"
  printf '  %s2)%s bridge (publish ports in config.json)\n' "$C_YELLOW" "$C_RESET"
  local network
  printf -v network '%s' "$(ask 'Select' '1')"
  case "$network" in
    2) network='bridge' ;;
    *) network='host' ;;
  esac

  step_header 5 'Environment variables'
  local -a env_pairs=()
  local env_input
  while true; do
    env_input="$(ask 'Environment variables (KEY=VALUE,KEY=VALUE — empty to skip)')"
    [[ -z "$env_input" ]] && break
    if [[ "$env_input" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^,]*(,[A-Za-z_][A-Za-z0-9_]*=[^,]*)*$ ]]; then
      IFS=',' read -r -a env_pairs <<< "$env_input"
      break
    fi
    printf '%sInvalid format. Example: API_KEY=secret,FOO=bar%s\n' "$C_RED" "$C_RESET" >&2
  done

  # --- save into config.json (merge; sibling agents are kept) --------------
  mkdir -p "$(dirname "$ISLET_CONFIG")"
  [[ -f "$ISLET_CONFIG" ]] || jq -n '{"$schema": "islet.sh"}' > "$ISLET_CONFIG"
  local env_json volume_libs
  if ((${#env_pairs[@]} > 0)); then
    env_json="$(printf '%s\n' "${env_pairs[@]}" \
      | jq -R 'split("=") | {(.[0]): .[1]}' | jq -s 'add // {}')"
  else
    env_json='{}'
  fi
  volume_libs="~/.local/share/islet/${name}-libs"

  local agent_json
  agent_json="$(jq -n \
    --arg image "$image" \
    --arg volume_libs "$volume_libs" \
    --arg volume_config "$volume_config" \
    --arg network "$network" \
    --argjson ports '[]' \
    --argjson environment "$env_json" \
    '{
      image: $image,
      volume_libs: $volume_libs,
      volume_config: $volume_config,
      network: $network,
      ports: $ports,
      environment: $environment
    }')"

  local merge_filter='
    .agent = ((.agent // {}) + {($key): $agent})
    | ."$schema" = (."$schema" // "islet.sh")
    | .container = (.container // $key)
  '
  local tmp_json="${ISLET_CONFIG}.tmp"
  jq --arg key "$name" --argjson agent "$agent_json" \
     "$merge_filter" "$ISLET_CONFIG" > "$tmp_json" \
    || die "invalid config format: $ISLET_CONFIG"
  mv "$tmp_json" "$ISLET_CONFIG"

  printf '%s✔ Agent %s%s%s saved to %s%s\n' \
    "$C_GREEN" "$C_BOLD" "$name" "$C_RESET" "$ISLET_CONFIG" "$C_RESET"
  printf '  run it now: %s %s <workspace>%s\n' "$C_BOLD" "$name" "$C_RESET"
  return 0
}

main() {
  case "${1:-}" in
    -h|--help|help)
      print_help
      ;;
    create)
      shift
      run_create "$@"
      ;;
    build)
      shift
      run_build "$@"
      ;;
    setup)
      shift
      run_setup "$@"
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

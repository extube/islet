#!/usr/bin/env bash
set -Eeuo pipefail

# islet-dev.sh — development version of islet.
# Universal runner for AI agent harnesses in isolated Docker containers.
# Currently supports opencode; more agents will be added in the future.

SCRIPT_NAME="$(basename "$0")"

ISLET_CONFIG_DIR="${ISLET_CONFIG_DIR:-${HOME}/.config/islet}"
ISLET_CONFIG="${ISLET_CONFIG_DIR}/config.json"

OPENCODE_IMAGE="ghcr.io/anomalyco/opencode:latest"
OPENCODE_CONFIG_MOUNT="/root/.config/opencode"

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
  $SCRIPT_NAME                        Show this help message
  $SCRIPT_NAME init                   Interactive initialization wizard
  $SCRIPT_NAME run [name] [workspace] Run an agent from config

Commands:
  init        Interactive setup: config folder, preinstalled environment,
              agent config folder, container name, network, env variables.
              Saves everything to the config file.
  run         Run an agent defined in the config.
              name      agent name (default: the "container" from config)
              workspace directory to mount at /workspace (default: current dir)
              Arguments are detected by type: an existing directory is the
              workspace, anything else is the agent name. Order-free.

Config:
  ~/.config/islet/config.json — agent definitions (image, network, ports, ...)
  Override the location with the ISLET_CONFIG_DIR environment variable.

Examples:
  $SCRIPT_NAME init
  $SCRIPT_NAME run                       # default agent, current directory
  $SCRIPT_NAME run .                     # same as above
  $SCRIPT_NAME run opencode ~/project    # "opencode" agent, ~/project mounted
EOF
}

cfg_get() {
  jq -r "$@" "$ISLET_CONFIG"
}

# ask <prompt> [default] — prints the answer (or default) to stdout.
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

# checklist <result_array> <item>... — toggle items by number, Enter to confirm.
checklist() {
  local -n _out=$1; shift
  local items=("$@")
  local -a state=()
  local i n input
  for ((i = 0; i < ${#items[@]}; i++)); do state[i]=0; done

  while true; do
    for ((i = 0; i < ${#items[@]}; i++)); do
      if ((state[i])); then
        printf '  %s%d) [x] %s%s\n' "$C_GREEN" $((i + 1)) "${items[i]}" "$C_RESET"
      else
        printf '  %s%d) [ ] %s%s\n' "$C_DIM" $((i + 1)) "${items[i]}" "$C_RESET"
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

  _out=()
  for ((i = 0; i < ${#items[@]}; i++)); do
    if ((state[i])); then
      _out+=("${items[i]}")
    fi
  done
  return 0
}

# json_array <string>... — prints a JSON array of the arguments.
json_array() {
  if (($#)); then
    printf '%s\n' "$@" | jq -R . | jq -s .
  else
    printf '[]'
  fi
}

# json_env <KEY=VALUE>... — prints a JSON object built from KEY=VALUE pairs.
json_env() {
  if (($#)); then
    printf '%s\n' "$@" \
      | jq -R 'capture("^(?<key>[^=]+)=(?<value>.*)$") | {(.key): .value}' \
      | jq -s 'add'
  else
    printf '{}'
  fi
}

cmd_init() {
  require_cmd jq

  printf '%s%s=== islet initialization ===%s\n\n' "$C_BOLD" "$C_CYAN" "$C_RESET"

  # --- Step 1: config folder location -------------------------------------
  printf '%sStep 1/6:%s config folder\n' "$C_BOLD" "$C_RESET"
  local config_dir
  config_dir="$(ask 'Config folder' "$ISLET_CONFIG_DIR")"
  ISLET_CONFIG_DIR="${config_dir/#\~/$HOME}"
  ISLET_CONFIG="${ISLET_CONFIG_DIR}/config.json"
  mkdir -p "$ISLET_CONFIG_DIR"

  if [[ -f "$ISLET_CONFIG" ]]; then
    local overwrite
    overwrite="$(ask "Config already exists at $ISLET_CONFIG — overwrite? (y/N)" 'N')"
    if [[ ! "$overwrite" =~ ^[Yy]([Ee][Ss])?$ ]]; then
      echo 'Aborted.'
      return 0
    fi
  fi

  # --- Step 2: preinstalled environment ------------------------------------
  printf '\n%sStep 2/6:%s preinstalled environment\n' "$C_BOLD" "$C_RESET"
  local -a preinstall=()
  checklist preinstall 'Node.js' 'Go' 'Java'

  # --- Step 3: opencode config folder --------------------------------------
  printf '\n%sStep 3/6:%s opencode config folder\n' "$C_BOLD" "$C_RESET"
  local agent_config_dir
  agent_config_dir="$(ask 'opencode config folder' '~/.config/opencode')"

  # --- Step 4: container name ----------------------------------------------
  printf '\n%sStep 4/6:%s container name\n' "$C_BOLD" "$C_RESET"
  local container_name=''
  while true; do
    container_name="$(ask 'Container name (empty for random)')"
    if [[ -z "$container_name" || "$container_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
      break
    fi
    printf '%sInvalid name. Use letters, digits, "_", ".", "-" (must start with a letter or digit).%s\n' \
      "$C_RED" "$C_RESET" >&2
  done

  # --- Step 5: network ------------------------------------------------------
  printf '\n%sStep 5/6:%s network\n' "$C_BOLD" "$C_RESET"
  printf '  %s1)%s host (default)\n' "$C_GREEN" "$C_RESET"
  printf '  %s2)%s port routing (publish ports)\n' "$C_YELLOW" "$C_RESET"
  local network='host'
  local -a ports=()
  local net_choice ports_input
  net_choice="$(ask 'Select' '1')"
  if [[ "$net_choice" == '2' ]]; then
    network='bridge'
    while true; do
      ports_input="$(ask 'Ports (<port>:<port>,<port>:<port>,...)')"
      if [[ "$ports_input" =~ ^[0-9]+:[0-9]+(,[0-9]+:[0-9]+)*$ ]]; then
        IFS=',' read -r -a ports <<< "$ports_input"
        break
      fi
      printf '%sInvalid format. Example: 8080:8080,3000:3000%s\n' "$C_RED" "$C_RESET" >&2
    done
  fi

  # --- Step 6: environment variables ----------------------------------------
  printf '\n%sStep 6/6:%s environment variables\n' "$C_BOLD" "$C_RESET"
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

  # --- Save ------------------------------------------------------------------
  local agent_key="${container_name:-opencode}"
  local ports_json env_json preinstall_json
  ports_json="$(json_array "${ports[@]}")"
  env_json="$(json_env "${env_pairs[@]}")"
  preinstall_json="$(json_array "${preinstall[@]}")"

  jq -n \
    --arg container "$agent_key" \
    --arg image "$OPENCODE_IMAGE" \
    --arg container_name "$container_name" \
    --arg network "$network" \
    --argjson ports "$ports_json" \
    --argjson environment "$env_json" \
    --argjson preinstall "$preinstall_json" \
    --arg agent_config_dir "$agent_config_dir" \
    --arg agent_config_mount "$OPENCODE_CONFIG_MOUNT" \
    '{
      "$schema": "islet.sh",
      container: $container,
      agent: {
        ($container): {
          image: $image,
          container_name: $container_name,
          network: $network,
          ports: $ports,
          environment: $environment,
          preinstall: $preinstall,
          agent_config_dir: $agent_config_dir,
          agent_config_mount: $agent_config_mount
        }
      }
    }' > "$ISLET_CONFIG"

  printf '\n%s✔ Configuration saved to %s%s\n\n' "$C_GREEN" "$ISLET_CONFIG" "$C_RESET"
  printf '  %s run <workdir>   %s\n' "$SCRIPT_NAME" '# run agent in this folder'
  printf '  %s --help          %s\n' "$SCRIPT_NAME" '# for help'
}

cmd_run() {
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
    || die "config not found: $ISLET_CONFIG — run '$SCRIPT_NAME init' first"

  jq -e '."$schema" and .agent' "$ISLET_CONFIG" >/dev/null \
    || die "invalid config format: $ISLET_CONFIG — run '$SCRIPT_NAME init' to recreate it"

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
  image="$(cfg_get --arg b "$name" '.agent[$b].image')"
  container_name="$(cfg_get --arg b "$name" '.agent[$b].container_name // ""')"
  network="$(cfg_get --arg b "$name" '.agent[$b].network // "host"')"
  agent_config_dir="$(cfg_get --arg b "$name" '.agent[$b].agent_config_dir')"
  agent_config_mount="$(cfg_get --arg b "$name" '.agent[$b].agent_config_mount')"

  # Expand a leading ~ in host-side paths.
  agent_config_dir="${agent_config_dir/#\~/$HOME}"

  [[ -d "$workspace" ]] || die "workspace directory does not exist: $workspace"
  workspace="$(cd "$workspace" && pwd)"
  mkdir -p "$agent_config_dir"

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
    "$image"
  )

  echo "Agent:     $name"
  echo "Image:     $image"
  echo "Workspace: $workspace"

  exec docker "${docker_args[@]}"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    ""|-h|--help|help)
      print_help
      ;;
    init)
      shift
      cmd_init "$@"
      ;;
    run)
      shift
      cmd_run "$@"
      ;;
    *)
      die "unknown command: $cmd (run '$SCRIPT_NAME' for help)"
      ;;
  esac
}

main "$@"

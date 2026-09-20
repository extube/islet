#!/usr/bin/env bash
# install.sh — islet installer.
#
#   curl -fsSL https://raw.githubusercontent.com/extube/islet/main/install.sh | sh
#
# Interactive TUI wizard that checks requirements (docker, jq) and creates
# the islet config file used by islet-dev.sh to run AI agent harnesses
# in Docker containers.

# --- POSIX re-exec shim (must stay POSIX; runs when piped into a shell) ------
# With `curl ... | sh` stdin carries the script itself, so the wizard cannot
# read answers from it — and `sh` may not be bash. Re-run from a real file
# with bash, reading answers from the terminal (/dev/tty).
if [ -z "${BASH_VERSION:-}" ] && [ -f "${0:-}" ]; then
  # `sh install.sh` — rerun the same file with bash, keep stdin.
  exec bash "$0" "$@"
fi
if [ ! -f "${0:-}" ]; then
  # Piped (e.g. `curl ... | sh`): the script occupies stdin, so download
  # a fresh copy of self and run it with bash on the terminal.
  _islet_url="${ISLET_INSTALL_URL:-https://raw.githubusercontent.com/extube/islet/main/install.sh}"
  _islet_tmp="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/islet-install.$$")"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$_islet_url" -o "$_islet_tmp" \
      || { echo "islet: download failed: $_islet_url" >&2; exit 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$_islet_tmp" "$_islet_url" \
      || { echo "islet: download failed: $_islet_url" >&2; exit 1; }
  else
    echo "islet: curl or wget is required to install when piping." >&2
    echo "islet: or download install.sh and run it with bash directly." >&2
    exit 1
  fi
  if (exec 3</dev/tty) 2>/dev/null; then
    ISLET_SCRIPT_TMP="$_islet_tmp" ISLET_SCRIPT_NAME="install.sh" \
      exec bash "$_islet_tmp" "$@" </dev/tty
  else
    ISLET_SCRIPT_TMP="$_islet_tmp" ISLET_SCRIPT_NAME="install.sh" \
      exec bash "$_islet_tmp" "$@" </dev/null
  fi
fi

set -Eeuo pipefail

SCRIPT_NAME="${ISLET_SCRIPT_NAME:-$(basename "$0")}"

# Remove the temp copy created by the re-exec shim above.
if [[ -n "${ISLET_SCRIPT_TMP:-}" ]]; then
  trap 'rm -f "$ISLET_SCRIPT_TMP"' EXIT
fi

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
islet installer — interactive TUI setup wizard

Usage:
  curl -fsSL https://raw.githubusercontent.com/extube/islet/main/install.sh | sh
  $SCRIPT_NAME            Run the setup wizard
  $SCRIPT_NAME --help     Show this help message

The installer:
  0. Checks requirements: docker (warns if missing), jq (required)
  1. Config folder (default: ~/.config/islet)
  2. Preinstalled environment — multi-select with icons
     (↑/↓ move, Tab/Space select, Enter confirm)
  3. opencode config folder (default: ~/.config/opencode)
  4. Container name (empty = random)
  5. Network: host, or port routing (<port>:<port>,<port>:<port>)
  6. Environment variables (KEY=VALUE,KEY=VALUE)

Everything is saved to the config file:
  ~/.config/islet/config.json

Environment variables:
  ISLET_CONFIG_DIR    override the config folder location
  ISLET_INSTALL_URL   override the URL used to re-download the script
                      when it is piped into a shell

After installation, run an agent with:
  islet-dev.sh [name] [workspace]
EOF
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

# hr <width> — prints <width> box-drawing dashes.
hr() {
  local s
  printf -v s '%*s' "$1" ''
  printf '%s' "${s// /─}"
}

# ui_box <line>... — draws a rounded box around the lines.
# Lines must be ASCII-only so padding is counted correctly.
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

# step_header <num> <title> — boxed TUI header for a wizard step.
step_header() {
  printf '\n'
  ui_box "islet installer - step $1/6" "$2"
}

# dep_icon <name> — prints the icon for a dependency.
dep_icon() {
  case "$1" in
    Node.js) printf '⬢' ;;
    Go)      printf '🐹' ;;
    Java)    printf '☕' ;;
    *)       printf '•' ;;
  esac
}

# multichoice <result_array> <item>... — multi-select list.
# TTY:  ↑/↓ (or j/k) move, Tab/Space toggle, Enter confirm.
# Pipe: toggle by numbers (space-separated), Enter confirm.
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

# check_requirements — jq is required, docker is strongly recommended.
check_requirements() {
  require_cmd jq

  printf '%s==>%s Checking requirements\n' "$C_BOLD" "$C_RESET"
  printf '  %s✔%s jq %s\n' "$C_GREEN" "$C_RESET" "$(jq --version 2>/dev/null || echo unknown)"

  if command -v docker >/dev/null 2>&1; then
    local docker_version
    docker_version="$(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')"
    printf '  %s✔%s docker %s\n' "$C_GREEN" "$C_RESET" "${docker_version:-unknown}"
    return 0
  fi

  printf '  %s✖ docker not found%s\n' "$C_RED" "$C_RESET"
  printf '    islet runs agents in Docker containers - Docker is required to run them.\n'
  printf '    Install Docker: %shttps://docs.docker.com/get-docker/%s\n' "$C_CYAN" "$C_RESET"
  local cont
  cont="$(ask 'Continue installation anyway? (Y/n)' 'Y')"
  if [[ "$cont" =~ ^[Nn]([Oo])?$ ]]; then
    echo 'Aborted.'
    exit 1
  fi
  return 0
}

wizard() {
  printf '\n'
  ui_box 'islet installer' 'AI agents in isolated Docker containers'

  check_requirements

  # --- Step 1: config folder location --------------------------------------
  step_header 1 'Config folder'
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

  # --- Step 2: preinstalled environment -------------------------------------
  step_header 2 'Preinstalled environment'
  local -a preinstall=()
  multichoice preinstall 'Node.js' 'Go' 'Java'

  # --- Step 3: opencode config folder ---------------------------------------
  step_header 3 'opencode config folder'
  local agent_config_dir
  agent_config_dir="$(ask 'opencode config folder' '~/.config/opencode')"

  # --- Step 4: container name ------------------------------------------------
  step_header 4 'Container name'
  local container_name=''
  while true; do
    container_name="$(ask 'Container name (empty for random)')"
    if [[ -z "$container_name" || "$container_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
      break
    fi
    printf '%sInvalid name. Use letters, digits, "_", ".", "-" (must start with a letter or digit).%s\n' \
      "$C_RED" "$C_RESET" >&2
  done

  # --- Step 5: network --------------------------------------------------------
  step_header 5 'Network'
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

  # --- Step 6: environment variables -------------------------------------------
  step_header 6 'Environment variables'
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

  # --- Save ---------------------------------------------------------------------
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
  printf '  %s <workdir>   %s\n' 'islet-dev.sh' '# run agent in this folder'
  printf '  %s --help      %s\n' 'islet-dev.sh' '# for help'
}

main() {
  case "${1:-}" in
    "" )
      wizard
      ;;
    -h|--help|help)
      print_help
      ;;
    *)
      die "unknown argument: $1 (run '$SCRIPT_NAME --help' for help)"
      ;;
  esac
}

main "$@"

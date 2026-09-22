#!/usr/bin/env bash
# install.sh — islet installer.
#
#   curl -fsSL https://raw.githubusercontent.com/extube/islet/main/install.sh | sh
#
# Interactive TUI wizard that checks requirements (docker, jq) and creates
# the islet config file used by islet.sh (islet-dev.sh) to run AI agent
# harnesses in Docker containers.

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

# Source location of install.sh (also used to find/download islet.sh).
SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"

# Flags (set from the command line; a non-empty flag skips its wizard step).
OPT_CONFIG_DIR='' OPT_PREINSTALL='' OPT_IMAGE='' OPT_AGENT_CONFIG_DIR=''
OPT_CONTAINER_NAME='' OPT_NETWORK='' OPT_PORTS='' OPT_ENV=''

OPENCODE_IMAGE="ghcr.io/anomalyco/opencode:latest"
OPENCODE_CONFIG_MOUNT="/root/.config/opencode"

ICON_ISLAND='🏝️'

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
  1. Config folder (default: ~/.config/islet)        --config-dir
  2. Preinstalled environment — multi-select with icons
     (↑/↓ move, Tab/Space select, Enter confirm)     --preinstall
  3. Docker image (default: ghcr.io/anomalyco/opencode:latest,
     or enter a custom image name)                   --image
  4. opencode config folder (default: ~/.config/opencode)
                                                     --agent-config-dir
  5. Container name (empty = random)                 --container-name
  6. Network: host, or port routing                  --network, --ports
     (<port>:<port>,<port>:<port>)
  7. Environment variables (KEY=VALUE,KEY=VALUE)     --env

If a flag is given (non-empty), its step is skipped and the flag value is
saved to the config file. Remaining steps are asked interactively.

Flags:
  --config-dir DIR        config folder
  --preinstall LIST       comma-separated deps (e.g. Node.js,Python,Rust)
  --image IMAGE           the Docker image to run agents in
  --agent-config-dir DIR  agent config folder on the host
  --container-name NAME   Docker container name
  --network MODE          host or bridge
  --ports LIST            comma-separated port mappings, e.g. 8080:8080
  --env LIST              comma-separated KEY=VALUE pairs

Everything is saved to the config file:
  ~/.config/islet/config.json

Environment variables:
  ISLET_CONFIG_DIR    override the config folder location
  ISLET_INSTALL_URL   override the URL used to re-download the script
                      when it is piped into a shell

After installation, run an agent from anywhere:
  islet [name] [workspace]      (installed into ~/.local/bin/islet)
  islet ps                      list running islet containers
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
  ui_box "islet installer - step $1/7" "$2"
}

# print_greeting — welcome box with the islet island icon in the top border.
# The icon is 2 terminal cells wide, so it is placed in the border (where the
# dash count is adjusted for it) instead of inside ui_box's padded lines.
print_greeting() {
  local line1='islet installer'
  local line2='AI agents in isolated Docker containers'
  local w=${#line2}
  printf '\n'
  printf '%s╭─ %s %s╮%s\n' "$C_CYAN" "$ICON_ISLAND" "$(hr $((w - 1)))" "$C_RESET"
  printf '%s│%s  %-*s  %s│%s\n' "$C_CYAN" "$C_RESET" "$w" "$line1" "$C_CYAN" "$C_RESET"
  printf '%s│%s  %-*s  %s│%s\n' "$C_CYAN" "$C_RESET" "$w" "$line2" "$C_CYAN" "$C_RESET"
  printf '%s╰%s╯%s\n' "$C_CYAN" "$(hr $((w + 4)))" "$C_RESET"
}

# dep_icon <name> — prints the icon for a dependency.
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

# install_islet_cmd — put the islet command into ~/.local/bin so it can be
# run from anywhere in the user's home directory: `islet <workdir>`.
install_islet_cmd() {
  local bin_dir="${HOME}/.local/bin"
  local dst="${bin_dir}/islet"
  local src_dir src

  if [[ -f "${SCRIPT_SOURCE}" ]]; then
    src_dir="$(cd -- "$(dirname -- "${SCRIPT_SOURCE}")" && pwd)"
    src="${src_dir}/islet.sh"
  else
    local src_url="${ISLET_INSTALL_URL:-https://raw.githubusercontent.com/extube/islet/main/install.sh}"
    src_dir="${src_url%install.sh}"
    src="${src_url%install.sh}islet.sh"
  fi

  mkdir -p "$bin_dir"

  if [[ -f "$src" ]]; then
    cp -f "$src" "$dst"
  else
    # Src dir does not carry islet.sh (piped install) — download it.
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$src" -o "$dst" \
        || { printf 'Error: failed to download islet.sh from %s\n' "$src" >&2; return 1; }
    elif command -v wget >/dev/null 2>&1; then
      wget -qO "$dst" "$src" \
        || { printf 'Error: failed to download islet.sh from %s\n' "$src" >&2; return 1; }
    else
      printf 'Error: curl or wget required to fetch islet.sh\n' >&2
      return 1
    fi
  fi

  chmod +x "$dst"
  printf '%s✔ islet command installed at %s%s\n' "$C_GREEN" "$dst" "$C_RESET"

  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *)
      printf '%sNote:%s %s is not in PATH — add it: export PATH="%s:$PATH"\n' \
        "$C_YELLOW" "$C_RESET" "$bin_dir" "$bin_dir"
      ;;
  esac
  return 0
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
  print_greeting
  check_requirements

  # --- Step 1: config folder location --------------------------------------
  if [[ -z "$OPT_CONFIG_DIR" ]]; then
    step_header 1 'Config folder'
    local config_dir
    config_dir="$(ask 'Config folder' "$ISLET_CONFIG_DIR")"
    ISLET_CONFIG_DIR="${config_dir/#\~/$HOME}"
    ISLET_CONFIG="${ISLET_CONFIG_DIR}/config.json"
  fi
  mkdir -p "$ISLET_CONFIG_DIR"

  # --- Step 2: preinstalled environment -------------------------------------
  local -a preinstall=()
  if [[ -n "$OPT_PREINSTALL" ]]; then
    IFS=',' read -r -a preinstall <<< "$OPT_PREINSTALL"
  else
    step_header 2 'Preinstalled environment'
    multichoice preinstall 'Node.js' 'Go' 'Java' 'Python' 'Rust' 'Ruby' 'C/C++'
  fi

  # --- Step 3: docker image -------------------------------------------------
  local image="$OPENCODE_IMAGE"
  if [[ -n "$OPT_IMAGE" ]]; then
    image="$OPT_IMAGE"
  else
    step_header 3 'Docker image'
    printf '  %s1)%s default (%s)\n' "$C_GREEN" "$C_RESET" "$OPENCODE_IMAGE"
    printf '  %s2)%s another image (please enter the name explicitly)\n' "$C_YELLOW" "$C_RESET"
    local image_choice
    image_choice="$(ask 'Select' '1')"
    if [[ "$image_choice" == '2' ]]; then
      while true; do
        image="$(ask 'Image (e.g. ghcr.io/owner/agent:tag)')"
        if [[ -n "$image" && ! "$image" =~ \  ]]; then
          break
        fi
        printf '%sInvalid image name.%s\n' "$C_RED" "$C_RESET" >&2
      done
    fi
  fi

  # --- Step 4: opencode config folder ---------------------------------------
  if [[ -n "$OPT_AGENT_CONFIG_DIR" ]]; then
    local agent_config_dir="$OPT_AGENT_CONFIG_DIR"
  else
    step_header 4 'opencode config folder'
    local agent_config_dir
    agent_config_dir="$(ask 'opencode config folder' '~/.config/opencode')"
  fi

  # --- Step 5: container name ------------------------------------------------
  local container_name=''
  if [[ -n "$OPT_CONTAINER_NAME" ]]; then
    container_name="$OPT_CONTAINER_NAME"
  else
    step_header 5 'Container name'
    while true; do
      container_name="$(ask 'Container name (empty for random)')"
      if [[ -z "$container_name" || "$container_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        break
      fi
      printf '%sInvalid name. Use letters, digits, "_", ".", "-" (must start with a letter or digit).%s\n' \
        "$C_RED" "$C_RESET" >&2
    done
  fi

  # --- Step 6: network --------------------------------------------------------
  local network='host'
  local -a ports=()
  local ports_input
  if [[ -n "$OPT_PORTS" ]]; then
    if [[ ! "$OPT_PORTS" =~ ^[0-9]+:[0-9]+(,[0-9]+:[0-9]+)*$ ]]; then
      die "--ports must be <port>:<port>,... (e.g. 8080:8080,3000:3000)"
    fi
    IFS=',' read -r -a ports <<< "$OPT_PORTS"
    network='bridge'
  fi
  if [[ -z "$OPT_NETWORK" ]] && [[ -z "$OPT_PORTS" ]]; then
    step_header 6 'Network'
    printf '  %s1)%s host (default)\n' "$C_GREEN" "$C_RESET"
    printf '  %s2)%s port routing (publish ports)\n' "$C_YELLOW" "$C_RESET"
    local net_choice
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
  elif [[ -n "$OPT_NETWORK" ]]; then
    if [[ "$OPT_NETWORK" != 'host' && "$OPT_NETWORK" != 'bridge' ]]; then
      die "--network must be 'host' or 'bridge'"
    fi
    network="$OPT_NETWORK"
  fi

  # --- Step 7: environment variables -------------------------------------------
  local -a env_pairs=()
  if [[ -n "$OPT_ENV" ]]; then
    if [[ ! "$OPT_ENV" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^,]*(,[A-Za-z_][A-Za-z0-9_]*=[^,]*)*$ ]]; then
      die "--env must be KEY=VALUE,KEY=VALUE (e.g. API_KEY=secret,FOO=bar)"
    fi
    IFS=',' read -r -a env_pairs <<< "$OPT_ENV"
  else
    step_header 7 'Environment variables'
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
  fi

  # --- Save ---------------------------------------------------------------
  # Merge into an existing config instead of overwriting it: add the new
  # agent under its key, replacing only the piece with the same name.
  local agent_key="${container_name:-opencode}"
  local ports_json env_json preinstall_json
  ports_json="$(json_array "${ports[@]}")"
  env_json="$(json_env "${env_pairs[@]}")"
  preinstall_json="$(json_array "${preinstall[@]}")"

  local agent_json
  agent_json="$(jq -n \
    --arg image "$image" \
    --arg container_name "$container_name" \
    --arg network "$network" \
    --argjson ports "$ports_json" \
    --argjson environment "$env_json" \
    --argjson preinstall "$preinstall_json" \
    --arg agent_config_dir "$agent_config_dir" \
    --arg agent_config_mount "$OPENCODE_CONFIG_MOUNT" \
    '{
      image: $image,
      container_name: $container_name,
      network: $network,
      ports: $ports,
      environment: $environment,
      preinstall: $preinstall,
      agent_config_dir: $agent_config_dir,
      agent_config_mount: $agent_config_mount
    }')"

  mkdir -p "$ISLET_CONFIG_DIR"
  local tmp_config="${ISLET_CONFIG}.tmp"
  local merge_filter
  merge_filter='
    .agent = ((.agent // {}) + {($key): $agent})
    | ."$schema" = (."$schema" // "islet.sh")
    | .container = (.container // $key)
  '
  if [[ -f "$ISLET_CONFIG" ]]; then
    jq --arg key "$agent_key" --argjson agent "$agent_json" \
      "$merge_filter" "$ISLET_CONFIG" > "$tmp_config"
  else
    jq -n --arg key "$agent_key" --argjson agent "$agent_json" \
      "$merge_filter" > "$tmp_config"
  fi
  mv "$tmp_config" "$ISLET_CONFIG"

  printf '\n%s✔ Configuration saved to %s%s\n\n' "$C_GREEN" "$ISLET_CONFIG" "$C_RESET"
  install_islet_cmd || true
  printf '  %s <workdir>   %s\n' 'islet'        '# run agent in this folder'
  printf '  %s --help      %s\n' 'islet'        '# for help'
  printf '  %s ps          %s\n' 'islet'        '# list running agents'
}

main() {
  local args=()
  while (($#)); do
    case "$1" in
      --config-dir)        OPT_CONFIG_DIR="${2:?}" ; shift 2 ;;
      --preinstall)        OPT_PREINSTALL="${2:?}" ; shift 2 ;;
      --image)             OPT_IMAGE="${2:?}" ; shift 2 ;;
      --agent-config-dir)  OPT_AGENT_CONFIG_DIR="${2:?}" ; shift 2 ;;
      --container-name)    OPT_CONTAINER_NAME="${2:?}" ; shift 2 ;;
      --network)           OPT_NETWORK="${2:?}" ; shift 2 ;;
      --ports)             OPT_PORTS="${2:?}" ; shift 2 ;;
      --env)               OPT_ENV="${2:?}" ; shift 2 ;;
      --)                  args+=("${@}") ; break ;;
      -h|--help|help)      print_help; return 0 ;;
      -*)                  die "unknown flag: $1 (run '$SCRIPT_NAME --help' for help)" ;;
      *)                   die "unknown argument: $1 (run '$SCRIPT_NAME --help' for help)" ;;
    esac
  done
  wizard
}

main "$@"

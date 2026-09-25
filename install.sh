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

# print_greeting — welcome box with the islet island icon in the top border.
# NOTE: simplified re-implementation (icons adjusted for ASCII box padding).
ICON_ISLAND='🏝️'
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
install_islet_cmd() {
  local bin_dir="${HOME}/.local/bin"
  local dst="${bin_dir}/islet"
  local src=""

  # 1) A local islet.sh copy: proper sibling next to install.sh, or a
  #    local file passed via ISLET_INSTALL_URL.
  local url_path=""
  if [[ -n "${ISLET_INSTALL_URL:-}" ]]; then
    url_path="${ISLET_INSTALL_URL/#\~/$HOME}"
  fi
  if [[ -f "${SCRIPT_SOURCE}" && "$(basename -- "${SCRIPT_SOURCE}")" == 'install.sh' \
       && -f "$(cd -- "$(dirname -- "${SCRIPT_SOURCE}")" && pwd)/islet.sh" ]]; then
    src="$(cd -- "$(dirname -- "${SCRIPT_SOURCE}")" && pwd)/islet.sh"
  elif [[ -f "$url_path" ]]; then
    case "$(basename -- "$url_path")" in
      islet.sh)   src="$url_path" ;;
      install.sh) src="$(dirname -- "$url_path")/islet.sh" ;;
      *)          src="$url_path" ;;
    esac
  fi

  # 2) Otherwise download it next to the configured install URL.
  if [[ -z "$src" ]]; then
    local base="${ISLET_INSTALL_URL:-https://raw.githubusercontent.com/extube/islet/main/install.sh}"
    case "$base" in
      */install.sh) base="${base%install.sh}" ;;
      */islet.sh)   base="${base%islet.sh}" ;;
      */)           ;;                    # a directory-style URL
      *)            base="${base%/}/" ;;  # no filename -> treat as dir
    esac
    src="${base}islet.sh"
  fi

  mkdir -p "$bin_dir"

  if [[ -f "$src" ]]; then
    cp -f "$src" "$dst"
  else
    # Platform-independent download of islet.sh.
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

# ask [prompt] [default] — print the prompt to stderr, read one line from
# stdin; empty input selects the default. Writes the reply to stdout.
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
  printf '    islet builds and runs agent images - Docker is required to run them.\n'
  printf '    Install Docker: %shttps://docs.docker.com/get-docker/%s\n' "$C_CYAN" "$C_RESET"
  local cont
  cont="$(ask 'Continue installation anyway? (Y/n)' 'Y')"
  if [[ "$cont" =~ ^[Nn]([Oo])?$ ]]; then
    echo 'Aborted.'
    exit 1
  fi
  return 0
}

main() {
  # --- flags ------------------------------------------------------------
  local opt_config_dir=''
  while (($#)); do
    case "$1" in
      --config-dir) opt_config_dir="${2:?}" ;;
      -h|--help)
        printf 'Usage: %s [--config-dir <dir>]\n' "$(basename "$0")"
        printf 'Checks requirements, creates the islet config file and installs the\n'
        printf 'islet command into ~/.local/bin.\n'
        exit 0
        ;;
    esac
    shift
  done

  # --- default islet config path ------------------------------------------
  if [[ -n "$opt_config_dir" ]]; then
    ISLET_CONFIG_DIR="${opt_config_dir/#\~/$HOME}"
  else
    print_greeting
    check_requirements
    local config_dir
    config_dir="$(ask 'islet config folder' "$ISLET_CONFIG_DIR")"
    ISLET_CONFIG_DIR="${config_dir/#\~/$HOME}"
  fi
  ISLET_CONFIG="${ISLET_CONFIG_DIR}/config.json"
  mkdir -p "$ISLET_CONFIG_DIR"

  # Create only the islet scaffolding — agent entries live in config.json
  # and are added after a Dockerfile is created and built (see README.md).
  if [[ ! -f "$ISLET_CONFIG" ]]; then
    jq -n '{"$schema": "islet.sh"}' > "$ISLET_CONFIG"
    printf '%s✔ islet config created at %s%s\n' "$C_GREEN" "$ISLET_CONFIG" "$C_RESET"
  else
    printf '  %sconfig found at %s%s — keeping it\n' "$C_DIM" "$ISLET_CONFIG" "$C_RESET"
  fi

  # --- islet command into ~/.local/bin -------------------------------------
  printf '%s==>%s Install islet command\n' "$C_BOLD" "$C_RESET"
  install_islet_cmd || true
  printf '\n  %s create <file> %s\n' 'islet' '# create a Dockerfile (choose an agent)'
  printf '  %s build <file> %s\n' 'islet' '# build the agent image'
  printf '  %s <agent> <ws> %s\n' 'islet' '# run an agent from config'
  printf '  %s ps           %s\n' 'islet' '# list running agents'
}

main "$@"

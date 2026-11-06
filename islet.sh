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

# Default image offered when the setup wizard prompts for one.
OPENCODE_IMAGE_DEFAULT='ghcr.io/anomalyco/opencode:latest'

# Installer source for `islet update` (re-executes install.sh, which
# refreshes the islet command and keeps config.json).
ISLET_INSTALL_URL_DEFAULT='https://raw.githubusercontent.com/extube/islet/main/install.sh'

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
  $SCRIPT_NAME [name] [workspace]   Run an agent (created on demand)
  $SCRIPT_NAME ps                   List running islet containers
  $SCRIPT_NAME mv <old> <new>       Rename an agent (config key + data folder)
  $SCRIPT_NAME update               Refresh the islet command (re-run installer)
  $SCRIPT_NAME rm [name]            Remove an agent, or uninstall islet
  $SCRIPT_NAME --help               Show this help message

Run:
  name        agent name (default: the "container" from config)
  workspace   directory to mount at /workspace (default: current dir);
              arguments are order-free

  Agent aliases opencode / opencode-v2 / opencode2 / pi / hermes: if the
  alias is not in config.json yet, its harness image is built on the fly
  from the factory Dockerfile (then deleted) and the setup wizard runs
  for it — then the agent starts. If <agent> is already configured, it
  just runs.
  Any other name that is not in config.json offers to create the agent
  ("Agent <name> not found. Create new? (y/N)"); on yes islet asks for
  the base agent (opencode / opencode v2 / pi / hermes) and performs
  the same build +
  setup steps as the aliases above, under the typed name. Anything but
  y aborts.
  --config-dir <dir>
              template agent config dir: validated, then copied into the
              fresh agent config dir (~/.config/islet/<name>/config)
              when the agent is first created
  -v host_path:container[,host2:container2,...]
              extra bind mounts for this run (e.g. ~/.ssh:/root/.ssh:ro);
              comma-separated, mounted in addition to config.json volumes

  On the first run the "preinstall" list from config.json is baked into a
  per-agent derived image (islet-pre:<name>-<keyed hash>; rebuilt only when
  deps or the base image change).
  Volumes persisted across runs (all under ~/.config/islet/<name>/):
    deps/          — agent tool store mounted at /opt/islet-tools and
                     /root/.local; installs made during a run (apk add,
                     pip --user, npm -g, gem, go) survive into the next run
    config/        — agent config (plugins, extensions, auth, themes)
                     mounted at the agent's config dir in the container
    sessions/      — saved sessions/auth data dir, mounted at the agent's
                     data dir; survive --rm runs and Docker restarts
    volume_libs / volume_config / volume_sessions in config.json override
    the corresponding dirs

Examples:
  $SCRIPT_NAME                        # default agent, current directory
  $SCRIPT_NAME opencode ~/project     # run (or create) the "opencode" agent
  $SCRIPT_NAME myagent ~/project      # unknown: offers to create it
  $SCRIPT_NAME rm opencode            # remove the "opencode" agent entry
  $SCRIPT_NAME rm                     # uninstall: remove config + islet command
EOF
}

cfg_get() {
  jq -r "$@" "$ISLET_CONFIG"
}

# run_ps — list running containers of agents configured in config.json.
run_ps() {
  require_cmd jq
  [[ -f "$ISLET_CONFIG" ]] ||
    die "config not found: $ISLET_CONFIG — run 'install.sh' first"

  local -a names=()
  mapfile -t names < <(cfg_get '.agent // {} | to_entries[] | .key')

  # docker ps --filter name= accepts a regex; match our containers precisely.
  if ((${#names[@]} > 0)); then
    local regex="^($(
      IFS='|'
      echo "${names[*]}"
    ))\$"
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
    [[ -f "$ISLET_CONFIG" ]] ||
      die "config not found: $ISLET_CONFIG — run 'install.sh' first"

    if ! jq -e --arg b "$name" '.agent | has($b)' "$ISLET_CONFIG" >/dev/null; then
      local available
      available="$(cfg_get '.agent // {} | keys | join(", ")')"
      die "unknown agent: $name (available: $available)"
    fi

    local tmp="${ISLET_CONFIG}.tmp"
    jq --arg b "$name" '
      .agent |= delpaths([[$b]])
      | if (.agent // {}) == {} then del(."$schema", .container, .agent) else . end
    ' "$ISLET_CONFIG" >"$tmp" && mv "$tmp" "$ISLET_CONFIG"
    printf '%s✔ Agent %s%s%s removed from %s%s\n' \
      "$C_GREEN" "$C_BOLD" "$name" "$C_RESET" "$ISLET_CONFIG" "$C_RESET"
    return 0
  fi

  # --- full uninstall ------------------------------------------------------
  require_cmd jq
  local ans
  printf '%sUninstall islet (the %s config folder and config.json are kept)? (y/N)%s ' \
    "$C_YELLOW" "$ISLET_CONFIG_DIR" "$C_RESET" >&2
  read -r ans || ans=''
  if [[ ! "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    echo 'Aborted.'
    return 0
  fi

  # The islet config folder is deliberately preserved: config.json holds the
  # agent entries, so a reinstall keeps everything configured. Only the two
  # islet-installed shell commands go away. Delete by hand if really needed:
  #   rm -rf ~/.config/islet

  # Clean all islet commands from ~/.local/bin.
  local bin_dir="${HOME}/.local/bin"
  local cmd
  for cmd in islet islet-dev; do
    if [[ -f "$bin_dir/$cmd" || -L "$bin_dir/$cmd" ]]; then
      rm -f "$bin_dir/$cmd"
      printf '  removed %s\n' "$bin_dir/$cmd" >&2
    fi
  done

  printf '%s✔ islet uninstalled (config folder kept: %s)%s\n' \
    "$C_GREEN" "$ISLET_CONFIG_DIR" "$C_RESET"
  return 0
}

# agent_alias_kind [name-or-alias] — canonical kind for the "docker-new"
# run flow (see run_agent): an unknown agent name that matches a supported
# platform alias (opencode / opencode-v2 / opencode2 / pi / hermes) gets its
# image built on the fly and an interactive setup, then runs. Prints the
# canoncal name, or an empty string when the name is not an alias.
agent_alias_kind() {
  case "$1" in
  opencode) printf 'opencode' ;;
  opencode2 | opencode-v2) printf 'opencode2' ;;
  pi) printf 'pi' ;;
  hermes) printf 'hermes' ;;
  *) printf '' ;;
  esac
}

# build_agent_image <kind> — build the <kind> harness image from its
# factory Dockerfile (dockerfile_for) and tag it islet/<kind>:latest. The
# Dockerfile is generated into a temp dir and deleted right after. When the
# tag already belongs to another agent entry (e.g. this agent was renamed
# with `islet mv`), a fresh unique tag is used, so the renamed agent keeps
# its previous image version untouched.
build_agent_image() {
  local kind="$1"
  local tag="islet/${kind}:latest"

  local claimed=0
  claimed="$(cfg_get --arg img "$tag" \
    '[.agent // {} | to_entries[] | select(.value.image == $img)] | length' 2>/dev/null || echo 0)"
  if ((claimed > 0)); then
    local fallback
    fallback="islet/${kind}:$(date +%Y%m%d-%H%M%S)"
    printf '%s%s is taken (moved to another agent) — building %s%s%s%s\n' \
      "$C_DIM" "$tag" "$C_BOLD" "$fallback" "$C_RESET" "$C_RESET" >&2
    tag="$fallback"
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"
  dockerfile_for "$kind" >"${tmpdir}/Dockerfile"
  printf '%sBuilding %s%s (first run, ~a minute)%s\n' \
    "$C_BOLD" "$tag" "$C_RESET" "$C_RESET" >&2
  docker build -t "$tag" -f "${tmpdir}/Dockerfile" "$tmpdir" >/dev/null
  rm -rf "$tmpdir"
  printf '%s' "$tag"
}

run_agent() {
  local name='' workspace='' volumes_arg='' config_dir_arg=''

  # Flexible arguments: an existing directory is the workspace,
  # anything else is treated as an agent name. Order doesn't matter.
  # Options: -v host:container[,host2:container2,...] — extra bind mounts;
  # --config-dir <dir> — template agent config dir, used when the agent is
  # created on the fly (applied by the setup wizard).
  local arg
  while (($#)); do
    arg="$1"
    shift
    case "$arg" in
    -v | --volume)
      [[ -n "${1:-}" ]] || die "-v requires an argument: host:container[,host2:container2]"
      volumes_arg="$1"
      shift
      ;;
    -v=* | --volume=*) volumes_arg="${arg#*=}" ;;
    --config-dir)
      [[ -n "${1:-}" ]] || die "--config-dir requires a template directory path"
      config_dir_arg="$1"
      shift
      ;;
    --config-dir=*) config_dir_arg="${arg#*=}" ;;
    *)
      if [[ -d "$arg" ]]; then
        [[ -z "$workspace" ]] || die "multiple workspaces given: '$workspace' and '$arg'"
        workspace="$arg"
      else
        [[ -z "$name" ]] || die "multiple agent names given: '$name' and '$arg'"
        name="$arg"
      fi
      ;;
    esac
  done
  workspace="${workspace:-$PWD}"

  require_cmd jq

  # Resolve agent name: argument, or the default container from config.
  local default_container
  default_container="$(cfg_get '.container // empty')"
  if [[ -z "$name" ]]; then
    name="$default_container"
    [[ -n "$name" ]] || die "no default container set in $ISLET_CONFIG — try 'islet <agent>, e.g. islet opencode'"
  fi

  if ! jq -e --arg b "$name" '.agent | has($b)' "$ISLET_CONFIG" >/dev/null; then
    # Not configured (yet). A supported platform alias (opencode /
    # opencode-v2 / opencode2 / pi / hermes) creates the agent right here:
    # build its harness image, run the setup wizard, continue the run.
    # Any other unknown name asks first ("Create new?"), then does the
    # same flow after a base agent is chosen (opencode / opencode v2 /
    # pi / hermes).
    local kind
    kind="$(agent_alias_kind "$name")"
    if [[ -z "$kind" ]]; then
      local ans
      printf '%sAgent %s%s%s not found in %s. Create new? (y/N)%s ' \
        "$C_YELLOW" "$C_BOLD" "$name" "$C_RESET" "$ISLET_CONFIG" "$C_RESET" >&2
      read -r ans || ans=''
      if [[ ! "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        local available
        available="$(cfg_get '.agent // {} | keys | join(", ")')"
        die "unknown agent: $name (available: ${available:-none})"
      fi
      [[ "$name" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]] ||
        die "invalid agent name: $name (letters, digits, . _ - only)"

      printf '%sChoose the base agent for %s%s\n' "$C_BOLD" "$name" "$C_RESET" >&2
      printf '  %s1)%s opencode\n' "$C_GREEN" "$C_RESET" >&2
      printf '  %s2)%s opencode v2\n' "$C_GREEN" "$C_RESET" >&2
      printf '  %s3)%s pi\n' "$C_GREEN" "$C_RESET" >&2
      printf '  %s4)%s hermes\n' "$C_GREEN" "$C_RESET" >&2
      local choice
      choice="$(ask 'Select base agent' '1')"
      case "$choice" in
      1) kind='opencode' ;;
      2) kind='opencode2' ;;
      3) kind='pi' ;;
      4) kind='hermes' ;;
      *) die "invalid choice: $choice" ;;
      esac
    elif [[ "$kind" != "$name" ]]; then
      # alias normalizes to its canonical name (opencode-v2 -> opencode2);
      # if that is already configured, it just runs.
      name="$kind"
    fi

    # Still not configured -> create it: build the harness image, then the
    # setup wizard for the entry (typed or canonical name).
    if ! jq -e --arg b "$name" '.agent | has($b)' "$ISLET_CONFIG" >/dev/null; then
      local image
      image="$(build_agent_image "$kind")"
      local -a setup_args=(--name "$name" --image "$image")
      [[ -n "$config_dir_arg" ]] && setup_args+=(--config-dir "$config_dir_arg")
      run_setup "${setup_args[@]}"
      config_dir_arg='' # consumed
    fi
  fi

  # --config-dir was given for an already-configured agent: creation-time
  # only, so it has nothing to do here — say so and keep running.
  if [[ -n "$config_dir_arg" ]]; then
    printf '%s--config-dir only applies when the agent is first created; %s is already configured%s\n' \
      "$C_YELLOW" "$name" "$C_RESET" >&2
  fi

  local base_image volume_libs volume_config volume_sessions network deps_dir
  local container_name='' cache_dir='' fixed_env=()

  base_image="$(cfg_get --arg b "$name" '.agent[$b].image')"
  network="$(cfg_get --arg b "$name" '.agent[$b].network // "host"')"

  # Per-agent data folder: ~/.config/islet/<name>/ groups every persistent
  # piece of one agent:
  #   deps/     — agent tool store (apk rootfs, npm/go/gem/pip libs, apk cache)
  #   config/   — agent configuration (plugins, extensions, auth, themes)
  #   sessions/ — saved sessions/auth data dir
  # Each entry in config.json only references its agent implicitly; the
  # volume_* keys below stay as optional overrides.
  local data_dir
  data_dir="${ISLET_CONFIG_DIR}/${name}"
  deps_dir="${data_dir}/deps"
  volume_libs="$(cfg_get --arg b "$name" '.agent[$b].volume_libs // ""')"
  volume_libs="${volume_libs:-${deps_dir}/apk-cache}"
  volume_config="$(cfg_get --arg b "$name" '.agent[$b].volume_config // ""')"
  volume_config="${volume_config:-${data_dir}/config}"
  volume_sessions="$(cfg_get --arg b "$name" '.agent[$b].volume_sessions // ""')"
  volume_sessions="${volume_sessions:-${data_dir}/sessions}"
  volume_libs="${volume_libs/#\~/$HOME}"
  volume_config="${volume_config/#\~/$HOME}"
  volume_sessions="${volume_sessions/#\~/$HOME}"

  # Extra volumes from -v ("host:container,host2:container2", :ro... flags
  # allowed): expand ~, require both halves, validate the host path exists,
  # and collect ready-to-mount spec strings ("host:container[:flags]").
  local -a extra_volumes=()
  if [[ -n "$volumes_arg" ]]; then
    local -a specs=()
    IFS=',' read -r -a specs <<<"$volumes_arg"
    local spec host container
    for spec in "${specs[@]}"; do
      spec="${spec/#\~/$HOME}"
      spec="${spec//!:/%%ISLET_ESC%%}" # "!:" marks an escaped ":"
      spec="${spec//!/:}"              # a lone "!" is a literal ":"
      spec="${spec//%%ISLET_ESC%%/:}"
      [[ "$spec" == *:* ]] || die "-v volume needs host:container: $spec"
      host="${spec%%:*}"
      container="${spec#*:}"
      [[ -n "$host" && -n "$container" ]] ||
        die "-v volume needs both host and container paths: $spec"
      [[ -e "$host" ]] || die "-v host path does not exist: $host"
      mkdir -p "$host"
      extra_volumes+=("$host:$container")
    done
  fi

  [[ -d "$workspace" ]] || die "workspace directory does not exist: $workspace"
  workspace="$(cd "$workspace" && pwd)"
  mkdir -p "$deps_dir" "$volume_libs" "$volume_config" "$volume_sessions"
  [[ -n "$cache_dir" ]] && mkdir -p "$cache_dir"

  # In-container paths of the agent's config and data dirs. They must match
  # what the agent itself reads — not the config entry name: an agent named
  # e.g. "my-agent" still reads its config from /root/.config/opencode.
  local run_config_dir run_data_dir
  local agent_kind
  agent_kind="$(cfg_get --arg b "$name" '.agent[$b].agent // ""')"
  if [[ -z "$agent_kind" ]]; then
    case "$base_image" in
      *opencode*) agent_kind='opencode' ;;
      *pi*) agent_kind='pi' ;;
      *hermes*) agent_kind='hermes' ;;
      *) agent_kind="$name" ;;
    esac
  fi
  case "$agent_kind" in
  opencode) run_config_dir='/root/.config/opencode'; run_data_dir='/root/.local/share/opencode' ;;
  pi) run_config_dir='/root/.config/pi'; run_data_dir='/root/.local/share/pi' ;;
  hermes) run_config_dir='/root/.config/hermes'; run_data_dir='/root/.local/share/hermes' ;;
  *) run_config_dir="/root/.config/${name}"; run_data_dir="/root/.local/share/${name}" ;;
  esac

  # pi keeps extensions, skills, themes, prompts and auth in its agent dir
  # (~/.pi/agent by default). Redirect it into the persisted config volume.
  if [[ "$agent_kind" == 'pi' ]]; then
    fixed_env+=(--env "PI_CODING_AGENT_DIR=$run_config_dir")
  elif [[ "$agent_kind" == 'opencode' ]]; then
    # npm plugins are installed into ~/.cache/opencode at startup.
    cache_dir="${data_dir}/opencode-cache"
  fi

  # Per-agent runtime image: preinstall deps from config are baked into a
  # derived image (<name>-<hash(base image + deps)>), which is also where the
  # capture environment lives — PATH prefixes and package-manager prefixes
  # pointing into the mounted deps dir, and an apk wrapper installing into
  # the deps dir too. Runtime installs therefore persist across runs.
  local -a preinstall=()
  mapfile -t preinstall < <(
    cfg_get --arg b "$name" '.agent[$b].preinstall // [] | .[]' || true
  )

  require_cmd docker
  local image
  image="$(run_deps_image "$name" "$base_image" ${preinstall[@]+"${preinstall[@]}"})"

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
  docker_args+=("${fixed_env[@]+${fixed_env[@]}}")

  docker_args+=(
    --workdir /workspace
    --volume "$workspace:/workspace"
    --volume "$volume_config:$run_config_dir"
    --volume "$volume_sessions:$run_data_dir"
    --volume "$volume_libs:/var/cache/apk"
    # agent tool store: one source, mounted twice — /opt/islet-tools is the
    # canonical hub (PATH/PM prefixes live there), /root/.local is where
    # pip --user and other home-relative installers go.
    --volume "$deps_dir:/opt/islet-tools"
    --volume "$deps_dir:/root/.local"
  )
  if [[ -n "$cache_dir" ]]; then
    docker_args+=(
      # opencode npm-plugin cache: installed once, reloaded after restart.
      --volume "$cache_dir:/root/.cache/opencode"
    )
  fi
  local extra
  for extra in "${extra_volumes[@]}"; do
    docker_args+=(--volume "$extra")
  done
  docker_args+=("$image")

  echo "Agent:     $name"
  echo "Image:     $image"
  echo "Deps:      $deps_dir (persisted across runs)"
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
  Go) printf '🐹' ;;
  Java) printf '☕' ;;
  Python) printf '🐍' ;;
  Rust) printf '🦀' ;;
  Ruby) printf '💎' ;;
  C/C++) printf '🔧' ;;
  *) printf '•' ;;
  esac
}

# multichoice <out-array> <item>... — interactive multi-select list
# (↑/↓ or j/k move, Tab/Space toggle, Enter confirm). When stdin or stderr
# is not a TTY this falls back to numbered toggles: one line per exchange,
# space-separated numbers toggle items, an empty line confirms.
multichoice() {
  local -n _out=$1
  shift
  local items=("$@")
  local -a state=()
  local i n input cur=0 key
  for ((i = 0; i < ${#items[@]}; i++)); do state[i]=0; done

  if [[ -t 0 && -t 2 ]]; then
    # --- interactive TUI ---------------------------------------------------
    printf '%s↑/↓ move · Tab select · Enter confirm%s\n' "$C_DIM" "$C_RESET" >&2
    printf '\033[?25l' >&2 # hide cursor
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
        *) key='ignore' ;;
        esac
      fi
      case "$key" in
      up | k) cur=$(((cur - 1 + ${#items[@]}) % ${#items[@]})) ;;
      down | j) cur=$(((cur + 1) % ${#items[@]})) ;;
      $'\t' | ' ') state[cur]=$((1 - state[cur])) ;;
      '' | $'\r') break ;; # Enter
      esac
      printf '\033[%dA' "${#items[@]}" >&2 # move cursor up to redraw
    done

    printf '\033[?25h' >&2 # show cursor
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

# preinstall_pkgs <dep>... — maps preinstall environment items (as stored
# in config.json) to the Alpine package names baked into the derived image.
preinstall_pkgs() {
  local out='' dep
  for dep in "$@"; do
    case "$dep" in
    Node.js) out+=' nodejs npm' ;;
    Go) out+=' go' ;;
    Java) out+=' openjdk17' ;;
    Python) out+=' python3' ;;
    Rust) out+=' cargo rust' ;;
    Ruby) out+=' ruby' ;;
    C/C++) out+=' build-base' ;;
    Git) out+=' git' ;;
    esac
  done
  printf '%s' "${out# }"
}

# dockerfile_for <agent> — print a Dockerfile for the supported agents
# (Alpine base: opencode/opencode v2 and hermes runtime installs, pi on
# node:24-alpine). No preinstall deps here — those are picked in the
# setup wizard, stored in config.json and baked into the derived image
# at run time.
dockerfile_for() {
  local agent="$1"
  shift

  case "$agent" in
  opencode)
    cat <<EOF
# opencode agent harness — Alpine, runtime setup baked at build time.
FROM alpine:latest

RUN apk add --no-cache \\
      bash curl wget jq tar unzip git ripgrep ca-certificates tzdata \\
      libstdc++

# Install the opencode binary. The installer needs bash (not busybox sh) —
# installed by the apk line above.
ENV SHELL=/bin/sh
RUN curl -fsSL https://opencode.ai/install | bash
ENV PATH="/root/.opencode/bin:\${PATH}"

RUN mkdir -p /workspace /root/.config/opencode
WORKDIR /workspace

ENTRYPOINT ["opencode"]
EOF
    ;;
  opencode2)
    cat <<EOF
# opencode v2 agent harness — Alpine, runtime setup baked at build time.
FROM alpine:latest

RUN apk add --no-cache \\
      bash curl wget jq tar unzip git ripgrep ca-certificates tzdata \\
      libstdc++

# Install the opencode v2 binary. The installer needs bash (not busybox sh)
# — installed by the apk line above.
ENV SHELL=/bin/sh
RUN curl -fsSL https://opencode.ai/v2/install | bash
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

RUN apk add --no-cache bash ca-certificates git ripgrep

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
      bash curl wget jq tar unzip git ripgrep ca-certificates tzdata

RUN curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
ENV PATH="/root/.hermes/bin:\${PATH}"

RUN mkdir -p /workspace /root/.config/hermes
WORKDIR /workspace

ENTRYPOINT ["hermes"]
EOF
    ;;
  *) die "unsupported agent: $agent (supported: opencode, opencode2, pi, hermes)" ;;
  esac
}

# run_deps_image <name> <base-image> [dep]... — bake the preinstall list into
# a per-agent derived image, and arm the capture environment for runtime
# installs (PATH prefixes, package-manager prefixes, apk wrapper). The tag is
# keyed by a hash of base image + dep list + wrapper revision, so Docker's
# cache keeps it across runs; it is rebuilt only when the deps, the base
# image, or the wrapper (CAPTURE block) change.
run_deps_image() {
  local name="$1" base="$2"
  shift 2

  local depkey tag pkg deps_desc wrapper_rev="2" # bump wrapper_rev when the CAPTURE block changes
  local -a pkgs=()
  for pkg in $(preinstall_pkgs "$@"); do pkgs+=("$pkg"); done
  deps_desc="$*"

  depkey="$(printf '%s|%s|wrapper-v%s' "$base" "$deps_desc" "$wrapper_rev" | sha256sum | cut -c1-10)"
  tag="islet-pre:${name}-${depkey}"

  if docker image inspect "$tag" >/dev/null 2>&1; then
    printf '%s' "$tag"
    return 0
  fi

  printf '%sBaking dependencies (%s) into %s%s\n' \
    "$C_BOLD" "${deps_desc:-none}" "$tag" "$C_RESET" >&2

  local df
  df="$(mktemp)"
  {
    printf 'FROM %s\n' "$base"
    if ((${#pkgs[@]} > 0)); then
      printf 'RUN apk add --no-cache'
      printf ' %s' "${pkgs[@]}"
      printf '\n'
    fi
    cat <<'CAPTURE'
RUN mkdir -p /usr/local/bin \
  && printf '%s\n' \
      '#!/bin/sh' \
      '# islet apk wrapper — install packages into the persistent deps' \
      '# rootfs (/opt/islet-tools/alpine) so they survive container rebuilds.' \
      'root=/opt/islet-tools/alpine' \
      'cache=/opt/islet-tools/apk-cache' \
      '# apk-tools 3: --initdb is only valid for DB-mutating applets (add, del,' \
      '# fix, upgrade) and is rejected by search/info/update — so never pass it' \
      '# blindly. Instead, bootstrap database + repo config on first use.' \
      'mkdir -p "$root" "$cache"' \
      'if [ ! -f "$root/etc/apk/repositories" ]; then' \
      '  mkdir -p "$root/etc/apk/keys"' \
      '  cp /etc/apk/repositories "$root/etc/apk/" 2>/dev/null || true' \
      '  cp /etc/apk/keys/* "$root/etc/apk/keys/" 2>/dev/null || true' \
      'fi' \
      'if [ ! -f "$root/lib/apk/db/installed" ]; then' \
      '  /sbin/apk --root "$root" --cache-dir "$cache" --initdb add >/dev/null 2>&1 || true' \
      'fi' \
      'exec /sbin/apk --root "$root" --cache-dir "$cache" "$@"' \
      > /usr/local/bin/apk \
  && chmod +x /usr/local/bin/apk
ENV PATH="/opt/islet-tools/alpine/usr/bin:/opt/islet-tools/alpine/usr/sbin:/opt/islet-tools/alpine/sbin:/opt/islet-tools/alpine/bin:/opt/islet-tools/bin:/opt/islet-tools/npm/bin:/opt/islet-tools/go/bin:/opt/islet-tools/pyuser/bin:/opt/islet-tools/gems/bin:/opt/islet-tools/cargo/bin:/root/.local/bin:${PATH}"
ENV NPM_CONFIG_PREFIX=/opt/islet-tools/npm
ENV GOPATH=/opt/islet-tools/go
ENV GEM_HOME=/opt/islet-tools/gems
ENV PYTHONUSERBASE=/opt/islet-tools/pyuser
ENV CARGO_HOME=/opt/islet-tools/cargo
ENV LD_LIBRARY_PATH=/opt/islet-tools/alpine/usr/lib:/opt/islet-tools/alpine/lib
CAPTURE
  } >"$df"

  docker build -t "$tag" -f "$df" . >/dev/null
  rm -f "$df"

  printf '%s' "$tag"
}

# jsonc_strip_comments — whitespace-preserving stream that removes // line
# comments and /* ... */ block comments (string-aware: // inside "..." or
# escaped quotes is kept). Used only to validate .jsonc config templates —
# the template files themselves are copied verbatim.
jsonc_strip_comments() {
  awk '
  {
    line = $0; out = ""
    j = 1; n = length(line)
    while (j <= n) {
      c = substr(line, j, 1)
      if (in_block) {
        if (c == "*" && substr(line, j + 1, 1) == "/") { in_block = 0; j += 2 }
        else { j++ }
        continue
      }
      if (c == "\"") {
        out = out c; j++
        while (j <= n) {
          cc = substr(line, j, 1)
          out = out cc; j++
          if (cc == "\\") { out = out substr(line, j, 1); j++ }
          else if (cc == "\"") { break }
        }
        continue
      }
      if (c == "/" && substr(line, j + 1, 1) == "/") { break }
      if (c == "/" && substr(line, j + 1, 1) == "*") { in_block = 1; j += 2; continue }
      out = out c; j++
    }
    print out
  }'
  return 0
}

# file_json_ok <file> — true when <file> is parseable JSON (.json) or
# JSONC (.jsonc, comments stripped first, still via jq).
file_json_ok() {
  local f="$1"
  if [[ "$f" == *.jsonc ]]; then
    jq -e . 2>/dev/null >/dev/null < <(jsonc_strip_comments <"$f")
  else
    jq -e . 2>/dev/null >/dev/null "$f"
  fi
}

# agent_kind_from_image <image> [fallback] — best-effort agent kind for
# template validation: "opencode" images may hold opencode.json(c) —
# pi/hermes keep arbitrary config trees. Unknown images fall back to the
# agent name (generic checks only).
agent_kind_from_image() {
  local image="$1" fallback="${2:-}"
  case "$image" in
  *opencode*) printf 'opencode' ;;
  *pi*) printf 'pi' ;;
  *hermes*) printf 'hermes' ;;
  *) printf '%s' "$fallback" ;;
  esac
}

# validate_template_dir <kind> <dir> — check that a --config-dir template
# agent dir is correct before it is copied into the fresh agent config dir:
#   - the directory must exist and not be empty
#   - opencode templates must contain opencode.json or opencode.jsonc
#   - every *.json / *.jsonc (also hidden) must parse via jq
# Dies with a clear message on the first problem found.
validate_template_dir() {
  local kind="$1" dir="$2"

  [[ -d "$dir" ]] || die "config-dir: template directory not found: $dir"
  [[ -n "$(ls -A "$dir" 2>/dev/null)" ]] ||
    die "config-dir: template directory is empty: $dir"

  if [[ "$kind" == 'opencode' ]]; then
    # opencode starts from opencode.json / opencode.jsonc (comments are
    # allowed in .jsonc — stripped before the jq validation).
    local cfg_file="$dir/opencode.json"
    [[ -f "$cfg_file" ]] || cfg_file="$dir/opencode.jsonc"
    [[ -f "$cfg_file" ]] ||
      die "config-dir: opencode template needs opencode.json or opencode.jsonc in $dir"
    file_json_ok "$cfg_file" ||
      die "config-dir: invalid JSON in $cfg_file"
  fi

  local g
  for g in "$dir"/*.json "$dir"/.*.json "$dir"/*.jsonc "$dir"/.*.jsonc; do
    [[ -f "$g" ]] || continue
    file_json_ok "$g" ||
      die "config-dir: invalid JSON in $g"
  done
  return 0
}

# run_setup — the setup wizard for the create-on-the-spot flow
# (`islet <agent>` with an unconfigured agent, run from run_agent):
#   step 1: agent name           (default: agent)
#   step 2: image                (default: ghcr.io/anomalyco/opencode:latest)
#   step 3: preinstall env       (multi-select, saved as .preinstall)
#   step 4: network              (default: host)
#   step 5: environment          (KEY=VALUE,KEY=VALUE; default: none)
# The preinstall list is baked into a per-agent derived image on the first
# run; runtime installs are captured in ~/.config/islet/<name>/deps.
# Persistence is automatic — every agent owns ~/.config/islet/<name>/
# (deps/, config/ and sessions/ are mounted into the container); only the
# optional --config-volume flag writes an explicit volume_config override.
# Flags skip their step with the given value (--name, --image,
# --preinstall 'a,b', --config-volume <dir>, --network host|bridge,
# --env 'KEY=V,K2=V2'); steps without a flag are still prompted.
run_setup() {
  require_cmd jq

  # --- flags: fill values without the TUI --------------------------------
  local opt_name='' opt_image='' opt_preinstall='' opt_config_volume=''
  local opt_network='' opt_env='' opt_config_dir=''
  local opt_usage='setup [flags]
flags:
  --name <agent>              step 1
  --image <docker-image>      step 2
  --preinstall <a,b,...>      step 3 (Git,Node.js,Go,Java,Python,Rust,Ruby,C/C++)
  --config-volume <dir>       step 4 (host dir mounted as agent config)
  --network <host|bridge>     step 5
  --env <KEY=V[,KEY2=V2]>     step 6
  --config-dir <template-dir> template agent config dir: validated and
                              copied into the fresh agent config dir
                              (~/.config/islet/<name>/config or the
                              --config-volume override)'
  while (($#)); do
    case "$1" in
    --name | --image | --preinstall | --config-volume | --network | --env | --config-dir)
      [[ -n "${2:-}" ]] || die "missing value for $1
$opt_usage"
      local flag="$1"
      case "$flag" in
      --name) opt_name="$2" ;;
      --image) opt_image="$2" ;;
      --preinstall) opt_preinstall="$2" ;;
      --config-volume) opt_config_volume="$2" ;;
      --network) opt_network="$2" ;;
      --env) opt_env="$2" ;;
      --config-dir) opt_config_dir="$2" ;;
      esac
      shift 2
      ;;
    -h | --help)
      printf '%s\n' "$opt_usage"
      return 0
      ;;
    *)
      die "unknown setup argument: $1
$opt_usage"
      ;;
    esac
  done

  local name
  if [[ -n "$opt_name" ]]; then
    name="$opt_name"
  else
    step_header 1 'Agent name'
    name="$(ask 'Agent name' 'agent')"
  fi

  local image
  if [[ -n "$opt_image" ]]; then
    image="$opt_image"
  else
    step_header 2 'Image'
    image="$(ask 'Docker image' "$OPENCODE_IMAGE_DEFAULT")"
  fi

  # --config-dir: the template is checked before anything is written, so a
  # wrong template aborts setup instead of seeding a broken config.
  if [[ -n "$opt_config_dir" ]]; then
    validate_template_dir "$(agent_kind_from_image "$image" "$name")" "$opt_config_dir"
  fi

  step_header 3 'Preinstall environment'
  # Baked into the derived image on the next run; runtime installs by the
  # agent are captured in the per-agent deps dir regardless.
  local -a preinstall=()
  if [[ -n "$opt_preinstall" ]]; then
    local dep
    local -a known=(Git Node.js Go Java Python Rust Ruby C/C++)
    IFS=',' read -r -a preinstall <<<"${opt_preinstall// /}"
    for dep in "${preinstall[@]}"; do
      if (( ${#dep} == 0 )); then
        continue
      fi
      if ! printf '%s\n' "${known[@]}" | grep -Fxq "$dep"; then
        die "unknown preinstall dep: $dep (known: ${known[*]})"
      fi
    done
  else
    multichoice preinstall 'Git' 'Node.js' 'Go' 'Java' 'Python' 'Rust' 'Ruby' 'C/C++'
  fi

  # config/ dir is derived (step removed): ~/.config/islet/<name>/config is
  # mounted automatically as the agent's config; --config-volume overrides.
  local volume_config=''
  [[ -n "$opt_config_volume" ]] && volume_config="$opt_config_volume"

  local network
  if [[ -n "$opt_network" ]]; then
    case "$opt_network" in
    host | bridge) network="$opt_network" ;;
    *) die "invalid --network value: $opt_network (host|bridge)" ;;
    esac
  else
    step_header 4 'Network'
    printf '  %s1)%s host (default)\n' "$C_GREEN" "$C_RESET"
    printf '  %s2)%s bridge (publish ports in config.json)\n' "$C_YELLOW" "$C_RESET"
    printf -v network '%s' "$(ask 'Select' '1')"
    case "$network" in
    2) network='bridge' ;;
    *) network='host' ;;
    esac
  fi

  local -a env_pairs=()
  local env_input="$opt_env"
  if [[ -n "$opt_env" ]]; then
    if [[ "$env_input" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^,]*(,[A-Za-z_][A-Za-z0-9_]*=[^,]*)*$ ]]; then
      IFS=',' read -r -a env_pairs <<<"$env_input"
    else
      die "invalid --env value: $opt_env
Example: API_KEY=secret,FOO=bar"
    fi
  else
    step_header 5 'Environment variables'
    while true; do
      env_input="$(ask 'Environment variables (KEY=VALUE,KEY=VALUE — empty to skip)')"
      [[ -z "$env_input" ]] && break
      if [[ "$env_input" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^,]*(,[A-Za-z_][A-Za-z0-9_]*=[^,]*)*$ ]]; then
        IFS=',' read -r -a env_pairs <<<"$env_input"
        break
      fi
      printf '%sInvalid format. Example: API_KEY=secret,FOO=bar%s\n' "$C_RED" "$C_RESET" >&2
    done
  fi

  # --- save into config.json (merge; sibling agents are kept) --------------
  mkdir -p "$(dirname "$ISLET_CONFIG")"
  [[ -f "$ISLET_CONFIG" ]] || jq -n '{"$schema": "islet.sh"}' >"$ISLET_CONFIG"
  local env_json preinstall_json
  if ((${#env_pairs[@]} > 0)); then
    env_json="$(printf '%s\n' "${env_pairs[@]}" |
      jq -R 'split("=") | {(.[0]): .[1]}' | jq -s 'add // {}')"
  else
    env_json='{}'
  fi
  # preinstall: multi-select names, stored verbatim (image build maps them
  # to Alpine packages; e.g. Node.js -> nodejs npm).
  if ((${#preinstall[@]} > 0)); then
    preinstall_json="$(printf '%s\n' "${preinstall[@]}" | jq -R . | jq -s .)"
  else
    preinstall_json='[]'
  fi

  local agent_json
  agent_json="$(jq -n \
    --arg image "$image" \
    --arg volume_config "$volume_config" \
    --arg network "$network" \
    --argjson ports '[]' \
    --argjson environment "$env_json" \
    --argjson preinstall "$preinstall_json" \
    '{
      image: $image,
      preinstall: $preinstall,
      network: $network,
      ports: $ports,
      environment: $environment
    }
    | if $volume_config == "" then . else .volume_config = $volume_config end
    ')"

  local merge_filter='
    .agent = ((.agent // {}) + {($key): $agent})
    | ."$schema" = (."$schema" // "islet.sh")
    | .container = (.container // $key)
  '
  local tmp_json="${ISLET_CONFIG}.tmp"
  jq --arg key "$name" --argjson agent "$agent_json" \
    "$merge_filter" "$ISLET_CONFIG" >"$tmp_json" ||
    die "invalid config format: $ISLET_CONFIG"
  mv "$tmp_json" "$ISLET_CONFIG"

  printf '%s✔ Agent %s%s%s saved to %s%s\n' \
    "$C_GREEN" "$C_BOLD" "$name" "$C_RESET" "$ISLET_CONFIG" "$C_RESET"

  # --config-dir: copy the validated template agent dir into the agent's
  # persistent config dir (the default config folder or the --config-volume
  # override). An already-populated config dir is never clobbered.
  if [[ -n "$opt_config_dir" ]]; then
    local seed_dir="${volume_config:-${ISLET_CONFIG_DIR}/${name}/config}"
    seed_dir="${seed_dir/#\~/$HOME}"
    if [[ -d "$seed_dir" && -n "$(ls -A "$seed_dir" 2>/dev/null)" ]]; then
      printf '%s  config: %s already populated — template not copied%s\n' \
        "$C_YELLOW" "$seed_dir" "$C_RESET"
    else
      mkdir -p "$seed_dir"
      cp -a "${opt_config_dir%/}/." "$seed_dir/"
      printf '  config: template copied to %s%s%s\n' \
        "$C_BOLD" "$seed_dir" "$C_RESET"
    fi
  fi

  if ((${#preinstall[@]} > 0)); then
    printf '  preinstall: %s\n' "${preinstall[*]}"
  fi
  printf '  run it now: %s %s <workspace>%s\n' "$C_BOLD" "$name" "$C_RESET"
  return 0
}

# run_mv <old> <new> — rename an agent: the config.json key (and the
# default container, if it pointed at <old>) plus its data folder
# ~/.config/islet/<old> -> <new>. Everything else (image, deps and env
# settings) is preserved. The derived deps image is keyed by the agent
# name, so it is re-baked on the next run under the new name.
run_mv() {
  local old="${1:-}" new="${2:-}"
  [[ -n "$old" && -n "$new" ]] ||
    die "usage: $SCRIPT_NAME mv <old-name> <new-name>"
  [[ "$old" != "$new" ]] || die "old and new names are identical: $old"
  [[ "$new" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]] ||
    die "invalid agent name: $new (letters, digits, . _ - only)"

  require_cmd jq
  [[ -f "$ISLET_CONFIG" ]] ||
    die "config not found: $ISLET_CONFIG — run 'install.sh' first"

  if ! jq -e --arg b "$old" '.agent | has($b)' "$ISLET_CONFIG" >/dev/null; then
    local available
    available="$(cfg_get '.agent // {} | keys | join(", ")')"
    die "unknown agent: $old (available: $available)"
  fi
  if jq -e --arg b "$new" '.agent | has($b)' "$ISLET_CONFIG" >/dev/null; then
    die "agent already exists: $new"
  fi

  local tmp="${ISLET_CONFIG}.tmp"
  jq --arg old "$old" --arg new "$new" '
    .agent |= (to_entries | map(if .key == $old then .key = $new else . end) | from_entries)
    | if .container == $old then .container = $new else . end
  ' "$ISLET_CONFIG" >"$tmp" || die "invalid config format: $ISLET_CONFIG"
  mv "$tmp" "$ISLET_CONFIG"

  local data_dir="${ISLET_CONFIG_DIR}/${old}"
  if [[ -d "$data_dir" ]]; then
    mv "$data_dir" "${ISLET_CONFIG_DIR}/${new}"
  fi

  printf '%s✔ Agent %s%s%s renamed to %s%s%s (config key + data folder)\n' \
    "$C_GREEN" "$C_BOLD" "$old" "$C_RESET" "$C_BOLD" "$new" "$C_RESET"
  return 0
}

# run_update — refresh the islet command by re-running the installer.
# install.sh preserves config.json, so all agent entries survive.
# The installer source can be overridden with ISLET_INSTALL_URL (the
# installer itself understands the same variable).
run_update() {
  local url="${ISLET_INSTALL_URL:-$ISLET_INSTALL_URL_DEFAULT}"
  require_cmd curl
  printf '%sUpdating islet — running the installer from %s%s%s\n' \
    "$C_BOLD" "$C_DIM" "$url" "$C_RESET" "$C_RESET"
  curl -fsSL "$url" | ISLET_INSTALL_URL="$url" sh
  printf '%s✔ islet updated (config.json untouched)%s\n' \
    "$C_GREEN" "$C_RESET"
}

main() {
  case "${1:-}" in
  -h | --help | help)
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
  mv)
    shift
    run_mv "$@"
    ;;
  update)
    shift
    run_update "$@"
    ;;
  *)
    run_agent "$@"
    ;;
  esac
}

main "$@"

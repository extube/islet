#!/usr/bin/env bash
# test/run.sh — minimal manual test suite for the islet shell scripts.
#
# No framework: assertion helpers plus scenario scripts that drive install.sh
# and islet.sh in isolated HOME dirs with piped stdin / a fake docker.
#
# Usage: bash test/run.sh

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKEBIN="$(mktemp -d)"
trap 'rm -rf "$FAKEBIN"' EXIT

pass=0 fail=0

check() {
  local desc="$1" result="$2"
  if [[ "$result" == 0 ]]; then
    printf '  ✔ %s\n' "$desc"; pass=$((pass + 1))
  else
    printf '  ✖ %s\n' "$desc"; fail=$((fail + 1))
  fi
}

assert_eq() {
  check "$1" "$([[ "$2" == "$3" ]] && echo 0 || echo 1)"
}

jq_get() { jq -r "$2" "$1"; }

# fake docker — logs its arguments; use run_x ... FAKE to activate.
make_fake_docker() {
  cat > "$FAKEBIN/docker" <<'EOF'
#!/bin/bash
echo "docker $*" >> /tmp/islet-fake-docker.log
EOF
  chmod +x "$FAKEBIN/docker"
}

# --- syntax -----------------------------------------------------------------

t_syntax() {
  printf 'syntax\n'
  for script in install.sh islet.sh islet.dev.sh test/run.sh; do
    check "$script" "$(bash -n "$ROOT/$script" 2>&1 && echo 0 || echo 1)"
  done
}

# --- install: requirements + config path + islet command ---------------------

t_install() {
  printf 'install — minimal installer\n'
  local home; home="$(mktemp -d)"
  # Prompts: docker-missing (y), islet config folder (default).
  printf 'y\n\n' | HOME="$home" bash "$ROOT/install.sh" >/dev/null 2>&1

  local cfg="$home/.config/islet/config.json"
  check 'config created'          "$([[ -f "$cfg" ]]; echo $?)"
  assert_eq 'config shape'        "$(jq_get "$cfg" '."$schema"')"        'islet.sh'
  check 'islet command installed' "$([[ -x "$home/.local/bin/islet" ]]; echo $?)"
  rm -rf "$home"
}

t_install_flag() {
  printf 'install — --config-dir flag\n'
  local home; home="$(mktemp -d)"
  HOME="$home" bash "$ROOT/install.sh" --config-dir "$home/cfg" >/dev/null 2>&1 </dev/null
  assert_eq 'config dir respected' \
    "$([[ -f "$home/cfg/config.json" ]]; echo $?)" '0'
  rm -rf "$home"
}

# --- islet create ------------------------------------------------------------

t_create() {
  printf 'islet create — one-step agent Dockerfile (no preinstall here)\n'
  local tmp; tmp="$(mktemp -d)"
  # Answers: agent (1) only — deps are picked in `islet setup`, not here.
  printf '1\n' | HOME="$tmp" PATH="$FAKEBIN:$PATH" bash "$ROOT/islet.sh" create "$tmp" >/dev/null 2>&1
  check 'opencode.Dockerfile created'  "$([[ -f "$tmp/opencode.Dockerfile" ]]; echo $?)"
  assert_eq 'alpine base'              "$(grep -m1 '^FROM alpine' "$tmp/opencode.Dockerfile")" 'FROM alpine:latest'
  check 'no preinstall baked (nodejs npm)' \
    "$(grep -q 'nodejs npm' "$tmp/opencode.Dockerfile" && echo 1 || echo 0)"
  check 'no preinstall baked (ruby)'   "$(grep -q ' ruby' "$tmp/opencode.Dockerfile" && echo 1 || echo 0)"

  printf '3\n' | HOME="$tmp" bash "$ROOT/islet.sh" create "$tmp" >/dev/null 2>&1
  check 'hermes.Dockerfile created' \
    "$([[ -f "$tmp/hermes.Dockerfile" ]]; echo $?)"
  # pi Dockerfile to the given file path.
  printf '2\n' | HOME="$tmp" bash "$ROOT/islet.sh" create /tmp/pi-test.Dockerfile >/dev/null 2>&1
  assert_eq 'pi base'   "$(grep -m1 '^FROM node:24-alpine' /tmp/pi-test.Dockerfile)" 'FROM node:24-alpine'
  rm -f /tmp/pi-test.Dockerfile
  rm -rf "$tmp"
}

# --- islet build ------------------------------------------------------------

t_build() {
  printf 'islet build — docker build wrapping\n'
  local tmp; tmp="$(mktemp -d)"
  make_fake_docker
  : > "$tmp/pi.Dockerfile"
  rm -f /tmp/islet-fake-docker.log
  HOME="$tmp" PATH="$FAKEBIN:$PATH" bash "$ROOT/islet.sh" build "$tmp/pi.Dockerfile" >/dev/null 2>&1
  assert_eq 'image tag islet/pi:latest' \
    "$(cat /tmp/islet-fake-docker.log 2>/dev/null)" \
    'docker build -t islet/pi:latest -f '"$tmp"'/pi.Dockerfile '"$tmp"
  rm -rf "$tmp"
}

# --- installer keeps an existing config.json ---------------------------------

t_install_keeps_config() {
  printf 'install — existing config.json is kept\n'
  local home; home="$(mktemp -d)"
  mkdir -p "$home/.config/islet"
  printf '{"$schema":"islet.sh","container":"myagent","agent":{"myagent":{"image":"img:x"}}}' \
    > "$home/.config/islet/config.json"
  printf 'y\n\n' | HOME="$home" bash "$ROOT/install.sh" >/dev/null 2>&1
  assert_eq 'existing config untouched' \
    "$(jq_get "$home/.config/islet/config.json" '.agent.myagent.image')" 'img:x'
  rm -rf "$home"
}

# --- run agent with the new config schema ------------------------------------

t_run_schema() {
  printf 'run agent — config.json fields\n'
  local home; home="$(mktemp -d)"
  mkdir -p "$home/.config/islet" "$home/ws"
  cat > "$home/.config/islet/config.json" <<'JSON'
{
  "$schema": "islet.sh",
  "container": "opencode",
  "agent": {
    "opencode": {
      "image": "islet/opencode:latest",
      "volume_libs": "~/.local/share/islet/opencode-libs",
      "volume_config": "~/.config/opencode",
      "network": "bridge",
      "ports": ["8080:8080"],
      "environment": { "API_KEY": "abc" }
    }
  }
}
JSON
  rm -f /tmp/islet-fake-docker.log
  make_fake_docker
  HOME="$home" PATH="$FAKEBIN:$PATH" bash "$ROOT/islet.sh" opencode "$home/ws" >/dev/null 2>&1
  local got; got="$(cat /tmp/islet-fake-docker.log 2>/dev/null)"
  check 'workspace mounted'    "$(grep -q -- "--volume $home/ws:/workspace" <<<"$got" && echo 0 || echo 1)"
  check 'agent config volume'  "$(grep -q -- "--volume $home/.config/opencode:/root/.config/opencode" <<<"$got" && echo 0 || echo 1)"
  check 'apk cache override (volume_libs)' "$(grep -q -- "--volume $home/.local/share/islet/opencode-libs:/var/cache/apk" <<<"$got" && echo 0 || echo 1)"
  check 'sessions volume'      "$(grep -q -- "--volume $home/.config/islet/opencode/sessions:/root/.local/share/opencode" <<<"$got" && echo 0 || echo 1)"
  check 'port published'       "$(grep -q -- '--publish 8080:8080' <<<"$got" && echo 0 || echo 1)"
  check 'env var'              "$(grep -q -- '--env API_KEY=abc' <<<"$got" && echo 0 || echo 1)"
  check 'image last (derived)' "$(grep -q ' islet-pre:opencode-' <<<"$got" && echo 0 || echo 1)"
  check 'opencode plugin cache persisted' \
    "$(grep -q -- "--volume $home/.config/islet/opencode/opencode-cache:/root/.cache/opencode" <<<"$got" && echo 0 || echo 1)"

  # rm command with the new schema
  HOME="$home" bash "$ROOT/islet.sh" rm opencode >/dev/null 2>&1 </dev/null
  assert_eq 'rm agent' "$(jq_get "$home/.config/islet/config.json" '.agent // "{}"')" '{}'
  rm -rf "$home"
}

# --- run: -v extra volumes -----------------------------------------------------

t_run_volumes_flag() {
  printf 'run agent — -v extra volumes flag\n'
  local home; home="$(mktemp -d)"
  mkdir -p "$home/.config/islet" "$home/ws" "$home/ssh" "$home/sub/deep"
  cat > "$home/.config/islet/config.json" <<'JSON'
{
  "$schema": "islet.sh",
  "container": "opencode",
  "agent": {
    "opencode": { "image": "islet/opencode:latest" }
  }
}
JSON
  make_fake_docker
  rm -f /tmp/islet-fake-docker.log

  # Existing dir mounts as-is.
  HOME="$home" PATH="$FAKEBIN:$PATH" bash "$ROOT/islet.sh" opencode "$home/ws" \
    -v "$home/ssh:/root/.ssh:ro,$home/sub:/work" >/dev/null 2>&1
  local got; got="$(cat /tmp/islet-fake-docker.log 2>/dev/null)"
  check 'two -v volumes mounted' \
    "$(grep -q -- "--volume $home/ssh:/root/.ssh:ro" <<<"$got" \
      && grep -q -- "--volume $home/sub:/work" <<<"$got" && echo 0 || echo 1)"

  # Missing host dir -> error exit, no docker run.
  rm -f /tmp/islet-fake-docker.log
  HOME="$home" PATH="$FAKEBIN:$PATH" bash "$ROOT/islet.sh" opencode "$home/ws" \
    -v "$home/missing:/x" >/dev/null 2>&1 </dev/null || true
  check 'missing host dir rejected' "$(grep -q docker /tmp/islet-fake-docker.log 2>/dev/null && echo 1 || echo 0)"

  # Malformed spec -> error exit.
  rm -f /tmp/islet-fake-docker.log
  HOME="$home" PATH="$FAKEBIN:$PATH" bash "$ROOT/islet.sh" opencode "$home/ws" \
    -v 'no-colon-here' >/dev/null 2>&1 </dev/null || true
  check 'malformed -v rejected' "$(grep -q docker /tmp/islet-fake-docker.log 2>/dev/null && echo 1 || echo 0)"

  # '!' escapes ":" in a container path; ~ expands to home; lone "!" is kept.
  HOME="$home" PATH="$FAKEBIN:$PATH" bash "$ROOT/islet.sh" opencode "$home/ws" \
    -v '~/ssh:keys!:one' >/dev/null 2>&1 </dev/null
  got="$(cat /tmp/islet-fake-docker.log 2>/dev/null)"
  check '~ and ! work (~/ssh -> keys:one)' \
    "$(grep -q -- "--volume $home/ssh:keys:one" <<<"$got" && echo 0 || echo 1)"

  rm -rf "$home"
}

# --- islet setup via flags ---------------------------------------------------

t_setup_flags() {
  printf 'islet setup — flags skip wizard steps\n'
  local home; home="$(mktemp -d)"
  make_fake_docker

  # All flags set -> no stdin needed; </dev/null proves it.
  # --config-volume is now an optional override of the agent data folder.
  HOME="$home" bash "$ROOT/islet.sh" setup \
    --name flagagent \
    --image 'img:flags:1' \
    --preinstall 'Node.js, C/C++' \
    --config-volume "~/.config/flagcfg" \
    --network bridge \
    --env 'K=v' \
    >/dev/null 2>&1 </dev/null
  local cfg="$home/.config/islet/config.json"
  check 'flag config created'     "$([[ -f "$cfg" ]]; echo $?)"
  assert_eq 'flag name'           "$(jq_get "$cfg" '.container')"                    'flagagent'
  assert_eq 'flag image'          "$(jq_get "$cfg" '.agent.flagagent.image')"        'img:flags:1'
  assert_eq 'flag preinstall'     "$(jq_get "$cfg" '.agent.flagagent.preinstall | join(" ")')" 'Node.js C/C++'
  assert_eq 'flag config volume'  "$(jq_get "$cfg" '.agent.flagagent.volume_config')" '~/.config/flagcfg'
  assert_eq 'flag network'        "$(jq_get "$cfg" '.agent.flagagent.network')"      'bridge'
  assert_eq 'flag env'            "$(jq_get "$cfg" '.agent.flagagent.environment.K')" 'v'

  # Mixed: only --name and --network set, rest still prompted
  # (image, preinstall, env); no config-volume prompt anymore.
  printf '%s\n' 'img:mixed' '' '' \
    | HOME="$home" bash "$ROOT/islet.sh" setup --name mixed --network bridge >/dev/null 2>&1
  assert_eq 'mixed image'         "$(jq_get "$cfg" '.agent.mixed.image')"            'img:mixed'
  assert_eq 'mixed network'       "$(jq_get "$cfg" '.agent.mixed.network')"          'bridge'
  assert_eq 'mixed no config key' "$(jq_get "$cfg" '.agent.mixed.volume_config // "absent"')" 'absent'

  # Flag validation errors.
  local rc=0
  HOME="$home" bash "$ROOT/islet.sh" setup --network wan >/dev/null 2>&1 </dev/null || rc=$?
  check 'invalid network rejected' "$([[ $rc -ne 0 ]]; echo $?)"
  rc=0
  HOME="$home" bash "$ROOT/islet.sh" setup --preinstall 'Node.js,Bogus' >/dev/null 2>&1 </dev/null || rc=$?
  check 'unknown dep rejected'    "$([[ $rc -ne 0 ]]; echo $?)"
  rc=0
  HOME="$home" bash "$ROOT/islet.sh" setup --bogus x >/dev/null 2>&1 </dev/null || rc=$?
  check 'unknown flag rejected'   "$([[ $rc -ne 0 ]]; echo $?)"

  rm -rf "$home"
}

# --- islet rm keeps the config folder ----------------------------------------

t_rm_keeps_config() {
  printf 'islet rm — full uninstall keeps config.json\n'
  local home; home="$(mktemp -d)"
  mkdir -p "$home/.config/islet" "$home/.local/bin"
  printf '{"$schema":"islet.sh","container":"a1","agent":{"a1":{"image":"img:x"}}}' \
    > "$home/.config/islet/config.json"
  touch "$home/.local/bin/islet"
  printf 'yes\n' | HOME="$home" bash "$ROOT/islet.sh" rm >/dev/null 2>&1
  check 'config.json survived uninstall' \
    "$(jq_get "$home/.config/islet/config.json" '.agent.a1.image' 2>/dev/null | grep -qx 'img:x' && echo 0 || echo 1)"
  check 'islet command removed'   "$([[ ! -e "$home/.local/bin/islet" ]]; echo $?)"
  check 'config folder survived'  "$([[ -d "$home/.config/islet" ]]; echo $?)"

  rm -rf "$home"
}

# --- islet setup -------------------------------------------------------------

t_setup() {
  printf 'islet setup — 5-step wizard into config.json\n'
  local home; home="$(mktemp -d)"
  make_fake_docker

  # Answers: name (pi), image, preinstall toggle '2 7' (Node.js Ruby),
  # confirm, network (2 = bridge), env.
  printf '%s\n' 'pi' 'img:pi:2' '2 7' '' '2' 'FOO=2' \
    | HOME="$home" bash "$ROOT/islet.sh" setup >/dev/null 2>&1
  local cfg="$home/.config/islet/config.json"
  check 'config created'          "$([[ -f "$cfg" ]]; echo $?)"
  assert_eq 'entry name'          "$(jq_get "$cfg" '.container')"               'pi'
  assert_eq 'image'               "$(jq_get "$cfg" '.agent.pi.image')"          'img:pi:2'
  assert_eq 'preinstall saved'    "$(jq_get "$cfg" '.agent.pi.preinstall | join(" ")')" 'Node.js Ruby'
  assert_eq 'no volume keys'      "$(jq_get "$cfg" '.agent.pi.volume_config // "absent"')" 'absent'
  assert_eq 'network'             "$(jq_get "$cfg" '.agent.pi.network')"        'bridge'
  assert_eq 'environment'         "$(jq_get "$cfg" '.agent.pi.environment.FOO')" '2'

  # Sibling kept on the second setup; same name replaces its own entry.
  HOME="$home" bash "$ROOT/install.sh" --config-dir "$home/none" >/dev/null 2>&1 </dev/null || true
  printf '%s\n' 'sib' 'sib:img' '' '' '' \
    | HOME="$home" bash "$ROOT/islet.sh" setup >/dev/null 2>&1
  printf '%s\n' 'pi' 'pi:v2' '' '' '' \
    | HOME="$home" bash "$ROOT/islet.sh" setup >/dev/null 2>&1
  assert_eq 'sibling kept'        "$(jq_get "$cfg" '.agent.sib.image')"         'sib:img'
  assert_eq 'entry replaced'      "$(jq_get "$cfg" '.agent.pi.image')"          'pi:v2'
  assert_eq 'preinstall replaced' "$(jq_get "$cfg" '.agent.pi.preinstall')"     '[]'

  # Run the saved entry end-to-end (fake docker): preinstall is baked into
  # a derived image, the agent data folder is mounted (deps + config).
  mkdir -p "$home/ws"; rm -f /tmp/islet-fake-docker.log
  HOME="$home" PATH="$FAKEBIN:$PATH" bash "$ROOT/islet.sh" pi "$home/ws" >/dev/null 2>&1
  local got; got="$(cat /tmp/islet-fake-docker.log 2>/dev/null)"
  check 'runs the saved entry' \
    "$(grep -q -- '--volume '"$home"'/ws:/workspace' <<<"$got" && echo 0 || echo 1)"
  check 'derived preinstall image' "$(grep -q 'islet-pre:pi-' <<<"$got" && echo 0 || echo 1)"
  check 'agent folder config mount' \
    "$(grep -q -- "--volume $home/.config/islet/pi/config:/root/.config/pi" <<<"$got" && echo 0 || echo 1)"
  check 'agent folder sessions mount' \
    "$(grep -q -- "--volume $home/.config/islet/pi/sessions:/root/.local/share/pi" <<<"$got" && echo 0 || echo 1)"
  check 'deps hub mounted' \
    "$(grep -q -- "--volume $home/.config/islet/pi/deps:/opt/islet-tools" <<<"$got" && echo 0 || echo 1)"
  check 'deps pip mount' \
    "$(grep -q -- "--volume $home/.config/islet/pi/deps:/root/.local" <<<"$got" && echo 0 || echo 1)"
  check 'apk cache inside deps' \
    "$(grep -q -- "--volume $home/.config/islet/pi/deps/apk-cache:/var/cache/apk" <<<"$got" && echo 0 || echo 1)"
  check 'pi agent dir redirect env' \
    "$(grep -q -- '--env PI_CODING_AGENT_DIR=/root/.config/pi' <<<"$got" && echo 0 || echo 1)"
  rm -rf "$home"
}


t_syntax
t_install
t_install_flag
t_install_keeps_config
t_create
t_build
t_run_schema
t_run_volumes_flag
t_rm_keeps_config
t_setup
t_setup_flags

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))

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
  printf 'islet create — agent + preinstall environment\n'
  local tmp; tmp="$(mktemp -d)"
  # Answers: agent (1), preinstall toggle '2 7' (Node.js Ruby), confirm.
  printf '1\n2 7\n\n' | HOME="$tmp" PATH="$FAKEBIN:$PATH" bash "$ROOT/islet.sh" create "$tmp" >/dev/null 2>&1
  check 'opencode.Dockerfile created'  "$([[ -f "$tmp/opencode.Dockerfile" ]]; echo $?)"
  assert_eq 'alpine base'              "$(grep -m1 '^FROM alpine' "$tmp/opencode.Dockerfile")" 'FROM alpine:latest'
  check 'preinstall baked (nodejs npm)' \
    "$(grep -q 'nodejs npm' "$tmp/opencode.Dockerfile" && echo 0 || echo 1)"
  check 'preinstall baked (ruby)'      "$(grep -q 'ruby' "$tmp/opencode.Dockerfile" && echo 0 || echo 1)"

  # Skip the preinstall list (empty toggle line) -> plain apk line only.
  printf '3\n\n' | HOME="$tmp" bash "$ROOT/islet.sh" create "$tmp" >/dev/null 2>&1
  check 'hermes preinstall skipped' \
    "$(grep -A1 'apk add' "$tmp/hermes.Dockerfile" | grep -Eq 'nodejs|openjdk|cargo' && echo 1 || echo 0)"
  # pi with Git preselected.
  printf '2\n1\n\n' | HOME="$tmp" bash "$ROOT/islet.sh" create /tmp/pi-test.Dockerfile >/dev/null 2>&1
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
  check 'libs volume (apk cache)' "$(grep -q -- "--volume $home/.local/share/islet/opencode-libs:/var/cache/apk" <<<"$got" && echo 0 || echo 1)"
  check 'sessions volume'      "$(grep -q -- "--volume $home/.local/share/islet/opencode-sessions:/root/.local/share/opencode" <<<"$got" && echo 0 || echo 1)"
  check 'port published'       "$(grep -q -- '--publish 8080:8080' <<<"$got" && echo 0 || echo 1)"
  check 'env var'              "$(grep -q -- '--env API_KEY=abc' <<<"$got" && echo 0 || echo 1)"
  check 'image last'           "$(grep -q ' islet/opencode:latest$' <<<"$got" && echo 0 || echo 1)"

  # rm command with the new schema
  HOME="$home" bash "$ROOT/islet.sh" rm opencode >/dev/null 2>&1 </dev/null
  assert_eq 'rm agent' "$(jq_get "$home/.config/islet/config.json" '.agent // "{}"')" '{}'
  rm -rf "$home"
}

# --- islet setup -------------------------------------------------------------

t_setup() {
  printf 'islet setup — 5-step wizard into config.json\n'
  local home; home="$(mktemp -d)"
  make_fake_docker

  # Answers: name (pi), image, config volume, network (2 = bridge), env.
  printf 'pi\nimg:pi:2\n\n2\nFOO=2\n' \
    | HOME="$home" bash "$ROOT/islet.sh" setup >/dev/null 2>&1
  local cfg="$home/.config/islet/config.json"
  check 'config created'          "$([[ -f "$cfg" ]]; echo $?)"
  assert_eq 'entry name'          "$(jq_get "$cfg" '.container')"               'pi'
  assert_eq 'image'               "$(jq_get "$cfg" '.agent.pi.image')"          'img:pi:2'
  assert_eq 'config volume'       "$(jq_get "$cfg" '.agent.pi.volume_config')"  '~/.config/pi'
  assert_eq 'libs volume'         "$(jq_get "$cfg" '.agent.pi.volume_libs')"    '~/.local/share/islet/pi-libs'
  assert_eq 'network'             "$(jq_get "$cfg" '.agent.pi.network')"        'bridge'
  assert_eq 'environment'         "$(jq_get "$cfg" '.agent.pi.environment.FOO')" '2'

  # Sibling kept on the second setup; same name replaces its own entry.
  HOME="$home" bash "$ROOT/install.sh" --config-dir "$home/none" >/dev/null 2>&1 </dev/null || true
  printf 'sib\nsib:img\n\n\n\n' \
    | HOME="$home" bash "$ROOT/islet.sh" setup >/dev/null 2>&1
  printf 'pi\npi:v2\n\n1\n\n' \
    | HOME="$home" bash "$ROOT/islet.sh" setup >/dev/null 2>&1
  assert_eq 'sibling kept'        "$(jq_get "$cfg" '.agent.sib.image')"         'sib:img'
  assert_eq 'entry replaced'      "$(jq_get "$cfg" '.agent.pi.image')"          'pi:v2'

  # Run the saved entry end-to-end (fake docker).
  mkdir -p "$home/ws"; rm -f /tmp/islet-fake-docker.log
  HOME="$home" PATH="$FAKEBIN:$PATH" bash "$ROOT/islet.sh" pi "$home/ws" >/dev/null 2>&1
  check 'runs the saved entry' \
    "$(grep -q -- '--volume '"$home"'/ws:/workspace' /tmp/islet-fake-docker.log 2>/dev/null && \
      grep -q ' pi:v2$' /tmp/islet-fake-docker.log 2>/dev/null && echo 0 || echo 1)"
  rm -rf "$home"
}


t_syntax
t_install
t_install_flag
t_create
t_build
t_run_schema
t_setup

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))

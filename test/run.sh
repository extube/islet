#!/usr/bin/env bash
# test/run.sh — minimal manual test suite for the islet shell scripts.
#
# No framework: a small set of assertion helpers plus scenario scripts that
# drive install.sh in isolated HOME dirs with piped stdin, checking the
# resulting config.json with jq.
#
# Usage: bash test/run.sh

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0 fail=0

# check <description> <condition-result>
check() {
  local desc="$1" result="$2"
  if [[ "$result" == 0 ]]; then
    printf '  %sPASS%s %s\n' "$(tput setaf 2 2>/dev/null || true)" '' "$desc" | sed 's/^  PASS/  ✔/'
    pass=$((pass + 1))
  else
    printf '  %sFAIL%s %s\n' "$(tput setaf 1 2>/dev/null || true)" '' "$desc" | sed 's/^  FAIL/  ✖/'
    fail=$((fail + 1))
  fi
}

# assert_eq <description> <actual> <expected>
assert_eq() {
  check "$1" "$([[ "$2" == "$3" ]] && echo 0 || echo 1)"
}

# jq_get <file> <jq-filter> — prints the filtered value.
jq_get() {
  jq -r "$2" "$1"
}

# run_install <home> [args...] — runs the installer with piped stdin.
# stdin must already contain the wizard answers.
run_install() {
  local home="$1"; shift
  HOME="$home" bash "$ROOT/install.sh" "$@" </dev/null >/dev/null 2>&1
}

# --- syntax checks -----------------------------------------------------------

t_syntax() {
  printf 'syntax\n'
  for script in install.sh islet.sh islet.dev.sh test/run.sh; do
    check "$script" "$(bash -n "$ROOT/$script" 2>&1 && echo 0 || echo 1)"
  done
}

# --- fresh install: defaults via piped answers -------------------------------

t_defaults() {
  printf 'fresh install — defaults\n'
  local home; home="$(mktemp -d)"
  # Order: docker-missing prompt (y), config folder, preinstall (skip),
  # image (default), agent config dir, container name, network, env.
  # Seek order: docker-missing (y), config folder (default), preinstall
  # (skip = empty toggle line), image (default), agent config dir (default),
  # container name (myagent), network (default host), env (skip).
  local answers='y\n\n\n\n\nmyagent\n\n\n'
  printf "$answers" | HOME="$home" bash "$ROOT/install.sh" >/dev/null 2>&1

  local cfg="$home/.config/islet/config.json"
  check 'config file created' "$([[ -f "$cfg" ]]; echo $?)"
  if [[ -f "$cfg" ]]; then
    assert_eq 'default image' \
      "$(jq_get "$cfg" '.agent.myagent.image')" \
      'ghcr.io/anomalyco/opencode:latest'
    assert_eq 'container name saved' \
      "$(jq_get "$cfg" '.agent.myagent.container_name')" \
      'myagent'
    assert_eq 'default network' \
      "$(jq_get "$cfg" '.agent.myagent.network')" \
      'host'
  fi
  rm -rf "$home"
}

# --- flags skip steps --------------------------------------------------------

t_flags() {
  printf 'flags skip wizard steps\n'
  local home; home="$(mktemp -d)"
  HOME="$home" bash "$ROOT/install.sh" \
    --image custom/img:v2 \
    --container-name agent1 \
    --network bridge \
    --ports '8080:8080,3000:3000' \
    --env 'API_KEY=abc,FOO=bar' \
    --preinstall 'Node.js,Go' \
    --agent-config-dir '~/.config/agent' \
    </dev/null >/dev/null 2>&1

  local cfg="$home/.config/islet/config.json"
  check 'config file created' "$([[ -f "$cfg" ]]; echo $?)"
  if [[ -f "$cfg" ]]; then
    assert_eq 'flag image'        "$(jq_get "$cfg" '.agent.agent1.image')"                'custom/img:v2'
    assert_eq 'flag container_name' "$(jq_get "$cfg" '.agent.agent1.container_name')"     'agent1'
    assert_eq 'flag network'      "$(jq_get "$cfg" '.agent.agent1.network')"              'bridge'
    assert_eq 'flag ports'        "$(jq_get "$cfg" '.agent.agent1.ports[1]')"             '3000:3000'
    assert_eq 'flag environment'  "$(jq_get "$cfg" '.agent.agent1.environment.API_KEY')"  'abc'
    assert_eq 'flag preinstall'   "$(jq_get "$cfg" '.agent.agent1.preinstall[1]')"        'Go'
    assert_eq 'flag agent_config_dir' "$(jq_get "$cfg" '.agent.agent1.agent_config_dir')" '~/.config/agent'
  fi
  rm -rf "$home"
}

# --- overwrite prompt --------------------------------------------------------

t_overwrite() {
  printf 'overwrite prompt on existing config\n'
  local home; home="$(mktemp -d)"
  mkdir -p "$home/.config/islet"
  printf '{}' > "$home/.config/islet/config.json"

  # Answer "n" — must abort and keep the original file.
  printf 'n\n' | HOME="$home" bash "$ROOT/install.sh" >/dev/null 2>&1
  check 'decline overwrite aborts, config untouched' \
    "$([[ "$(cat "$home/.config/islet/config.json")" == '{}' ]]; echo $?)"

  # Answer "y" — a full config is written.
  # Seek order: overwrite (y), docker-missing (y), config folder, preinstall
  # (skip), image (default), agent config dir, container name, network, env.
  printf 'y\ny\n\n\n\n\n\n\n\n\n' | HOME="$home" bash "$ROOT/install.sh" >/dev/null 2>&1
  check 'accept overwrite rewrites config' \
    "$([[ "$(jq_get "$home/.config/islet/config.json" '.agent.opencode.network')" == 'host' ]]; echo $?)"
  rm -rf "$home"
}

# --- flag validation ----------------------------------------------------------

t_validation() {
  printf 'flag validation\n'
  local home; home="$(mktemp -d)"
  local out; out="$(mktemp)"
  HOME="$home" bash "$ROOT/install.sh" --network warp </dev/null >"$out" 2>&1 || true
  check '--network rejects bad value' \
    "$(grep -q "must be 'host' or 'bridge'" "$out" && echo 0 || echo 1)"
  HOME="$home" bash "$ROOT/install.sh" --ports 'abc' </dev/null >"$out" 2>&1 || true
  check '--ports rejects bad value' "$(grep -q -- '--ports must be' "$out" && echo 0 || echo 1)"
  HOME="$home" bash "$ROOT/install.sh" --env 'NOEQUALS' </dev/null >"$out" 2>&1 || true
  check '--env rejects bad value' "$(grep -q -- '--env must be' "$out" && echo 0 || echo 1)"
  HOME="$home" bash "$ROOT/install.sh" --bogus </dev/null >"$out" 2>&1 || true
  check 'unknown flag rejected' "$(grep -q -- 'unknown flag: --bogus' "$out" && echo 0 || echo 1)"
  rm -rf "$home" "$out"
}

t_syntax
t_defaults
t_flags
t_overwrite
t_validation

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

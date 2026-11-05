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

# --- config-dir: validated template agent config dir --------------------------

t_config_dir() {
  printf 'config-dir — template agent dir (validated, copied at creation)\n'
  local home; home="$(mktemp -d)"
  mkdir -p "$home/ws" "$home/.config/islet" "$home/tpl-ok"
  printf '{ "$schema": "islet.sh", "agent": {} }\n' > "$home/.config/islet/config.json"
  make_fake_docker
  printf '%s\n' '{"$schema": "https://opencode.ai/config.json", "permission": "allow"}' \
    > "$home/tpl-ok/opencode.json"

  # Prompt order for an unknown name: create? (y), base agent (1 = opencode),
  # preinstall toggle+confirm (''), network (1 = host), env ('').
  run_create_agent() { # <agent-name> <template-dir>
    printf '%s\n' 'y' '1' '' '1' '' \
      | HOME="$home" PATH="$FAKEBIN:$PATH" bash "$ROOT/islet.sh" \
          "$1" --config-dir "$2" "$home/ws"
  }
  run_create_agent ocdir "$home/tpl-ok" >/dev/null 2>&1
  local seeded="$home/.config/islet/ocdir/config/opencode.json"
  check 'template copied into agent config dir' "$([[ -f "$seeded" ]]; echo $?)"
  assert_eq 'template contents preserved' "$(jq_get "$seeded" '.permission')" 'allow'

  # Invalid JSON in the template -> creation dies, nothing copied.
  mkdir -p "$home/tpl-bad"
  printf '{ "schema": broken' > "$home/tpl-bad/opencode.json"
  local rc=0
  run_create_agent bad-agent "$home/tpl-bad" >/dev/null 2>&1 </dev/null || rc=$?
  check 'invalid template rejected' "$([[ $rc -ne 0 ]]; echo $?)"
  check 'nothing copied for bad template' \
    "$([[ ! -d "$home/.config/islet/bad-agent" ]]; echo $?)"

  # opencode template without a config file -> rejected.
  mkdir -p "$home/tpl-nocfg" && printf 'readme\n' > "$home/tpl-nocfg/README"
  rc=0
  run_create_agent nocfg "$home/tpl-nocfg" >/dev/null 2>&1 </dev/null || rc=$?
  check 'opencode template without config file rejected' "$([[ $rc -ne 0 ]]; echo $?)"

  # Nonempty check: an empty template dir -> rejected.
  mkdir -p "$home/tpl-empty"
  rc=0
  run_create_agent empty-tpl "$home/tpl-empty" >/dev/null 2>&1 </dev/null || rc=$?
  check 'empty template dir rejected' "$([[ $rc -ne 0 ]]; echo $?)"

  # Missing template dir -> rejected.
  rc=0
  run_create_agent no-tpl "$home/no-such-dir" >/dev/null 2>&1 </dev/null || rc=$?
  check 'missing template dir rejected' "$([[ $rc -ne 0 ]]; echo $?)"

  # opencode.jsonc template: comments stripped for validation, file copied
  # verbatim into the agent config dir.
  mkdir -p "$home/tpl-jsonc"
  printf '{ /* note */ "$schema": "https://opencode.ai/config.json", // line\n"permission": "allow" }\n' \
    > "$home/tpl-jsonc/opencode.jsonc"
  run_create_agent ocjsonc "$home/tpl-jsonc" >/dev/null 2>&1 </dev/null
  check 'jsonc template accepted' \
    "$([[ -f "$home/.config/islet/ocjsonc/config/opencode.jsonc" ]]; echo $?)"

  # pi-family base: no single config file expected, template still copied.
  mkdir -p "$home/tpl-pi" && printf 'themes\n' > "$home/tpl-pi/ext"
  printf '%s\n' 'y' '3' '' '1' '' \
    | HOME="$home" PATH="$FAKEBIN:$PATH" bash "$ROOT/islet.sh" \
        pidir --config-dir "$home/tpl-pi" "$home/ws" >/dev/null 2>&1
  check 'pi template accepted and copied' \
    "$([[ -f "$home/.config/islet/pidir/config/ext" ]]; echo $?)"

  # Already-populated config dir is not clobbered; setup still succeeds.
  mkdir -p "$home/tpl-ok2"
  printf '{"permission": "ask"}' > "$home/tpl-ok2/opencode.json"
  rm -rf "$home/.config/islet/ocdir2"
  printf '%s\n' 'y' '1' '' '1' '' \
    | HOME="$home" PATH="$FAKEBIN:$PATH" bash "$ROOT/islet.sh" \
        ocdir2 --config-dir "$home/tpl-ok" "$home/ws" >/dev/null 2>&1
  printf '%s\n' 'y' '1' '' '1' '' \
    | HOME="$home" PATH="$FAKEBIN:$PATH" bash "$ROOT/islet.sh" \
        ocdir2 --config-dir "$home/tpl-ok2" "$home/ws" >/dev/null 2>&1
  assert_eq 'existing seeded config kept' \
    "$(jq_get "$home/.config/islet/ocdir2/config/opencode.json" '.permission')" 'allow'

  # Alias run flow: --config-dir is forwarded to the wizard for a new agent.
  home="$(mktemp -d)"
  make_fake_docker
  mkdir -p "$home/ws" "$home/.config/islet"
  printf '{ "$schema": "islet.sh", "agent": {} }\n' > "$home/.config/islet/config.json"
  rm -f /tmp/islet-fake-docker.log
  mkdir -p "$home/tpl-ok"
  printf '%s\n' '{"$schema": "https://opencode.ai/config.json", "permission": "allow"}' \
    > "$home/tpl-ok/opencode.json"
  printf '%s\n' '' '1' '' \
    | HOME="$home" PATH="$FAKEBIN:$PATH" bash "$ROOT/islet.sh" \
        opencode --config-dir "$home/tpl-ok" "$home/ws" >/dev/null 2>&1
  local cfg="$home/.config/islet/config.json"
  assert_eq 'alias entry saved' "$(jq_get "$cfg" '.agent.opencode.image')" 'islet/opencode:latest'
  check 'alias flow seeded the template' \
    "$([[ -f "$home/.config/islet/opencode/config/opencode.json" ]]; echo $?)"

  # Already-configured agent: --config-dir is ignored (notice), run works.
  rm -f /tmp/islet-fake-docker.log
  HOME="$home" PATH="$FAKEBIN:$PATH" bash "$ROOT/islet.sh" \
    opencode --config-dir "$home/tpl-ok" "$home/ws" >/dev/null 2>&1 </dev/null
  check 'configured alias: still runs with --config-dir' \
    "$(grep -q docker /tmp/islet-fake-docker.log 2>/dev/null && echo 0 || echo 1)"

  rm -rf "$home"
}

# --- islet update -------------------------------------------------------------

t_update() {
  printf 'islet update — re-runs the installer, keeps the config\n'
  local home; home="$(mktemp -d)"
  mkdir -p "$home/.config/islet"
  printf '{"$schema":"islet.sh","container":"myagent","agent":{"myagent":{"image":"img:x"}}}' \
    > "$home/.config/islet/config.json"

  # Prompts: docker-missing (y), islet config folder (default).
  printf 'y\n\n' | env ISLET_INSTALL_URL="file://$ROOT/install.sh" \
    HOME="$home" PATH="$FAKEBIN:$PATH" \
    bash "$ROOT/islet.sh" update >/dev/null 2>&1
  check 'islet command present' "$([[ -x "$home/.local/bin/islet" ]]; echo $?)"
  assert_eq 'config kept through update' \
    "$(jq_get "$home/.config/islet/config.json" '.agent.myagent.image')" 'img:x'
  rm -rf "$home"
}

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

# --- creation wizard: unknown name -> create + five-step flow -----------------

t_setup() {
  printf 'creation wizard — unknown-name flow into config.json\n'
  local home; home="$(mktemp -d)"
  mkdir -p "$home/ws" "$home/.config/islet"
  printf '{ "$schema": "islet.sh", "agent": {} }\n' > "$home/.config/islet/config.json"
  make_fake_docker

  # Answer lines: create? y, base agent 4 (hermes), preinstall '2 7' + ''
  # confirm (name/image are passed implicitly — no prompts), network 2
  # (bridge), env FOO=2.
  printf '%s\n' 'y' '4' '2 7' '' '2' 'FOO=2' \
    | HOME="$home" PATH="$FAKEBIN:$PATH" bash "$ROOT/islet.sh" cust "$home/ws" >/dev/null 2>&1
  local cfg="$home/.config/islet/config.json"
  check 'config created' "$([[ -f "$cfg" ]]; echo $?)"
  assert_eq 'entry name' "$(jq_get "$cfg" '.container')" 'cust'
  assert_eq 'image from base build' "$(jq_get "$cfg" '.agent.cust.image')" 'islet/hermes:latest'
  assert_eq 'preinstall saved' "$(jq_get "$cfg" '.agent.cust.preinstall | join(" ")')" 'Node.js Ruby'
  assert_eq 'no volume keys' "$(jq_get "$cfg" '.agent.cust.volume_config // "absent"')" 'absent'
  assert_eq 'network' "$(jq_get "$cfg" '.agent.cust.network')" 'bridge'
  assert_eq 'environment' "$(jq_get "$cfg" '.agent.cust.environment.FOO')" '2'

  # Second creation keeps the first entry (merge semantics).
  printf '%s\n' 'y' '1' '' '1' '' \
    | HOME="$home" PATH="$FAKEBIN:$PATH" bash "$ROOT/islet.sh" sib "$home/ws" >/dev/null 2>&1
  assert_eq 'sibling kept' "$(jq_get "$cfg" '.agent.cust.image')" 'islet/hermes:latest'
  assert_eq 'sibling created' "$(jq_get "$cfg" '.agent.sib.image')" 'islet/opencode:latest'
  assert_eq 'default container stays first' "$(jq_get "$cfg" '.container')" 'cust'

  # Base-agent choice 2 = opencode v2.
  printf '%s\n' 'y' '2' '' '1' '' \
    | HOME="$home" PATH="$FAKEBIN:$PATH" bash "$ROOT/islet.sh" v2sib "$home/ws" >/dev/null 2>&1
  assert_eq 'base opencode2' "$(jq_get "$cfg" '.agent.v2sib.image')" 'islet/opencode2:latest'

  # Decline creation -> unknown-agent error, nothing saved.
  local rc=0
  printf 'n\n' | HOME="$home" PATH="$FAKEBIN:$PATH" bash "$ROOT/islet.sh" \
    deny-robot "$home/ws" >/dev/null 2>&1 || rc=$?
  check 'declined creation rejected' "$([[ $rc -ne 0 ]]; echo $?)"
  assert_eq 'declined not saved' "$(jq_get "$cfg" '.agent."deny-robot" // "absent"')" 'absent'

  # Invalid agent name rejected before the wizard runs.
  rc=0
  printf '%s\n' 'y' '1' '' '1' '' \
    | HOME="$home" PATH="$FAKEBIN:$PATH" bash "$ROOT/islet.sh" \
    'bad/name!' "$home/ws" >/dev/null 2>&1 || rc=$?
  check 'invalid agent name rejected' "$([[ $rc -ne 0 ]]; echo $?)"

  # Run the saved entry end-to-end (fake docker): preinstall is baked into
  # a derived image, the agent data folder is mounted (deps + config).
  rm -f /tmp/islet-fake-docker.log
  HOME="$home" PATH="$FAKEBIN:$PATH" bash "$ROOT/islet.sh" cust "$home/ws" >/dev/null 2>&1 </dev/null
  local got; got="$(cat /tmp/islet-fake-docker.log 2>/dev/null)"
  check 'runs the saved entry' \
    "$(grep -q -- '--volume '"$home"'/ws:/workspace' <<<"$got" && echo 0 || echo 1)"
  check 'derived preinstall image' "$(grep -q 'islet-pre:cust-' <<<"$got" && echo 0 || echo 1)"
  check 'agent folder config mount' \
    "$(grep -q -- "--volume $home/.config/islet/cust/config:/root/.config/hermes" <<<"$got" && echo 0 || echo 1)"
  check 'agent folder sessions mount' \
    "$(grep -q -- "--volume $home/.config/islet/cust/sessions:/root/.local/share/hermes" <<<"$got" && echo 0 || echo 1)"
  check 'deps hub mounted' \
    "$(grep -q -- "--volume $home/.config/islet/cust/deps:/opt/islet-tools" <<<"$got" && echo 0 || echo 1)"

  rm -rf "$home"
}

# --- run <alias>: on-the-spot agent creation (build image + setup) ------------

t_run_alias() {
  printf 'islet <agent> — create-and-run flow when not configured yet\n'
  local home; home="$(mktemp -d)"
  mkdir -p "$home/.config/islet" "$home/ws"
  cat > "$home/.config/islet/config.json" <<'JSON'
{ "$schema": "islet.sh", "agent": {} }
JSON
  make_fake_docker
  rm -f /tmp/islet-fake-docker.log

  # Setup prompts come after the image build: preinstall (confirm none),
  # network (1 = host), env (empty = skip).
  printf '%s\n' '' '1' '' \
    | HOME="$home" PATH="$FAKEBIN:$PATH" bash "$ROOT/islet.sh" opencode "$home/ws" >/dev/null 2>&1
  local cfg="$home/.config/islet/config.json"
  assert_eq 'alias entry saved' \
    "$(jq_get "$cfg" '.agent.opencode.image')" 'islet/opencode:latest'
  local got; got="$(cat /tmp/islet-fake-docker.log 2>/dev/null)"
  check 'harness image built' \
    "$(grep -q -- 'docker build -t islet/opencode:latest' <<<"$got" && echo 0 || echo 1)"
  check 'runs after setup' \
    "$(grep -q -- '--volume '"$home"'/ws:/workspace' <<<"$got" && echo 0 || echo 1)"

  # Second invocation: entry exists -> plain run, no rebuild, no setup.
  rm -f /tmp/islet-fake-docker.log
  HOME="$home" PATH="$FAKEBIN:$PATH" bash "$ROOT/islet.sh" opencode "$home/ws" </dev/null >/dev/null 2>&1
  got="$(cat /tmp/islet-fake-docker.log 2>/dev/null)"
  check 'configured alias: no rebuild' \
    "$(grep -q 'docker build' <<<"$got" && echo 1 || echo 0)"
  check 'configured alias: runs' \
    "$(grep -q -- '--volume '"$home"'/ws:/workspace' <<<"$got" && echo 0 || echo 1)"

  # opencode-v2 alias normalizes to the canonical opencode2 name.
  printf '%s\n' '' '1' '' \
    | HOME="$home" PATH="$FAKEBIN:$PATH" bash "$ROOT/islet.sh" opencode-v2 "$home/ws" >/dev/null 2>&1
  assert_eq 'opencode-v2 alias' \
    "$(jq_get "$cfg" '.agent.opencode2.image')" 'islet/opencode2:latest'

  rm -rf "$home"

  # A moved agent keeps its previous image: after `islet mv opencode
  # agent-007` the tag islet/opencode:latest is claimed, so a new
  # `islet opencode` builds under a fresh unique tag.
  home="$(mktemp -d)"
  mkdir -p "$home/.config/islet" "$home/ws"
  cat > "$home/.config/islet/config.json" <<'JSON'
{
  "$schema": "islet.sh",
  "container": "agent-007",
  "agent": { "agent-007": { "image": "islet/opencode:latest" } }
}
JSON
  rm -f /tmp/islet-fake-docker.log
  printf '%s\n' '' '1' '' \
    | HOME="$home" PATH="$FAKEBIN:$PATH" bash "$ROOT/islet.sh" opencode "$home/ws" >/dev/null 2>&1
  local new_image
  new_image="$(jq_get "$home/.config/islet/config.json" '.agent.opencode.image')"
  check 'moved: fresh unique tag' \
    "$([[ "$new_image" =~ ^islet/opencode:[0-9]{8}-[0-9]{6}$ ]] && [[ "$new_image" != 'islet/opencode:latest' ]]; echo $?)"
  assert_eq 'moved: agent-007 keeps image' \
    "$(jq_get "$home/.config/islet/config.json" '.agent."agent-007".image')" 'islet/opencode:latest'
  rm -rf "$home"

  # Unknown (non-alias) names still fail.
  home="$(mktemp -d)"
  mkdir -p "$home/.config/islet"
  printf '{ "$schema": "islet.sh", "agent": {} }\n' >"$home/.config/islet/config.json"
  local rc=0
  HOME="$home" PATH="$FAKEBIN:$PATH" bash "$ROOT/islet.sh" nosuchagent >/dev/null 2>&1 </dev/null || rc=$?
  check 'unknown name rejected' "$([[ $rc -ne 0 ]]; echo $?)"
  rm -rf "$home"
}

# --- mv: rename an agent ------------------------------------------------------

t_mv() {
  printf 'islet mv — rename agent (config key + data folder)\n'
  local home; home="$(mktemp -d)"
  mkdir -p "$home/.config/islet/a/deps" "$home/ws"
  printf 'artifact' >"$home/.config/islet/a/deps/marker"
  cat > "$home/.config/islet/config.json" <<'JSON'
{
  "$schema": "islet.sh",
  "container": "a",
  "agent": {
    "a": { "image": "img-a", "preinstall": ["Node.js"] },
    "sib": { "image": "img-sib" }
  }
}
JSON

  HOME="$home" bash "$ROOT/islet.sh" mv a b >/dev/null 2>&1 </dev/null
  local cfg="$home/.config/islet/config.json"
  assert_eq 'key renamed'        "$(jq_get "$cfg" '.agent.b.image')"             'img-a'
  assert_eq 'old key gone'       "$(jq_get "$cfg" '.agent.a // "gone"'           )" 'gone'
  assert_eq 'sibling kept'       "$(jq_get "$cfg" '.agent.sib.image')"           'img-sib'
  assert_eq 'default container'  "$(jq_get "$cfg" '.container')"                 'b'
  check 'data folder renamed' \
    "$([[ -f "$home/.config/islet/b/deps/marker" ]] && [[ ! -e "$home/.config/islet/a" ]]; echo $?)"

  # mv onto an existing name fails; renaming unknown fails.
  local rc=0
  HOME="$home" bash "$ROOT/islet.sh" mv b sib >/dev/null 2>&1 </dev/null || rc=$?
  check 'mv conflict rejected'   "$([[ $rc -ne 0 ]]; echo $?)"
  rc=0
  HOME="$home" bash "$ROOT/islet.sh" mv missing zzz >/dev/null 2>&1 </dev/null || rc=$?
  check 'mv unknown rejected'    "$([[ $rc -ne 0 ]]; echo $?)"
  rm -rf "$home"
}


t_syntax
t_install
t_install_flag
t_install_keeps_config
t_run_schema
t_run_volumes_flag
t_rm_keeps_config
t_setup
t_run_alias
t_mv
t_config_dir
t_update

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))

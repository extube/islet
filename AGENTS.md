# AGENTS.md

Guidance for AI agents working in this repository.

## Project overview

**islet** is a mini CLI app that runs AI agent harnesses in isolated Docker
containers. It currently supports
[opencode](https://github.com/anomalyco/opencode)
(`ghcr.io/anomalyco/opencode:latest`); support for more agents is planned.

## Repository layout

- `islet.sh` — stable script. Config-driven runner: `islet.sh [name]
  [workspace]` runs the selected agent (sessions and auth persist on the
  host), `-v host:container[,...]` adds one-off extra volume mounts, and
  `islet.sh ps` lists running islet containers. Dependencies are
  config-driven: `agent.<name>.preinstall` is baked into a derived image
  (`islet-pre:<name>-<hash(base image + deps)>`, via `run_deps_image`,
  cached so it survives rebuilds and is only rebuilt when deps or the
  base image change), and the per-agent deps dir
  `~/.config/islet/<name>/deps` is mounted at `/opt/islet-tools` and
  `/root/.local` so installs made *during* a run (apk add, pip --user,
  npm install -g, gem, go) are captured there and persist across runs —
  the derived image sets `PATH`/`NPM_CONFIG_PREFIX`/`GOPATH`/`GEM_HOME`/
  `PYTHONUSERBASE` prefixes into the deps dir plus an `apk` wrapper
  (`/usr/local/bin/apk`, `apk --root .../deps-alpine rootfs`). The
  setup wizard now has six steps (name, image, preinstall multi-select,
  config volume, network, environment) writing `preinstall` into
  config.json — that wizard (setup) is the place where deps are picked;
  flags (`--name`, `--image`, `--preinstall`, `--config-volume`,
  `--network`, `--env`) skip their step with the given value (flagged
  values are validated; steps without a flag are still prompted);
  `islet.sh create` generates a bare agent Dockerfile (fixed runtime,
  no preinstall step) and `islet.sh build` just docker-builds it.
  `islet.sh rm [name]` removes one agent piece from config.json (empty
  `$schema`/`container` keys are dropped when it was the last agent);
  bare `islet.sh rm` uninstalls — after a `y/N` prompt it removes the
  islet-installed commands (`islet`, `islet-dev`) from `~/.local/bin`
  and deliberately keeps the config folder and `config.json` (the
  installer also preserves an existing config).
- `install.sh` — installer. Interactive initialization wizard; **merges**
  the configured agent into the existing config (same-name agents get
  their piece replaced, siblings and the default container are kept) and
  installs a global `islet` command into `~/.local/bin` (downloaded from
  the install URL when running piped).
- `islet-dev.sh` — development version. Universal, config-driven runner
  with preinstall image baking. Active development happens here.
- `README.md` — user-facing documentation.

## install.sh

- `curl -fsSL <url>/install.sh | sh` — curl-pipeable installer. A POSIX shim
  at the top re-runs the script with bash: `sh install.sh` re-execs the same
  file; when piped, the script re-downloads itself (stdin carries the script,
  so it can't be read for answers) to a temp file and runs it with stdin
  attached to `/dev/tty` (`/dev/null` when headless). The download URL can be
  overridden with `ISLET_INSTALL_URL`.
- Checks requirements first: `jq` (required), `docker` (warns and asks to
  continue if missing).
- `install.sh` — run the interactive TUI wizard:
  1. Config folder (default `~/.config/islet`)
  2. Preinstalled environment — TUI multi-select with per-dependency icons
     (Node.js/Go/Java/Python/Rust/Ruby/C/C++; ↑/↓ or j/k move, Tab/Space
     toggle, Enter confirm; falls back to numbered toggles when stdin is
     not a TTY)
  3. Docker image (default `ghcr.io/anomalyco/opencode:latest` or custom)
  4. opencode config folder (default `~/.config/opencode`)
  5. Container name (empty = random, Docker generates one)
  6. Network: host, or port routing (`<port>:<port>,<port>:<port>`)
  7. Environment variables (`KEY=VALUE,KEY=VALUE`)
  Flags (`--config-dir`, `--preinstall`, `--image`, ...) skip their step.
  Saving never overwrites the whole config: the agent is written under
  its key (`<container_name>` or `opencode`) via a jq merge
  (`.agent[key] = entry`, atomic `tmp`+`mv` write).
- Each step is introduced by a boxed TUI header (`ui_box`, `step_header`).
  Box content must be ASCII-only — padding is computed with `${#var}`.
  The greeting box (`print_greeting`) puts the 🏝️ island icon in the top
  border instead, where the dash count is adjusted for its 2-cell width.
- `install.sh --help` — show help.

## islet-dev.sh

- `islet-dev.sh [name] [workspace]` — run an agent from config. No
  subcommands: running the script directly executes the run scenario.
  Arguments are detected by type: an existing directory is the workspace,
  anything else is the agent name. Order-free; both are optional.
- `preinstall` deps are baked into a derived image
  `islet-pre:<agent>-<hash(base image + dep list)>` via `docker build`
  (apt-get packages per dep); the hash-keyed Docker cache keeps the image
  across container rebuilds, so deps and `environment` vars persist.

## Configuration

Stored at `~/.config/islet/config.json` (override location with the
`ISLET_CONFIG_DIR` environment variable):

```json
{
  "$schema": "islet.sh",
  "container": "<default agent name>",
  "agent": {
    "<name>": {
      "image": "ghcr.io/anomalyco/opencode:latest",
      "container_name": "<docker --name; empty = random>",
      "network": "host | bridge",
      "ports": ["8080:8080"],
      "environment": { "API_KEY": "..." },
      "preinstall": ["Node.js"],
      "agent_config_dir": "~/.config/opencode",
      "agent_config_mount": "/root/.config/opencode"
    }
  }
}
```

Note: `preinstall` is applied by both runners (`islet.sh` and
`islet-dev.sh`) via derived images (above); `islet.sh` additionally
captures runtime installs in the per-agent deps dir
`~/.config/islet/<name>/deps` (hub layout: `npm/` global packages,
`alpine/` apk rootfs, `apk-cache/` download cache, plus user-space
installs from `/root/.local`).

## Requirements

- bash, docker, jq

## Coding conventions

- Bash with `set -Eeuo pipefail`.
- `die "..."` for fatal errors, `require_cmd` for dependency checks.
- All JSON reading/writing goes through `jq` (never parse JSON by hand).
- Colors only when stdout is a TTY; prompts go to stderr.
- Watch out for `set -e`: functions must `return 0` explicitly if their last
  command can fail harmlessly.

## Testing

`test/run.sh` — framework-free test suite (`bash test/run.sh`):

- Assertion helpers (`check`, `assert_eq`) with pass/fail counters.
- Syntax-checks all shell scripts (`bash -n`).
- Drives `install.sh` in isolated `HOME` dirs with piped stdin, verifying the
  written `config.json` via `jq`: default install, skip-steps CLI flags
  (`--image`, `--container-name`, ...), config merge on existing config
  (`t_merge`), and flag validation errors.
- Note: the piped multichoice fallback consumes one stdin line per exchange
  (empty line = confirm), so count answer lines to the exact prompt sequence.

Manual testing approach used so far:

- `bash -n <script>` — syntax check.
- Fake `docker` executable in `PATH` that echoes its arguments, to verify the
  generated command line without running real containers.
- Isolated `HOME` (e.g. `HOME=/tmp/...`) so `init` doesn't touch real config.
- Piped stdin to drive the interactive wizard non-interactively.
- `script -qec '<cmd>' /dev/null` (util-linux) to allocate a pty and test the
  TUI code paths; feed it paced input (small `sleep`s between keys) — dumping
  all bytes at once desyncs the escape-sequence reads.
- `cat install.sh | ISLET_INSTALL_URL="file://$PWD/install.sh" sh` to test
  the curl-pipe re-exec path locally.

## Branching / git workflow (enforced by hooks)

The rules below are **enforced programmatically** by the git hooks in
`githooks/` (activated for a checkout with `scripts/install-hooks.sh`;
repo already has `core.hooksPath=githooks` configured). The agent MUST
follow them exactly:

1. **No commits on `main`/`dev`** — direct commits (including merge
   commits other than feature merges) are rejected by `pre-commit`.
2. **Every new feature starts a new branch created from `dev`** — use
   `scripts/new-branch.sh <name>`, which also handles rule 7.
3. **No merges into `main`** — `pre-merge-commit` rejects any merge
   targeting `main`; feature branches merge into `dev` only.
4. **Push only when the user asks** — never push on your own. As a
   safety net, pushes to `main`/`dev` are blocked by `pre-push`; the
   user can override explicitly with `ISLET_ALLOW_MAIN_PUSH=1`.
5. **Branch naming** — `<feat|bug|hotfix>-#<number>-<description>`
   (e.g. `feat-#12-add-volume-mounts`). Checked in `pre-commit`,
   `commit-msg` (for merges into `dev`) and `pre-push`.
6. **Delete after merge into `dev`** — `post-merge` automatically
   deletes the merged feature branch (local, and its remote counterpart
   if it exists).
7. **Before creating a branch from `dev`: load ssh keys and sync
   `main`/`dev`** — `scripts/new-branch.sh` does this: `ssh-add -l`,
   `git fetch --prune`, fast-forward `main` and `dev` to `origin/*`,
   then branches off `dev`.
8. **Commit message format** — `<feat|bug>: [#number] - description`
   (e.g. `feat: [#12] - add docker volume mounts`), enforced by
   `commit-msg`.

Branch roles:

- `main` — stable branch (no local commits/merges; push only on request)
- `dev` — integration branch (feature branches merge here)
- `feat|bug|hotfix-#<number>-<description>` — work branches, created
  from `dev`, merged back into `dev`, deleted afterwards

## Git

- A repo-local identity is configured: `islet <islet@localhost>`.

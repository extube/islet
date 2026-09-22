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
  host), `islet.sh ps` lists running islet containers. `islet.sh rm
  [name]` removes one agent piece from config.json (empty `$schema`/
  `container` keys are dropped when it was the last agent); bare
  `islet.sh rm` uninstalls — after a `y/N` prompt it deletes the config
  folder and the islet-installed commands (`islet`, `islet-dev`) from
  `~/.local/bin`.
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

Note: `preinstall` is applied by `islet-dev.sh` via derived images (above);
`islet.sh` still runs the plain configured image.

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

## Branching

- `main` — stable branch
- `dev` — integration branch
- `feat-agent/#<number>-<description>` — feature branches, created from `dev`
  and merged back into `dev`

## Git

- A repo-local identity is configured: `islet <islet@localhost>`.

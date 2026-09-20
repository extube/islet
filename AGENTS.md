# AGENTS.md

Guidance for AI agents working in this repository.

## Project overview

**islet** is a mini CLI app that runs AI agent harnesses in isolated Docker
containers. It currently supports
[opencode](https://github.com/anomalyco/opencode)
(`ghcr.io/anomalyco/opencode:latest`); support for more agents is planned.

## Repository layout

- `islet.sh` — stable script. Runs opencode in Docker with the current (or
  given) directory mounted at `/workspace`.
- `install.sh` — installer. Interactive initialization wizard that creates
  the config file.
- `islet-dev.sh` — development version. Universal, config-driven runner.
  Active development happens here.
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
     (↑/↓ or j/k move, Tab/Space toggle, Enter confirm; falls back to
     numbered toggles when stdin is not a TTY)
  3. opencode config folder (default `~/.config/opencode`)
  4. Container name (empty = random, Docker generates one)
  5. Network: host, or port routing (`<port>:<port>,<port>:<port>`)
  6. Environment variables (`KEY=VALUE,KEY=VALUE`)
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
- `islet-dev.sh --help` — show help.

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

Note: `preinstall` is saved to config but not yet applied to containers
(future work: custom image builds).

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

No test framework yet. Manual testing approach used so far:

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

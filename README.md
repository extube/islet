# 🏝️ islet

A mini CLI app for running AI agents in Docker containers.

## Quick start

```sh
curl -fsSL https://raw.githubusercontent.com/extube/islet/main/install.sh | sh
```

That's it — then run an agent in your project dir:

```sh
islet opencode .    # first run: builds the opencode image, quick setup, starts
islet pi .          # same flow for pi (also: hermes, opencode-v2)
```

No config editing needed: on the first run islet builds the harness image
and asks for the essentials (preinstall tools, network, env) with a short
wizard; everything (deps, auth, sessions, plugins) persists in the agent's
data folder, so the next `islet opencode .` just starts the agent.

## Installation

Run the installer:

```sh
curl -fsSL https://raw.githubusercontent.com/extube/islet/main/install.sh | sh
```

Or, if you already have the repository:

```sh
./install.sh
```

The installer only asks for the islet config folder (default
`~/.config/islet`, override with `ISLET_CONFIG_DIR` and the `--config-dir`
flag), checks the requirements (`jq`, `docker`), creates a fresh
`config.json` if there is none, and installs the `islet` command into
`~/.local/bin/islet`.

To refresh the installed `islet` command later:

```sh
islet update
```

## Adding an agent to config.json

Option A — from a Dockerfile (agent built into the image):

1. **Create a Dockerfile** (`islet create` — single step: choose the agent
   opencode, opencode v2, pi or hermes; preinstall deps are NOT picked
   here — that happens in `islet setup`):

   ```sh
   islet create ~/my-agents/opencode.Dockerfile
   ```

2. **Build the image** (tagged `islet/<agent>:latest`):

   ```sh
   islet build ~/my-agents/opencode.Dockerfile
   ```

3. **Register it in the config** with the 5-step `islet setup` wizard
   (each step has a default — agent name, image, preinstall environment,
   network, environment variables; agent data dirs are created
   automatically under `~/.config/islet/<name>`). Point `image` at
   `islet/<agent>:latest`; or fill steps headless with flags that skip
   their step:

   ```sh
   islet setup \
     --name opencode \
     --image islet/opencode:latest \
     --preinstall 'Git,Node.js' \
     --network host
   ```

   (`--config-volume`, `--env` are the other flags; steps without a flag
   are still prompted.)

Option B — config only, no Dockerfile. Edit `config.json` by hand; every
entry needs just an `image`, and the `preinstall` list (optional) is baked
into a per-agent derived image automatically on the first run:

```json
{
  "$schema": "islet.sh",
  "container": "opencode",
  "agent": {
    "opencode": {
      "image": "islet/opencode:latest",
      "preinstall": ["Node.js"],
      "network": "host",
      "ports": [],
      "environment": {}
    }
  }
}
```

   - `image` — the image built with `islet build` (or any other image)
   - `preinstall` — dependency list picked in `islet setup`
     (Git, Node.js, Go, Java, Python, Rust, Ruby, C/C++); baked into a
     derived image `islet-pre:<name>-<keyed hash>` on the first run and
     rebuilt only when the list or the base image changes
   - **agent data folder** — `~/.config/islet/<agent-name>/`, created
     automatically; all persistent state of one agent lives here and is
     mounted into the container on every run (no volume keys needed):

     | host dir (under `~/.config/islet/<name>/`) | container path | contents |
     |---|---|---|
     | `deps/` | `/opt/islet-tools` + `/root/.local` | apk rootfs, npm `-g` (`npm/`), go (`go/`), gem (`gems/`), pip user packages (`pyuser/`), apk download cache (`apk-cache/`) |
     | `config/` | agent config dir — `/root/.config/opencode`, `/root/.config/pi` (+`PI_CODING_AGENT_DIR`, pi reads `~/.pi/agent`-style paths from there), `/root/.config/hermes` | plugins, extensions, themes, auth, agent settings |
     | `sessions/` | agent data dir — `/root/.local/share/opencode` etc. | sessions, saved state |
     | `opencode-cache/` (opencode only) | `/root/.cache/opencode` | npm plugin cache |

   - `volume_config` — optional override of the `config/` dir above
     (also `--config-volume` at `islet setup`); `volume_libs` / 
     `volume_sessions` similarly override the apk cache / sessions dirs
   - `network` — `host` or `bridge`
   - `ports` — `<port>:<port>` list for `network: bridge`
   - `environment` — `KEY: value` map passed to the container

4. **Run it**:

   ```sh
   islet <agent-name> ~/project
   ```

### Where agent extensions/plugins live (and how they persist)

- **opencode** — local plugins: `<agent folder>/config/plugins/` (the
  agent data folder's `config/` dir, mounted at
  `/root/.config/opencode`); npm plugins declared in `opencode.json`
  live in `/root/.cache/opencode`, persisted as
  `<agent folder>/opencode-cache/`.
- **pi** — extensions, skills, themes, prompts and auth live in the pi
  agent dir; islet sets `PI_CODING_AGENT_DIR=/root/.config/pi`, so they
  all live in `<agent folder>/config/`.
- Anything an agent pip/npm/apk/gem/go-installs during a run lands in
  the agent folder's `deps/` regardless.

### One-off volume mounts (`-v`)

Extra bind mounts — ssh keys, cache dirs, anything — can be attached to a
single run with `-v` (or `--volume`), without touching `config.json`:

```sh
islet opencode ~/project -v ~/.ssh:/root/.ssh:ro
islet opencode ~/project -v '~/data:dest!:with:colon,~/cache:/cache:rw'
```

- comma-separated `host:container[:flags]` pairs; `flags` is passed as-is to
  `docker run --volume`
- `~` expands to the host home dir; `!` marks a literal `:` in a path
  (`dest!:with:colon` -> `/dest:with:colon`)
- the host path must exist (it is created with `mkdir -p` if missing)
- the volumes are mounted in addition to the `config.json` ones

## Requirements

- Docker
- Bash
- `jq` (checked and reported by the installer)

## Usage

```sh
islet create [file]        # Dockerfile (opencode / opencode v2 / pi / hermes)
islet build [file]         # docker build the Dockerfile into islet/<agent>:latest
islet setup                # 5-step wizard: add an agent entry to config.json
islet setup --name pi --image img:pi --preinstall 'Node.js,Go' \
  --config-volume ~/.config/pi --network bridge --env 'K=v'
                           # flags skip their wizard step (value from flag)
islet [name] [workspace]   # run an agent (name/order optional)
islet opencode [ws]        # alias flow: not in config yet? builds its image,
islet opencode-v2 [ws]     # runs setup for it, then starts it (also pi,
islet pi [ws]              # hermes); if already configured, just runs
islet hermes [ws]
islet [name] [ws] -v h:c   # run with extra volumes (host:container pairs)
islet ps                   # list running islet containers
islet mv <old> <new>       # rename an agent (config key + data folder)
islet update               # refresh the islet command (re-runs install.sh)
islet rm [name]            # remove one agent entry from the config
islet rm                   # uninstall the islet command (config.json is kept)
islet --help
```

Without the installed command, use `./islet.sh` with the same arguments.

## How it works

- Runs the agent harness inside a Docker image; optionally derived from
  the configured image with the `preinstall` list baked in
  (`islet-pre:<name>-<key>`, built automatically, cached across runs).
- Mounts your workspace at `/workspace` inside the container.
- Multi-agent configs: each entry can set its own image, preinstall list,
  volumes, network, ports and environment variables.
- Persisted state lives in one agent folder:
  `~/.config/islet/<agent-name>/` — `deps/` (tool store), `config/`
  (agent config) and `sessions/` (sessions/auth) are mounted into the
  container automatically; `volume_config` / `volume_libs` /
  `volume_sessions` in config.json can override each of them.
- Both image-baked (`preinstall`) and runtime installs (the agent's own
  `apk add`, `pip --user`, `npm install -g`, `gem install`, `go install`,
  ...) survive: runtime installs land in the `deps/` dir via a redirected
  package-manager environment (and an `apk` wrapper that installs into
  the deps-dir rootfs).
- Interactive TTY; the container is removed automatically on exit.
- `islet rm` (uninstall) removes only the installed `islet` commands; the
  islet config folder and `config.json` are kept, so reinstalling preserves
  every agent entry.
- Re-running the installer never overwrites an existing `config.json` —
  it is kept as-is and only the `islet` command is refreshed.

## Testing

`bash test/run.sh` — framework-free test suite that syntax-checks all shell
scripts and drives the installer in isolated `HOME` dirs, verifying the
written config with `jq`.

## Branching

- `main` — stable branch
- `dev` — integration branch
- `feat/#<feature_number>-<description>` — feature branches,
  e.g. `feat/#1-multi-agent-support`

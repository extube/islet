# 🏝️ islet

A mini CLI app for running AI agents in Docker containers.

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

## Adding an agent to config.json

Option A — from a Dockerfile (agent + preinstall baked into the image):

1. **Create a Dockerfile** (`islet create` — step 1: choose the agent
   opencode, pi or hermes; step 2: multi-select the preinstall environment
   (Git, Node.js, Go, Java, Python, Rust, Ruby, C/C++ — baked into the
   image as apk packages, so it survives every container restart)):

   ```sh
   islet create ~/my-agents/opencode.Dockerfile
   ```

2. **Build the image** (tagged `islet/<agent>:latest`):

   ```sh
   islet build ~/my-agents/opencode.Dockerfile
   ```

3. **Register it in the config** with the 6-step `islet setup` wizard
   (each step has a default — agent name, image, preinstall environment,
   agent config volume, network, environment variables). Point `image` at
   `islet/<agent>:latest`:

   ```sh
   islet setup
   ```

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
      "volume_config": "~/.config/opencode",
      "network": "host",
      "ports": [],
      "environment": {}
    }
  }
}
```

   - `image` — the image built with `islet build` (or any other image)
   - `preinstall` — dependency list from `islet create`/`islet setup`
     (Git, Node.js, Go, Java, Python, Rust, Ruby, C/C++); baked into a
     derived image `islet-pre:<name>-<keyed hash>` on the first run and
     rebuilt only when the list or the base image changes
   - deps dir — `~/.config/islet/<agent-name>/deps` next to `config.json`;
     the agent's tool store, mounted at `/opt/islet-tools` and
     `/root/.local` in the container: libraries and programs installed
     **during a run** (apk add, pip --user, npm install -g, gem install,
     go install, ...) are captured here and are still available on the
     next run of the same agent
   - `volume_libs` — optional override of the apk download cache
     (default `<deps dir>/apk-cache`, mounted at `/var/cache/apk`)
   - `volume_config` — agent config dir (default `~/.config/<agent-name>`,
     mounted at `/root/.config/<agent-name>` in the container)
   - `volume_sessions` — optional override of the saved sessions dir
     (default `~/.local/share/islet/<agent-name>-sessions`, mounted at
     `/root/.local/share/<agent-name>`; e.g. opencode keeps its
     sessions/auth in that data dir). Not normally set by hand.
   - `network` — `host` or `bridge`
   - `ports` — `<port>:<port>` list for `network: bridge`
   - `environment` — `KEY: value` map passed to the container

4. **Run it**:

   ```sh
   islet <agent-name> ~/project
   ```

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
islet create [file]        # create a Dockerfile (choose opencode/pi/hermes)
islet build [file]         # docker build the Dockerfile into islet/<agent>:latest
islet setup                # 6-step wizard: add an agent entry to config.json
islet [name] [workspace]   # run an agent (name/order optional)
islet [name] [ws] -v h:c   # run with extra volumes (host:container pairs)
islet ps                   # list running islet containers
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
- Persisted volumes: agent config (`volume_config`), saved sessions
  (`~/.local/share/islet/<agent-name>-sessions`) and the per-agent deps
  dir (`~/.config/islet/<agent-name>/deps`), so config, sessions and
  packages survive `--rm` runs and Docker restarts.
- Both image-baked (`preinstall`) and runtime installs (the agent's own
  `apk add`, `pip --user`, `npm install -g`, `gem install`, `go install`,
  ...) survive: runtime installs land in the deps dir via a redirected
  package-manager environment (and an `apk` wrapper that installs into
  the deps-dir rootfs).
- `volume_config` defaults to `~/.config/<agent-name>` on the host,
  mounted at `/root/.config/<agent-name>`.
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

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

Option A — from a Dockerfile (agent built into the image):

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

3. **Register it in the config** with the 5-step `islet setup` wizard
   (each step has a default — agent name, image, agent config volume,
   network, environment variables). Point `image` at
   `islet/<agent>:latest`:

   ```sh
   islet setup
   ```

Option B — edit `config.json` by hand. Every entry only needs these fields:

```json
{
  "$schema": "islet.sh",
  "container": "opencode",
  "agent": {
    "opencode": {
      "image": "islet/opencode:latest",
      "volume_libs": "~/.local/share/islet/opencode-libs",
      "volume_config": "~/.config/opencode",
      "network": "host",
      "ports": [],
      "environment": {}
    }
  }
}
```

   - `image` — the image built with `islet build` (or any other image)
   - `volume_libs` — one host dir for installed libs; it is mounted at
     `/var/cache/apk` so package downloads survive container restarts
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

## Requirements

- Docker
- Bash
- `jq` (checked and reported by the installer)

## Usage

```sh
islet create [file]        # create a Dockerfile (choose opencode/pi/hermes)
islet build [file]         # docker build the Dockerfile into islet/<agent>:latest
islet setup                # 5-step wizard: add an agent entry to config.json
islet [name] [workspace]   # run an agent (name/order optional)
islet ps                   # list running islet containers
islet rm [name]            # remove one agent entry from the config
islet rm                   # uninstall: config + installed islet command
islet --help
```

Without the installed command, use `./islet.sh` with the same arguments.

## How it works

- Runs the agent harness inside a Docker image built from a generated
  Dockerfile (`islet create` + `islet build`).
- Mounts your workspace at `/workspace` inside the container.
- Multi-agent configs: each entry can set its own image, volumes, network,
  ports and environment variables.
- Persisted volumes: agent config (`volume_config`), saved sessions
  (`~/.local/share/islet/<agent-name>-sessions`) and the installed-libs
  cache (`volume_libs`), so config, sessions and packages survive `--rm`
  runs and Docker restarts.
- `volume_config` defaults to `~/.config/<agent-name>` on the host,
  mounted at `/root/.config/<agent-name>`.
- Interactive TTY; the container is removed automatically on exit.

## Testing

`bash test/run.sh` — framework-free test suite that syntax-checks all shell
scripts and drives the installer in isolated `HOME` dirs, verifying the
written config with `jq`.

## Branching

- `main` — stable branch
- `dev` — integration branch
- `feat/#<feature_number>-<description>` — feature branches,
  e.g. `feat/#1-multi-agent-support`

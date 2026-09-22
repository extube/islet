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

The installer launches an interactive wizard that creates the config file
at `~/.config/islet/config.json` (override with `ISLET_CONFIG_DIR`), guiding
you through:

1. Config folder
2. Preinstalled environment (multi-select: Node.js, Go, Java, Python,
   Rust, Ruby, C/C++)
3. Docker image (default `ghcr.io/anomalyco/opencode:latest` or custom)
4. opencode config folder
5. Container name (empty = Docker picks a random one)
6. Network: host or port routing
7. Environment variables (`KEY=VALUE,KEY=VALUE`)

Flags like `--image`, `--container-name`, `--preinstall`, `--env` skip
their wizard step.

Running the installer never overwrites an existing config: the configured
agent is merged into `config.json` (an agent with the same name replaces
only its own entry; other agents and the default container are kept).

The `islet` command is installed into `~/.local/bin/islet`, so the app
runs from anywhere in your home directory. `islet` only runs opencode
agents, in isolated Docker containers.

## Requirements

- Docker
- Bash
- `jq` (checked and reported by the installer)

## Usage

```sh
islet [name] [workspace]   # run an agent (name/order optional)
islet ps                   # list running islet containers
islet rm [name]            # remove one agent entry from the config
islet rm                   # uninstall: config + installed islet command
islet --help
```

Without the installed command, use `./islet.sh` with the same arguments.

## How it works

- Runs the [opencode](https://github.com/anomalyco/opencode) agent from
  the configured image (`ghcr.io/anomalyco/opencode:latest` by default).
- Mounts your workspace at `/workspace` inside the container.
- Multi-agent configs: each entry can set its own image, network, ports,
  environment variables and config mounts.
- Persists opencode config and sessions (auth included) via host
  directories mounted into the container, so they survive `--rm` runs.
- Preselected dependencies can be baked into a per-agent derived image,
  so the environment stays in place after every container rebuild.
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

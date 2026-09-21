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
2. Preinstalled environment (multi-select)
3. opencode config folder
4. Container name (empty = Docker picks a random one)
5. Network: host or port routing
6. Environment variables (`KEY=VALUE,KEY=VALUE`)

## Requirements

- Docker
- Bash
- `jq` (checked and reported by the installer)

## Usage

```sh
./islet.sh [workspace]
```

- `workspace` — optional path to the directory mounted into the container.
  Defaults to the current directory.

## How it works

- Runs the [opencode](https://github.com/anomalyco/opencode) agent from
  `ghcr.io/anomalyco/opencode:latest`.
- Mounts your workspace at `/workspace` inside the container.
- Persists opencode config via `~/.config/opencode` on the host.
- Uses host networking and an interactive TTY.
- The container is removed automatically on exit (`--rm`).

## Testing

`bash test/run.sh` — framework-free test suite that syntax-checks all shell
scripts and drives the installer in isolated `HOME` dirs, verifying the
written config with `jq`.

## Branching

- `main` — stable branch
- `dev` — integration branch
- `feat/#<feature_number>-<description>` — feature branches,
  e.g. `feat/#1-multi-agent-support`

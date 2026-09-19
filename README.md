# islet

A mini CLI app for running AI agents in Docker containers.

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

## Requirements

- Docker
- Bash

## Branching

- `main` — stable branch
- `dev` — integration branch
- `feat/#<feature_number>-<description>` — feature branches,
  e.g. `feat/#1-multi-agent-support`

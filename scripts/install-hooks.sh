#!/usr/bin/env bash
# install-hooks.sh — activate the islet git policy hooks for this checkout.
set -Eeuo pipefail

cd "$(dirname "$0")/.."
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "install-hooks: not a git repository" >&2
    exit 1
}

chmod +x githooks/* scripts/*.sh
git config core.hooksPath githooks
echo "install-hooks: git policy hooks activated ($(git config core.hooksPath))"

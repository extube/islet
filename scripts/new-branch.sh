#!/usr/bin/env bash
# new-branch.sh — start work on a new feature branch: load ssh keys, sync
# main/dev against origin, then branch off dev.
#
# Usage: scripts/new-branch.sh <feat|bug|hotfix>-#<number>-<description>
set -Eeuo pipefail

die() { echo "new-branch: $1" >&2; exit 1; }

name="${1:-}"
[ -n "$name" ] || die "usage: new-branch.sh <feat|bug|hotfix>-#<number>-<description>"
echo "$name" | grep -Eq "^(feat|bug|hotfix)-#[0-9]+-[a-zA-Z0-9._/-]+$" \
    || die "invalid branch name '${name}' — use feat|bug|hotfix-#<number>-<description>"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"

# 1. ssh keys
if ssh-add -l >/dev/null 2>&1; then
    echo "new-branch: ssh keys loaded"
else
    echo "new-branch: adding default ssh keys..."
    ssh-add ~/.ssh/id_ed25519 ~/.ssh/id_rsa 2>/dev/null || true
fi

# 2. sync main and dev
git fetch origin --prune >/dev/null 2>&1 || true
git rev-parse --verify -q origin/main >/dev/null || die "no origin/main — cannot sync"
git rev-parse --verify -q origin/dev >/dev/null || die "no origin/dev — cannot sync"

echo "new-branch: syncing 'main'..."
git checkout main >/dev/null 2>&1 || die "cannot checkout main"
git merge --ff-only origin/main >/dev/null 2>&1 || die "main diverged from origin/main — resolve manually"

echo "new-branch: syncing 'dev'..."
git checkout dev >/dev/null 2>&1 || die "cannot checkout dev"
git merge --ff-only origin/dev >/dev/null 2>&1 || die "dev diverged from origin/dev — resolve manually"

# 3. branch from dev
echo "new-branch: creating '${name}' from dev..."
git checkout -b "$name"

echo "new-branch: ready — work on '${name}', merge it into 'dev' when done."

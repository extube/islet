#!/usr/bin/env bash
# Shared helpers for islet git policy hooks (activate with scripts/install-hooks.sh).

VALID_TYPES="feat|bug|hotfix"

current_branch() {
    git rev-parse --abbrev-ref HEAD 2>/dev/null
}

# Feature branches must be named <feat|bug|hotfix>-#<number>-<description>.
feature_branch_name() {
    echo "$1" | grep -Eq "^(${VALID_TYPES})-#[0-9]+-[a-zA-Z0-9._/-]+$"
}

# Prints the name of the branch referenced by MERGE_HEAD (empty if absent).
merged_branch() {
    local head
    head="$(git rev-parse --git-dir)/MERGE_HEAD"
    [ -f "$head" ] || return 1
    git name-rev --name-only "$(cat "$head")" 2>/dev/null \
        | sed 's|^refs/remotes/origin/||; s|^remotes/origin/||; s|^origin/||; s|~[0-9]*$||; s|\^[0-9]*$||'
}

# Validates "<feat|bug>: [#number] - description".
commit_message_valid() {
    grep -Eq "^(${VALID_TYPES}): \[#[0-9]+\] - .+$" "$1"
}

deny() {
    echo "islet: ${1}" >&2
    exit 1
}

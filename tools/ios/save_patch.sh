#!/bin/bash
# tools/ios/save_patch.sh <out.patch> [pathspec...]   (e.g. out/patches/этапN.patch)
# Diff of dod3-recomp and its ps3recomp submodule against HEAD, new files included,
# through a temporary index (the real index and the working tree are untouched).
# Pathspecs are relative to dod3-recomp; ps3recomp/... ones go to the submodule.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)   # the dod3-recomp checkout this script is in
case "$1" in /*) out=$1;; *) out=$root/$1;; esac; shift
tmp=$(mktemp -d)
: > "$tmp/all.patch"
top=(); sub=()
if [ $# -eq 0 ]; then top=(. ':(exclude)ps3recomp'); sub=(.)
else for p in "$@"; do case "$p" in ps3recomp/*) sub+=("${p#ps3recomp/}");; *) top+=("$p");; esac; done; fi
run() {   # repo prefix pathspec...
    local repo=$1 prefix=$2; shift 2
    [ $# -gt 0 ] || return 0
    local idx="$tmp/index.$RANDOM"
    cp "$(git -C "$repo" rev-parse --absolute-git-dir)/index" "$idx"
    GIT_INDEX_FILE="$idx" git -C "$repo" add -A -- "$@"
    GIT_INDEX_FILE="$idx" git -C "$repo" diff --cached --binary \
        --src-prefix="a/$prefix" --dst-prefix="b/$prefix" -- "$@" >> "$tmp/all.patch"
}
run "$root" "" "${top[@]+"${top[@]}"}"
run "$root/ps3recomp" "ps3recomp/" "${sub[@]+"${sub[@]}"}"
mkdir -p "$(dirname "$out")"
mv "$tmp/all.patch" "$out"
rm -rf "$tmp"
echo "$out: $(grep -c '^diff --git' "$out" || true) files, $(wc -c < "$out" | tr -d ' ') bytes"
grep '^diff --git' "$out" | sed 's/^diff --git a\///; s/ b\/.*//' || true

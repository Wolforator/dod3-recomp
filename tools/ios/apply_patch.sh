#!/bin/bash
# Apply a patch tools/ios/save_patch.sh wrote (out/patches/этапN.patch) to a
# checkout of dod3-recomp and its ps3recomp submodule: the paths under
# ps3recomp/ go to the submodule, the rest to dod3-recomp. A three-way apply
# (git apply --3way), so on a newer version a change whose surroundings moved
# still goes in, and one that clashes is left as a conflict to resolve by
# hand (git status shows it), not dropped. Nothing is committed.
#
#   tools/ios/apply_patch.sh <file.patch> [<dod3-recomp checkout>]   (default: this one)
#   CHECK=1 tools/ios/apply_patch.sh ...   only say whether it applies
set -euo pipefail
patch=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
root=${2:-$(cd "$(dirname "$0")/../.." && pwd)}
mode=(--3way)
[ -n "${CHECK:-}" ] && mode=(--check)
[ -d "$root/ps3recomp/.git" ] || [ -f "$root/ps3recomp/.git" ] || { echo "no ps3recomp submodule in $root"; exit 1; }
tmp=$(mktemp -d)
# the patch split by repository: a file's diff starts at its "diff --git" line
awk -v out="$tmp" '/^diff --git /{f = ($3 ~ /^a\/ps3recomp\//) ? out "/sub" : out "/top"} f {print > f}' "$patch"
if [ -s "$tmp/top" ]; then
    echo "dod3-recomp: $(grep -c '^diff --git' "$tmp/top") files"
    git -C "$root" apply "${mode[@]}" --whitespace=nowarn "$tmp/top"
fi
if [ -s "$tmp/sub" ]; then
    echo "ps3recomp: $(grep -c '^diff --git' "$tmp/sub") files"
    git -C "$root/ps3recomp" apply "${mode[@]}" --whitespace=nowarn -p2 "$tmp/sub"
fi
rm -rf "$tmp"
echo "done${CHECK:+ (checked only)}: git status in both shows what changed; resolve any conflict markers, then build"

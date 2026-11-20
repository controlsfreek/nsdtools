#!/usr/bin/env bash
# Write BUILD in bin/fhm from the current git commit count plus one
# (the number after the next commit). Prints the build number.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FHM=$ROOT_DIR/bin/fhm
count=$(git -C "$ROOT_DIR" rev-list --count HEAD)
build=$((count + 1))

if grep -qE "^BUILD=$build$" "$FHM"; then
    printf '%s\n' "$build"
    exit 0
fi

tmp=$FHM.tmp.$$
while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    if [[ $line =~ ^BUILD=[0-9]+$ ]]; then
        printf 'BUILD=%s\n' "$build"
    else
        printf '%s\n' "$line"
    fi
done <"$FHM" >"$tmp"
mv "$tmp" "$FHM"
printf '%s\n' "$build"

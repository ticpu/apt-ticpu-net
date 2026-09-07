#!/bin/bash
# Report packages already published into a suite whose glibc they exceed.
# Read-only: removals are `reprepro remove <suite> <package>` by hand, then
# ./publish.sh.
set -euo pipefail

cd "$(dirname "$0")"
source ./config.sh

WORKDIR="scratch/audit-$$"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
trap 'rm -rf "$WORKDIR"' EXIT

# shellcheck disable=SC2016  # reprepro's own field syntax, not shell expansion
LIST_FORMAT='${package}\t${$fullfilename}\n'

fail=0
for suite in "${SUITES[@]}"; do
    while IFS=$'\t' read -r package file; do
        elf=$(deb_glibc_floor "$file" "$WORKDIR/$suite/$package")
        IFS=$'\t' read -r interp floor <<<"$elf"
        check_floor_against_suite "${file##*/}" "$floor" "$interp" "$suite" || fail=1
    done < <("${REPREPRO[@]}" --list-format "$LIST_FORMAT" list "$suite" | sort -u)
done
(( fail == 0 )) || exit 1
echo "every published package fits the glibc its suite ships"

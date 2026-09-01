#!/bin/bash
# Add locally built .deb files to every suite, then publish.
# For packages with no upstream release to ingest — the keyring being the one
# that matters.
set -euo pipefail

cd "$(dirname "$0")"
source ./config.sh

(( $# )) || { echo "usage: ${0##*/} FILE.deb..." >&2; exit 1; }

for f in "$@"; do
    [[ -f "$f" ]] || { echo "no such file: $f" >&2; exit 1; }
done

for suite in "${SUITES[@]}"; do
    "${REPREPRO[@]}" includedeb "$suite" "$@"
done

./publish.sh

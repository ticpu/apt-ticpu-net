#!/bin/bash
# Add locally built .deb files to suites, then publish.
# For packages with no upstream release to ingest — the keyring being the one
# that matters.
set -euo pipefail

cd "$(dirname "$0")"
source ./config.sh

usage() {
    cat >&2 <<'USAGE'
usage: add-local.sh [-s SUITE]... FILE.deb...
  -s  a suite to add to, repeatable; every suite when none is given
USAGE
    exit "${1:-1}"
}

suites=()
files=()
while (( $# )); do
    case "$1" in
        -s|--suite) shift; [[ -n "${1:-}" ]] || usage; suites+=("$1") ;;
        -h|--help) usage 0 ;;
        -*) echo "unknown option: $1" >&2; usage ;;
        *) files+=("$1") ;;
    esac
    shift
done
(( ${#files[@]} )) || usage
(( ${#suites[@]} )) || suites=("${SUITES[@]}")

for suite in "${suites[@]}"; do
    [[ " ${SUITES[*]} " == *" $suite "* ]] || { echo "no such suite: $suite" >&2; exit 1; }
done
for f in "${files[@]}"; do
    [[ -f "$f" ]] || { echo "no such file: $f" >&2; exit 1; }
done

WORKDIR="scratch/add-local-$$"
rm -rf "$WORKDIR"
trap 'rm -rf "$WORKDIR"' EXIT

fail=0
for f in "${files[@]}"; do
    check_deb "$f" "$WORKDIR/${f##*/}" "${suites[@]}" || fail=1
done
(( fail == 0 )) || exit 1

archive_begin
trap 'rm -rf "$WORKDIR"; archive_unlock' EXIT

for suite in "${suites[@]}"; do
    "${REPREPRO[@]}" includedeb "$suite" "${files[@]}"
done

./publish.sh

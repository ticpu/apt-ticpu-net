#!/bin/bash
# List what each suite carries, and take a version back out.
#
# The archive keeps every version ingested (Limit: 0 in conf/distributions), so
# something has to prune, and it is this rather than reprepro dropping the
# previous version behind your back on the next ingest.
set -euo pipefail

cd "$(dirname "$0")"
source ./config.sh

usage() {
    cat >&2 <<'USAGE'
usage: versions.sh list [PACKAGE]
       versions.sh remove SUITE PACKAGE VERSION
  list    every version in every suite, newest last
  remove  one version from one suite, then republish
USAGE
    exit "${1:-1}"
}

# shellcheck disable=SC2016  # reprepro's own field syntax, not shell expansion
LIST_FORMAT='${$identifier}\t${package}\t${version}\n'

case "${1:-}" in
list)
    want="${2:-}"
    for suite in "${SUITES[@]}"; do
        "${REPREPRO[@]}" --list-format "$LIST_FORMAT" list "$suite" ${want:+"$want"}
    done | sort -t$'\t' -k2,2 -k1,1 -V | column -t
    ;;
remove)
    (( $# == 4 )) || usage
    suite="$2" package="$3" version="$4"
    archive_begin
    trap archive_unlock EXIT
    "${REPREPRO[@]}" removefilter "$suite" "Package (== $package), Version (== $version)"
    ./publish.sh
    ;;
-h|--help) usage 0 ;;
*) usage ;;
esac

#!/bin/bash
# Re-sign the indexes and mirror the archive to the web host.
set -euo pipefail

cd "$(dirname "$0")"
source ./config.sh

DRY_RUN=0
SKIP_RSYNC=0
while (( $# )); do
    case "$1" in
        -n|--dry-run) DRY_RUN=1 ;;
        --local) SKIP_RSYNC=1 ;;
        -h|--help)
            echo "usage: ${0##*/} [-n|--dry-run] [--local]" >&2
            echo "  --local  export and sign, but do not mirror to $RSYNC_TARGET" >&2
            exit 0
            ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

for suite in "${SUITES[@]}"; do
    "${REPREPRO[@]}" export "$suite"
done

# Anything served alongside the archive but not part of it: the public key a
# first-time user fetches before they can verify anything else.
if [[ -d static ]]; then
    cp -a static/. "$BASE_DIR/"
fi

# A version-free path for the keyring, so every project's install snippet can
# name it without going stale on the next keyring bump.
keyring=$(find "$BASE_DIR/pool" -name 'ticpu-archive-keyring_*_all.deb' | sort -V | tail -1)
if [[ -n "$keyring" ]]; then
    cp -a "$keyring" "$BASE_DIR/ticpu-archive-keyring.deb"
fi

if (( SKIP_RSYNC )); then
    echo "exported to $BASE_DIR, not mirrored"
    exit 0
fi

rsync_flags=(-rlptDv --human-readable)
(( DRY_RUN )) && rsync_flags+=(--dry-run)

# Pool before dists, and prune only afterwards. An index naming a .deb that has
# not landed yet is a 404 for everyone running apt-get update in that window;
# the other order merely serves a stale index for a few seconds.
rsync "${rsync_flags[@]}" "$BASE_DIR/pool/" "$RSYNC_TARGET/pool/"
rsync "${rsync_flags[@]}" --delete "$BASE_DIR/dists/" "$RSYNC_TARGET/dists/"
rsync "${rsync_flags[@]}" --delete "$BASE_DIR/pool/" "$RSYNC_TARGET/pool/"

# Never a recursive sync of $BASE_DIR itself: conf/ and db/ live there too, and
# db/ is reprepro's state, not something to publish.
for f in "$BASE_DIR"/*; do
    [[ -f "$f" ]] || continue
    rsync "${rsync_flags[@]}" "$f" "$RSYNC_TARGET"
done

echo "published ${SUITES[*]} to $RSYNC_TARGET"

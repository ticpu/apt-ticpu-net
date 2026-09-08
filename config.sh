# Shared settings for the ingest and publish scripts.
# shellcheck shell=bash
# shellcheck disable=SC2034  # consumed by the scripts that source this

SUITES=(bookworm trixie noble resolute generic)

# The glibc each suite's distribution ships, read off packages.debian.org and
# packages.ubuntu.com. generic has no entry on purpose: it exists for releases
# with no suite of their own, of unknown vintage, so nothing with a glibc floor
# belongs in it.
declare -A SUITE_GLIBC=(
    [bookworm]=2.36
    [trixie]=2.41
    [noble]=2.39
    [resolute]=2.43
)

RSYNC_TARGET=p4:/srv/http/apt/
ARCHIVE_HOST="${RSYNC_TARGET%%:*}"
ARCHIVE_PATH="${RSYNC_TARGET%/}"
ARCHIVE_PATH="${ARCHIVE_PATH#*:}"
ARCHIVE_LOCK="$ARCHIVE_PATH/publish.lock"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# conf/ is version-controlled here; the pool, the indexes and reprepro's own
# database are build output and stay out of the repository.
#
# The archive lives on ARCHIVE_HOST, always: db/ and pool/ together are its
# state, and whichever db a run starts from is the one publish.sh's --delete
# makes the far end match. This is a working copy, refreshed from there before
# every write. Running reprepro against the archive path directly — which this
# used to do when the hostname matched — forks that state instead, and the
# archive then loses whatever the other db never learned about.
BASE_DIR="$HOME/.local/share/apt-ticpu-net"
REPREPRO=(reprepro --confdir "$REPO_DIR/conf" --basedir "$BASE_DIR")

# Signing happens here because the key is here, so the writing does too, and
# two writers against one Berkeley DB corrupt it. A symlink is the lock: ln -s
# fails atomically when one exists, and its target names who holds it.
archive_lock() {
    local owner holder
    owner="$(id -un)@$(hostname):$$"
    if ! ssh "$ARCHIVE_HOST" ln -s "$owner" "$ARCHIVE_LOCK" 2>/dev/null; then
        # shellcheck disable=SC2029  # the path is this side's to expand
        holder=$(ssh "$ARCHIVE_HOST" readlink "$ARCHIVE_LOCK" || true)
        echo "the archive is locked by ${holder:-someone}" >&2
        echo "if that run is gone: ssh $ARCHIVE_HOST rm $ARCHIVE_LOCK" >&2
        return 1
    fi
    export ARCHIVE_LOCKED=1
}

archive_unlock() {
    [[ "${ARCHIVE_LOCKED:-0}" == 1 ]] || return 0
    ssh "$ARCHIVE_HOST" rm -f "$ARCHIVE_LOCK"
    ARCHIVE_LOCKED=0
}

# Every path that writes to the database calls this first, and traps
# archive_unlock. publish.sh does not: it uploads what the writer just built,
# and pulling first would take a removal straight back out.
archive_begin() {
    archive_lock || return 1
    rsync -a --delete \
        "$ARCHIVE_HOST:$ARCHIVE_PATH/pool" \
        "$ARCHIVE_HOST:$ARCHIVE_PATH/dists" \
        "$ARCHIVE_HOST:$ARCHIVE_PATH/db" \
        "$BASE_DIR/"
}

# conf/distributions is the only place the key is named. reprepro signs through
# gpgme, which takes the digest from the key itself — aptly hardcodes SHA256 and
# cannot sign with this P-384 key at all.
signing_key() {
    awk '/^SignWith:/ {print $2; exit}' "$REPO_DIR/conf/distributions"
}

# gpg --verify alone accepts any key in the local keyring, so a release signed
# with an unrelated key of the maintainer's — a work-scoped one, say — would pass
# while carrying nothing this archive vouches for. Match the fingerprint gpg
# actually validated against the one conf/distributions signs with.
verify_sig() {
    local sig="$1" file="$2" want status
    want=$(signing_key)
    if ! status=$(gpg --status-fd 1 --verify "$sig" "$file" 2>/dev/null); then
        echo "bad signature: $sig" >&2
        return 1
    fi
    if ! grep -q "^\[GNUPG:\] VALIDSIG $want " <<<"$status"; then
        echo "$sig is valid but not signed by $want:" >&2
        awk '/^\[GNUPG:\] VALIDSIG /{print "  signed by " $3}' <<<"$status" >&2
        return 1
    fi
}

# Depends is a claim the project typed; a claim that understates the ELF
# installs cleanly and dies at exec on a missing symbol version. Read the
# binary instead. Prints "<interp>\t<floor>" — that order because the floor is
# empty for a package with no glibc symbols, and a trailing empty field survives
# `read` where a leading one does not.
deb_glibc_floor() {
    local deb="$1" dir="$2" f v magic floor="" interp=no
    command -v readelf >/dev/null || { echo "readelf not found; install binutils" >&2; return 1; }
    mkdir -p "$dir"
    dpkg-deb --fsys-tarfile "$deb" | tar -x -C "$dir"
    while IFS= read -r -d '' f; do
        # Split debug files duplicate the binary's symbols and carry a PT_INTERP
        # with no contents, which readelf reports as an error on each one.
        [[ "$f" != */usr/lib/debug/* ]] || continue
        IFS= read -rn4 magic < "$f" || true
        [[ $magic == $'\x7fELF' ]] || continue
        # An ELF with no interpreter and no glibc symbol fails both greps, and
        # under `set -e -o pipefail` that killed the scan mid-package: whatever
        # came after went unread and the package reported no floor at all.
        if readelf -SW "$f" | grep -q ' \.interp '; then interp=yes; fi
        v=$(readelf --dyn-syms -W "$f" | grep -oP '@+GLIBC_\K[0-9]+(\.[0-9]+)+' | sort -V | tail -1 || true)
        [[ -z "$v" ]] || floor=$(printf '%s\n%s\n' "$floor" "$v" | sort -V | tail -1)
    done < <(find "$dir" -type f -print0)
    printf '%s\t%s\n' "$interp" "$floor"
}

deb_declared_floor() {
    dpkg-deb -f "$1" Depends | grep -oP 'libc6[^,]*\(\s*>=\s*\K[0-9][^-)]*' | sort -V | tail -1 || true
}

# One .deb against every suite it is headed for, Depends included. Every path
# that reaches `reprepro includedeb` calls this: keyleds went in around it once
# and put a glibc 2.38 binary in generic.
check_deb() {
    local deb="$1" dir="$2" name interp floor declared suite rc=0
    shift 2
    name="${deb##*/}"
    IFS=$'\t' read -r interp floor <<<"$(deb_glibc_floor "$deb" "$dir")"
    declared=$(deb_declared_floor "$deb")
    if [[ -n "$floor" ]] && { [[ -z "$declared" ]] || dpkg --compare-versions "$declared" lt "$floor"; }; then
        echo "$name needs glibc $floor but Depends asks for ${declared:-no libc6 at all}" >&2
        echo "  apt would install it anywhere and it would fail at exec" >&2
        rc=1
    fi
    for suite in "$@"; do
        check_floor_against_suite "$name" "$floor" "$interp" "$suite" || rc=1
    done
    return "$rc"
}

# One package against one suite. Prints why it does not belong and returns 1.
check_floor_against_suite() {
    local name="$1" floor="$2" interp="$3" suite="$4" ceiling="${SUITE_GLIBC[$4]:-}"
    if [[ -z "$ceiling" ]]; then
        [[ -n "$floor" || "$interp" == yes ]] || return 0
        echo "$suite: $name is dynamically linked (glibc ${floor:-none}, interpreter $interp)" >&2
        echo "  $suite serves releases with no suite of their own, so it takes no glibc floor" >&2
        echo "  build it static-pie against musl, or drop $suite from its glob in projects.yaml" >&2
        return 1
    fi
    [[ -n "$floor" ]] && dpkg --compare-versions "$floor" gt "$ceiling" || return 0
    echo "$suite: $name needs glibc $floor, $suite ships $ceiling" >&2
    return 1
}

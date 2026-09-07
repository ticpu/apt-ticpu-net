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

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# conf/ is version-controlled here; the pool, the indexes and reprepro's own
# database are build output and stay out of the repository.
#
# Running on the same host RSYNC_TARGET names, BASE_DIR is that path directly:
# there is nothing to mirror to. Anywhere else it's a per-machine copy that
# publish.sh keeps in sync with --delete, so an empty one is stale state, not
# a fresh start.
if [[ "${RSYNC_TARGET%%:*}" == "$(hostname)" ]]; then
    BASE_DIR="${RSYNC_TARGET#*:}"
else
    BASE_DIR="$HOME/.local/share/apt-ticpu-net"
fi
REPREPRO=(reprepro --confdir "$REPO_DIR/conf" --basedir "$BASE_DIR")

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
        IFS= read -rn4 magic < "$f" || true
        [[ $magic == $'\x7fELF' ]] || continue
        readelf -lW "$f" | grep -q INTERP && interp=yes
        v=$(readelf --dyn-syms -W "$f" | grep -oP '@+GLIBC_\K[0-9]+(\.[0-9]+)+' | sort -V | tail -1)
        [[ -z "$v" ]] || floor=$(printf '%s\n%s\n' "$floor" "$v" | sort -V | tail -1)
    done < <(find "$dir" -type f -print0)
    printf '%s\t%s\n' "$interp" "$floor"
}

deb_declared_floor() {
    dpkg-deb -f "$1" Depends | grep -oP 'libc6[^,]*\(\s*>=\s*\K[0-9][^-)]*' | sort -V | tail -1 || true
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

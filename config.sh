# Shared settings for the ingest and publish scripts.
# shellcheck shell=bash
# shellcheck disable=SC2034  # consumed by the scripts that source this

SUITES=(bookworm trixie noble resolute generic)

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

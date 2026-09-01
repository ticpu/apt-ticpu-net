# Shared settings for the ingest and publish scripts.
# shellcheck shell=bash
# shellcheck disable=SC2034  # consumed by the scripts that source this

SUITES=(bookworm trixie noble resolute)

RSYNC_TARGET=p4:/srv/http/apt/

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# conf/ is version-controlled here; the pool, the indexes and reprepro's own
# database are build output and stay out of the repository.
BASE_DIR="$HOME/.local/share/apt-ticpu-net"
REPREPRO=(reprepro --confdir "$REPO_DIR/conf" --basedir "$BASE_DIR")

# conf/distributions is the only place the key is named. reprepro signs through
# gpgme, which takes the digest from the key itself — aptly hardcodes SHA256 and
# cannot sign with this P-384 key at all.
signing_key() {
    awk '/^SignWith:/ {print $2; exit}' "$REPO_DIR/conf/distributions"
}

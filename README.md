# apt.ticpu.net

A Debian/Ubuntu archive for the packages built out of
[github.com/ticpu](https://github.com/ticpu/).

The portable single-binary tools install on **any** Debian or Ubuntu, from a
`generic` suite. Debian 12 (bookworm), Debian 13 (trixie), Ubuntu 24.04 (noble)
and Ubuntu 26.04 (resolute) additionally get podman and containers/storage,
which are rebuilt per release. On anything else you get the tools and a note
saying podman is not available there — you never need to add another release's
suite to install something.

Arch packages are on the [AUR](https://aur.archlinux.org/packages?K=ticpu), not
here.

## Using it

```bash
curl -fsSLO https://apt.ticpu.net/ticpu-archive-keyring.deb
sudo dpkg -i ticpu-archive-keyring.deb
sudo apt-get update
```

The keyring package installs the archive key and writes
`/etc/apt/sources.list.d/ticpu.sources` for the suite matching your release. If
your release has no suite here it says so and installs only the key.

It also pins podman and containers/storage to this archive at priority 1001.
Those are recompiled against a patched storage library and an archive build
cannot start against a bcachefs graphroot, so version ordering must not be what
decides which one is installed — the `+bcachefs1` suffix loses to the next
archive revision.

To set it up by hand instead. The key goes in `/etc/apt/keyrings`, which is
where a key added by an administrator belongs; `/usr/share/keyrings` is dpkg's,
and only the keyring package above may write there:

```bash
sudo install -d -m 755 /etc/apt/keyrings
sudo curl -fsSLo /etc/apt/keyrings/ticpu-archive-keyring.gpg \
    https://apt.ticpu.net/ticpu-archive-keyring.gpg
. /etc/os-release
sudo tee /etc/apt/sources.list.d/ticpu.sources <<SOURCES
Types: deb
URIs: https://apt.ticpu.net
Suites: ${VERSION_CODENAME}
Components: main
Signed-By: /etc/apt/keyrings/ticpu-archive-keyring.gpg
SOURCES
```

## What is in it

Package sets are pulled from each project's GitHub release. `projects.yaml`
says which assets belong to which suites.

Single-binary tools are published into every suite unchanged. Only podman and
containers-storage are rebuilt per distro, because each carries that distro's
own upstream version.

`generic` takes no dynamically linked package at all. It serves releases with no
suite of their own, of a vintage nobody here knows, so a glibc floor cannot be
checked against anything — a static-pie musl build has none to check.

## Publishing

The signing key lives on the maintainer's workstation, so reprepro runs there
and signs `Release` directly — no key is ever held by CI or by the web host,
which only receives an rsync of the finished tree.

reprepro rather than aptly because the archive key is ECDSA on NIST P-384:
aptly hardcodes `--digest-algo SHA256` when it calls gpg, and a P-384 key cannot
produce a SHA256 signature (`gpg: signing failed: Invalid length`). reprepro
signs through gpgme, which takes the digest from the key.

```bash
./bootstrap.sh                                   # once: create the suites, export the key
make publish-keyring                             # once, and on every key or suite change
./ingest.sh bcachefs-storage-driver v1.3.0       # pull a release into the archive
./ingest.sh freeswitch-log-parser                # omit the tag for the latest release
./audit.sh                                       # what is published that no longer fits its suite
./versions.sh list                               # every version in every suite
./versions.sh remove generic fs-cli 1.4.4        # take one back out, then republish
```

`ingest.sh -n` downloads and resolves suites without touching the archive.
`publish.sh --local` signs and publishes without mirroring.

Every version ingested stays until `versions.sh remove` takes it out, so a
release that turns out broken always has a predecessor left to pin back to.

Ingest refuses a project declared `signed: true` whose assets carry no
signature, and refuses to continue if any `.deb` in a release matches no suite —
a mapping that has gone stale is a release published with packages missing, not
something to skip past. It also refuses a package needing a newer glibc than a
suite it is mapped into ships, and one whose `Depends` asks for less than its
binary needs: that one installs anywhere and dies at exec on a symbol version.

## Serving

`nginx/apt.ticpu.net.conf` goes in `/etc/nginx/sites-available/apt` on the web
host. It needs no certificate of its own: the host already holds a Let's Encrypt
wildcard for `*.ticpu.net`.

Two things live in the Cloudflare dashboard rather than in this repository:

- the DNS record for `apt.ticpu.net`
- cache rules — `/pool/*` cached hard, `/dists/*` bypassed

The origin sends matching `Cache-Control`, but the cache rules are what actually
decide. Getting them backwards produces a hash mismatch on `apt-get update`
whose message points at the archive rather than at the cache.

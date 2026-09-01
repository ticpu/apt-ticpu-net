# apt.ticpu.net

A Debian/Ubuntu archive for packages built out of github.com/ticpu. Arch is on
the AUR and deliberately not here.

Five suites, and the split is the important part. **`generic` carries the
portable single-binary tools** — one build, no per-release difference, installable
on any Debian or Ubuntu above the packages' glibc floor. The four codename
suites (bookworm, trixie, noble, resolute) add only what is genuinely rebuilt per
distro, which today means podman and containers/storage.

Without `generic`, a release with no suite of its own — jammy, forky, sid,
whatever ships next — got the key and no sources file at all, and the only way in
would have been to add an older distro's suite. The keyring's postinst writes
`Suites: <codename> generic` when it recognises the release and `Suites: generic`
when it does not, so the fallback is a working install rather than a wrong one.

Portable packages are published into the codename suites **as well as**
`generic`. That is redundant, and deliberate: installs predating `generic` have
only their codename suite, and dropping the duplicate would strand them.

README.md is user-facing: how to add the archive, how to publish. This file is
the provenance of the packages and the traps.

## Where the packages come from

Nothing is built here. `ingest.sh` downloads a project's GitHub release,
verifies the signatures, and files each `.deb` into the suites `projects.yaml`
names. The projects are the source of truth for their own packaging.

| package | built by | suites | signed |
| --- | --- | --- | --- |
| podman, podman-docker, podman-remote, containers-storage, golang-github-containers-{storage,image}{,-dev} | [bcachefs-storage-driver](https://github.com/ticpu/bcachefs-storage-driver) | trixie, noble, resolute | yes |
| fslog | [freeswitch-log-parser](https://github.com/ticpu/freeswitch-log-parser) | all five | yes |
| fs-cli | [fs_cli-rs](https://github.com/ticpu/fs_cli-rs) | all five | yes |
| ticpu-claude-command-hook | [ticpu-claude-command-hook](https://github.com/ticpu/ticpu-claude-command-hook) | all five | yes |
| claude-conversation-search | [claude-conversation-search-mcp](https://github.com/ticpu/claude-conversation-search-mcp) | all five | yes |
| ccusage-statusline-rs | [ccusage-statusline-rs](https://github.com/ticpu/ccusage-statusline-rs) | all five | yes |
| ticpu-archive-keyring | here, `make keyring` | all five | n/a |

Everything ingested is signature-verified. Nothing here is `signed: false`, and
adding a project that way should be a deliberate, temporary decision.

ccusage-statusline-rs is the one package with no `Depends` at all, and that is
correct: it links static-pie against musl, so there is no interpreter and no
`DT_NEEDED`. Its packaging fails the build if dynamic linking ever reappears,
which is what makes `generic` safe for it rather than merely convenient.

### What a project has to do to be carried

Every feeding repo now follows the same shape, and the archive enforces each
part rather than trusting it:

1. **CI builds the `.deb`s and creates the release as a draft.** Draft is not
   optional — releases are immutable once published, so signatures have to land
   before that.
2. **`sign-release.sh` runs locally**, detach-signs every asset with the key from
   `git config user.signingkey`, uploads the `.asc` files, and clears the draft
   flag last. The key never reaches CI.
3. **Someone tells this repo the tag**, and `./ingest.sh <project> <tag>` does
   the rest.

What ingest refuses: an asset signed by any other key, a missing signature, a
`.deb` matching no suite, and a version that disagrees with the tag. All four
are conditions that would otherwise be discovered by a user rather than here.

The per-repo packaging conventions that made this work — deriving the glibc
floor and the whole `Depends` set from the built binary rather than typing
them, and failing the build on an unmappable `DT_NEEDED` — live in those repos,
not here. Three separate projects found a hand-typed floor was wrong the first
time they derived it.

### The podman set is not uniform

Only podman and containers/storage are rebuilt per distro, each carrying that
distro's own upstream version, so **no filename pattern can tell a noble build
from a trixie one**. That is why bcachefs-storage-driver's release carries a
`manifest.json` naming the suite per file and `projects.yaml` marks it
`manifest: true`. Everything else is a portable single binary published into
every suite unchanged.

trixie and resolute carry podman `+bcachefs2`: they also build a patched
`golang-github-containers-image` for a registry auth-scope fix unrelated to
bcachefs. noble stays `+bcachefs1`. When
[PR 1130](https://github.com/podman-container-tools/container-libs/pull/1130)
merges, that patch goes away upstream and podman there **returns to
`+bcachefs1`** — a version going backwards on purpose.

**bookworm gets no podman**, and cannot: it ships containers/storage 1.43.0 and
the driver needs 1.57 (noble's 1.51 already costs a fork). It carries fslog and
the keyring only.

## Signing

`conf/distributions` names the key in `SignWith:` and is the only place it
appears; `config.sh`'s `signing_key()` reads it back. The same key signs the
release assets ingest verifies, so a hand-downloaded `.deb` and the archive it
also lives in answer to one identity.

Ingest checks the *fingerprint*, not just that a signature is good. Plain
`gpg --verify` accepts anything in the local keyring, so a release signed with
the maintainer's work-scoped key would sail through while carrying nothing this
archive vouches for — which is not hypothetical: fs_cli-rs resolved to that key
until it was pinned. `verify_sig()` matches gpg's `VALIDSIG` against
`signing_key()` and names the offending key when it does not.

**reprepro, not aptly.** aptly hardcodes `--digest-algo SHA256` when it shells
out to gpg, and the key is ECDSA on NIST P-384, which cannot produce a SHA256
signature — `gpg: signing failed: Invalid length`. There is no aptly option for
it and its `internal` provider cannot read a gpg 2.1+ keyring. reprepro signs
through gpgme, which takes the digest from the key.

**Releases are immutable now.** Assets cannot be added to a published release,
so a project's signatures have to land while its release is still a draft. A
release that went public unsigned can never be signed — its packages are
ingestable only with `signed: false`, which skips verification entirely.

## Publishing

Publishing runs on the workstation because the key does. p4 only ever receives
an rsync of a finished tree and holds nothing secret.

`publish.sh` rsyncs **pool before dists, and prunes last**. An index naming a
`.deb` that has not landed is a 404 for everyone running `apt-get update` in
that window; the other order merely serves a stale index for a few seconds.
Never rsync `$BASE_DIR` recursively — `conf/` and reprepro's `db/` live there.

`ingest.sh` **skips a package already present at the same name and version.**
Every release rebuilds every package, so ones whose version did not change come
back with different bytes; reprepro refuses two builds under one version and
aborts the whole run. That once left resolute without the podman a release
existed for, because the suite processed before it hit a duplicate — and the run
still delivered the earlier suite, so its exit status was the only sign.

It **fails closed** on a `.deb` matching no suite, on a missing signature for a
project marked `signed: true`, and on a package version that disagrees with the
tag under `version_from_tag: true`. That last one exists because a release job
checking out shallow has no tags: version derivation falls through to the
untagged form, stamps every package `1.2.3+<sha>`, and builds, signs and
publishes it without complaint. Nothing upstream of the archive notices.

## The pin

`ticpu-archive-keyring` ships `/etc/apt/preferences.d/ticpu-podman` at priority
1001, so this origin wins even when the archive's version is higher. Without it
the `+bcachefs` suffix loses to the next archive revision and apt installs a
podman that cannot start against a bcachefs graphroot. Verified against a
stand-in package at version 99.0.0.

containers/image is in the pinned set for a second reason: on trixie and
resolute it carries the auth-scope fix, and an archive copy would take that back
out of a working install.

The cauca GitLab runners ship the key and this pin **directly from puppet**
rather than installing the package, so their copy is a fork — a change here does
not reach them. Tell that session (`manage-runners-apt-repositories`) when the
pinned set changes.

## Gotchas

- **`/etc/apt/keyrings`, not `/usr/share/keyrings`,** for a key added by hand.
  The latter is dpkg's; only the keyring package writes there.
- **A host AppArmor profile confines containerised curl.** `/etc/apparmor.d/curl`
  attaches by executable path, so a container's `/usr/bin/curl` inherits it and
  can only write under `$HOME` and user-tmp. `curl -o /etc/apt/keyrings/...`
  inside a container fails with a bare `curl: (23)` and no mention of AppArmor.
- **Cloudflare caches by extension and `.deb` is not on its list**, so origin
  `Cache-Control` alone caches nothing. Two cache rules do the work: `/pool/*`
  eligible (immutable content, safe to cache hard), `/dists/*` bypassed. Getting
  those backwards serves a stale `InRelease` against fresh `Packages`, which
  surfaces as a hash mismatch blaming the archive.
- `gpg --export` prompts to overwrite an existing file and fails with
  `cannot open '/dev/tty'` when there is no terminal. `bootstrap.sh` passes
  `--yes`; the error names a tty and means nothing of the sort.

NAME := ticpu-archive-keyring
VERSION := 1.1
KEY := static/$(NAME).gpg
DEB := dist/$(NAME)_$(VERSION)_all.deb
PKG := build/$(NAME)

.PHONY: all keyring publish-keyring clean

all: keyring

keyring: $(DEB)

$(DEB): keyring/control keyring/postinst keyring/postrm keyring/conffiles keyring/ticpu-podman.pref $(KEY)
	rm -rf "$(PKG)"
	install -D -m 644 -T "$(KEY)" "$(PKG)/usr/share/keyrings/$(NAME).gpg"
	install -D -m 644 -T keyring/ticpu-podman.pref "$(PKG)/etc/apt/preferences.d/ticpu-podman"
	install -D -m 644 -T keyring/control "$(PKG)/DEBIAN/control"
	install -D -m 644 -T keyring/conffiles "$(PKG)/DEBIAN/conffiles"
	install -D -m 755 -T keyring/postinst "$(PKG)/DEBIAN/postinst"
	install -D -m 755 -T keyring/postrm "$(PKG)/DEBIAN/postrm"
	sed -i -e "s/^Version:.*/Version: $(VERSION)/" "$(PKG)/DEBIAN/control"
	mkdir -p dist
	dpkg-deb --build --root-owner-group "$(PKG)" "$@"
	rm -rf "$(PKG)"

$(KEY):
	./bootstrap.sh

# The keyring is the one package with no upstream release to ingest.
publish-keyring: $(DEB)
	./add-local.sh "$(DEB)"

clean:
	rm -rf build dist

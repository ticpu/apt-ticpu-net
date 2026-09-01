#!/bin/bash
# Create the reprepro database and export the archive key.
# Safe to re-run.
set -euo pipefail

cd "$(dirname "$0")"
source ./config.sh

mkdir -p "$BASE_DIR"

# reprepro creates its database on first use; export makes it do so without
# needing a package to add.
for suite in "${SUITES[@]}"; do
    "${REPREPRO[@]}" export "$suite"
done

key=$(signing_key)
mkdir -p static
gpg --export --yes --output static/ticpu-archive-keyring.gpg "$key"
echo "exported $key to static/ticpu-archive-keyring.gpg"

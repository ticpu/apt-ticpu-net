#!/bin/bash
# Pull a project's release assets into the apt repository and publish.
set -euo pipefail

cd "$(dirname "$0")"
source ./config.sh

usage() {
    echo "usage: ${0##*/} [-n|--dry-run] PROJECT [TAG]" >&2
    echo "  PROJECT  a name from projects.yaml; TAG defaults to the latest release" >&2
    exit "${1:-1}"
}

DRY_RUN=0
PROJECT=""
TAG=""
while (( $# )); do
    case "$1" in
        -n|--dry-run) DRY_RUN=1 ;;
        -h|--help) usage 0 ;;
        -*) echo "unknown option: $1" >&2; usage ;;
        *) if [[ -z "$PROJECT" ]]; then PROJECT="$1"; else TAG="$1"; fi ;;
    esac
    shift
done
[[ -n "$PROJECT" ]] || usage

project_json=$(yq -o=json '.' projects.yaml | jq --arg n "$PROJECT" '.[] | select(.name == $n)')
if [[ -z "$project_json" ]]; then
    echo "$PROJECT is not in projects.yaml; known projects:" >&2
    yq -r '.[].name' projects.yaml >&2
    exit 1
fi

GH_REPO=$(jq -r .repo <<<"$project_json")
SIGNED=$(jq -r '.signed // false' <<<"$project_json")
USE_MANIFEST=$(jq -r '.manifest // false' <<<"$project_json")

if [[ -z "$TAG" ]]; then
    TAG=$(gh release view --repo "$GH_REPO" --json tagName --jq .tagName)
    echo "no tag given, using latest release $TAG"
fi

WORKDIR="scratch/ingest-$PROJECT-$TAG"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
trap 'rm -rf "$WORKDIR"' EXIT

gh release download "$TAG" --repo "$GH_REPO" --dir "$WORKDIR"

shopt -s nullglob
debs=("$WORKDIR"/*.deb)
if (( ${#debs[@]} == 0 )); then
    echo "$GH_REPO $TAG carries no .deb assets" >&2
    exit 1
fi

if [[ "$SIGNED" == true ]]; then
    for deb in "${debs[@]}"; do
        if [[ ! -f "$deb.asc" ]]; then
            echo "$PROJECT is declared signed but ${deb##*/} has no .asc" >&2
            echo "run sign-release.sh in that repository before ingesting" >&2
            exit 1
        fi
        verify_sig "$deb.asc" "$deb"
    done
fi

# filename -> space-separated suites
declare -A asset_suites=()

if [[ "$USE_MANIFEST" == true ]]; then
    manifest="$WORKDIR/manifest.json"
    if [[ ! -f "$manifest" ]]; then
        echo "$PROJECT declares manifest: true but $TAG has no manifest.json" >&2
        exit 1
    fi
    [[ "$SIGNED" != true || -f "$manifest.asc" ]] || { echo "manifest.json is unsigned" >&2; exit 1; }
    [[ "$SIGNED" != true ]] || verify_sig "$manifest.asc" "$manifest"
    while IFS=$'\t' read -r file suite; do
        asset_suites["$file"]="${asset_suites["$file"]:-} $suite"
    done < <(jq -r '.[] | "\(.file)\t\(.suite)"' "$manifest")
else
    while IFS=$'\t' read -r glob suites; do
        for deb in "${debs[@]}"; do
            # shellcheck disable=SC2053  # glob from projects.yaml, matched not compared
            [[ "${deb##*/}" == $glob ]] && asset_suites["${deb##*/}"]="${asset_suites["${deb##*/}"]:-} $suites"
        done
    done < <(jq -r '.assets[] | "\(.glob)\t\(.suites | join(" "))"' <<<"$project_json")
fi

unmatched=0
for deb in "${debs[@]}"; do
    if [[ -z "${asset_suites[${deb##*/}]:-}" ]]; then
        echo "no suite for ${deb##*/}" >&2
        unmatched=1
    fi
done
# A package nobody claimed is a mapping that went stale, not something to skip:
# silently dropping it publishes a release missing packages users expect.
(( unmatched == 0 )) || exit 1

# Invert to suite -> files, so each suite takes one aptly call.
declare -A suite_files=()
for file in "${!asset_suites[@]}"; do
    for suite in ${asset_suites[$file]}; do
        suite_files["$suite"]="${suite_files["$suite"]:-} $WORKDIR/$file"
    done
done

for suite in "${!suite_files[@]}"; do
    echo "$suite: ${suite_files[$suite]//$WORKDIR\//}"
done

if (( DRY_RUN )); then
    echo "dry run: nothing added, $WORKDIR left in place for inspection"
    trap - EXIT
    exit 0
fi

for suite in "${!suite_files[@]}"; do
    # Every release rebuilds every package, so the ones whose version did not
    # change come back with different bytes under the same version. reprepro
    # refuses that, and rightly — but it is not an error here, there is simply
    # nothing new to deliver. Skipping keeps one aborted package from stopping
    # the suites that follow.
    present=$("${REPREPRO[@]}" list "$suite" | awk '{print $2, $3}' | sort -u)
    add=()
    for f in ${suite_files[$suite]}; do
        nv="$(dpkg-deb -f "$f" Package) $(dpkg-deb -f "$f" Version)"
        if grep -qxF "$nv" <<<"$present"; then
            echo "$suite: $nv already present, skipping"
            continue
        fi
        add+=("$f")
    done
    if (( ${#add[@]} == 0 )); then
        echo "$suite: nothing to add"
        continue
    fi
    "${REPREPRO[@]}" includedeb "$suite" "${add[@]}"
done

./publish.sh

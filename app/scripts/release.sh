#!/bin/sh
# Cuts a release: writes app/VERSION, commits, tags v<version> and pushes. CI builds, signs when the secrets exist,
# and publishes the zip and DMG with notes from the commits since the previous tag.
set -eu
cd "$(dirname "$0")/.."
[ $# -eq 1 ] || { echo "usage: scripts/release.sh <version>  (e.g. 1.0.1)" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "commit or stash your changes first" >&2; exit 1; }
echo "$1" > VERSION
git commit -qm "Release v$1" VERSION
git tag "v$1"
git push -q origin HEAD "v$1"
echo "tagged v$1; the release appears at https://github.com/takeachangs/mike/releases once CI finishes"

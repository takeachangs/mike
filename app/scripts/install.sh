#!/bin/bash
# Installs dist/CallNotch.app into /Applications (building it first if needed), replacing an older copy safely: the
# running app is asked to quit (it saves any session first), the old bundle is removed, and the new one is copied
# fresh. Copying over a signed app in place keeps the old signature cached for those files and macOS kills the new
# binary at launch, so never `cp -R` over an installed copy.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d dist/CallNotch.app ] || scripts/build-app.sh

pid=$(cat ~/.claude-call/app.pid 2>/dev/null || true)
if [ -n "$pid" ] && ps -o comm= -p "$pid" 2>/dev/null | grep -q CallNotch; then
    kill -TERM "$pid"
    for _ in $(seq 1 75); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done  # up to 15 s for a session to save
fi
pkill -x CallNotch 2>/dev/null || true  # a session's notch, if one is up

rm -rf /Applications/CallNotch.app
ditto dist/CallNotch.app /Applications/CallNotch.app
echo "installed /Applications/CallNotch.app ($(/Applications/CallNotch.app/Contents/MacOS/CallNotch --version))"
[ "${1:-}" = "--open" ] && open /Applications/CallNotch.app || true

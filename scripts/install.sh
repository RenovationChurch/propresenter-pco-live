#!/bin/bash
# Build PCOSync.app, install it in /Applications (or ~/Applications if that
# isn't writable) and start it. Re-run any time to update.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh

DEST=/Applications
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

if pgrep -x PCOSync >/dev/null; then
  echo "==> Quitting the running PCOSync (it releases LIVE control if it holds it)…"
  osascript -e 'tell application id "com.renovationchurch.pcosync" to quit' >/dev/null 2>&1 || pkill -x PCOSync || true
  for _ in $(seq 1 30); do pgrep -x PCOSync >/dev/null || break; sleep 0.5; done
fi

rm -rf "$DEST/PCOSync.app"
cp -R build/PCOSync.app "$DEST/"
echo "==> Installed $DEST/PCOSync.app"

open "$DEST/PCOSync.app"
echo "==> PCOSync is running in the menu bar. Dashboard: http://127.0.0.1:8642"
echo "    Turn on 'Open at Login' from its menu-bar menu."

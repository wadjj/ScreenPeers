#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/dist/ScreenPeers.app"
mode="${1:-run}"
if [[ "$mode" != "--build-only" ]]; then pkill -x ScreenPeers || true; fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$root/dist/module-cache"
cp "$root/Info.plist" "$app/Contents/Info.plist"
# Only the current provider bridge ships in the app; legacy helpers stay in source.
rm -f "$app/Contents/Resources/agent.py" "$app/Contents/Resources/ddns.py"
cp "$root/Resources/providers.py" "$app/Contents/Resources/"
cp "$root/Docs/DNS-SETUP.md" "$app/Contents/Resources/"
MACOSX_DEPLOYMENT_TARGET=13.0 clang -O2 -c "$root/Sources/Connections.c" -o "$root/dist/Connections.o"
MACOSX_DEPLOYMENT_TARGET=13.0 swiftc -O -module-cache-path "$root/dist/module-cache" \
  "$root/Sources/"*.swift "$root/dist/Connections.o" -o "$app/Contents/MacOS/ScreenPeers"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
case "$mode" in
  --build-only) exit 0 ;;
  --debug) exec lldb -- "$app/Contents/MacOS/ScreenPeers" ;;
  run|--verify|--logs|--telemetry) open "$app" ;;
  *) echo "Usage: $0 [--build-only|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
if [[ "$mode" == "--verify" ]]; then sleep 2; pgrep -x ScreenPeers; fi
if [[ "$mode" == "--logs" || "$mode" == "--telemetry" ]]; then
  exec /usr/bin/log stream --info --style compact --predicate 'process == "ScreenPeers"'
fi

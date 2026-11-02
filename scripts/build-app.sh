#!/bin/bash
# Builds DockBar, signs it, and installs it to ~/Applications.
# Quit DockBar to restore the macOS Dock. If the Dock stays hidden, run scripts/restore-dock.sh.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
  echo "Generating app icon..."
  mkdir -p "$ROOT/build/icon.iconset"
  swift "$ROOT/scripts/make-icon.swift" "$ROOT/build/icon-1024.png"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ROOT/build/icon-1024.png" --out "$ROOT/build/icon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ROOT/build/icon-1024.png" --out "$ROOT/build/icon.iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ROOT/build/icon.iconset" -o "$ROOT/Resources/AppIcon.icns"
fi

echo "Compiling..."
swift build -c release

APP="$ROOT/build/DockBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/DockBar" "$APP/Contents/MacOS/DockBar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/MacOS/DockBar"

IDENTITY="${CODESIGN_IDENTITY:-DockBar Development}"
"$ROOT/scripts/ensure-signing-identity.sh"
echo "Signing with $IDENTITY"
codesign --force --sign "$IDENTITY" --identifier com.sanfordliu.DockBar "$APP"

mkdir -p "$HOME/Applications"
if pgrep -x DockBar >/dev/null 2>&1; then
  echo "Quitting DockBar so it can restore the Dock..."
  killall DockBar 2>/dev/null || true
  for _ in $(seq 1 25); do
    if ! pgrep -x DockBar >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done
  if pgrep -x DockBar >/dev/null 2>&1; then
    echo "DockBar is still running. Quit it, then run this script again." >&2
    exit 1
  fi
fi
rm -rf "$HOME/Applications/DockBar.app"
cp -R "$APP" "$HOME/Applications/DockBar.app"
echo "Installed ~/Applications/DockBar.app"
echo "Open it from Finder, or run: open ~/Applications/DockBar.app"
echo "Quit DockBar from its menu bar icon to restore the macOS Dock."

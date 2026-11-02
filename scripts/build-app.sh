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
# Several certificates can share the name. Permissions stick to the oldest one.
HASH="$(
  python3 - "$IDENTITY" << 'PY'
import datetime, os, subprocess, sys
name = sys.argv[1]
listed = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
valid = set()
for line in listed.splitlines():
    if name not in line:
        continue
    parts = line.split()
    if len(parts) >= 2:
        valid.add(parts[1].strip('"'))
keychain = os.path.expanduser("~/Library/Keychains/login.keychain-db")
pem = subprocess.check_output(["security", "find-certificate", "-a", "-c", name, "-p", keychain], text=True)
best = None
best_date = None
for chunk in pem.split("-----END CERTIFICATE-----"):
    if "BEGIN CERTIFICATE" not in chunk:
        continue
    body = chunk.strip() + "\n-----END CERTIFICATE-----\n"
    info = subprocess.check_output(
        ["openssl", "x509", "-noout", "-fingerprint", "-sha1", "-startdate"],
        input=body, text=True,
    )
    fingerprint = None
    started = None
    for line in info.splitlines():
        if "Fingerprint=" in line:
            fingerprint = line.split("=", 1)[1].replace(":", "").strip()
        if line.startswith("notBefore="):
            started = datetime.datetime.strptime(line.split("=", 1)[1], "%b %d %H:%M:%S %Y %Z")
    if fingerprint not in valid or started is None:
        continue
    if best_date is None or started < best_date:
        best_date = started
        best = fingerprint
if best is None:
    sys.exit(f"No code-signing identity named {name}")
print(best)
PY
)"
echo "Signing with $HASH ($IDENTITY)"
codesign --force --sign "$HASH" --identifier com.sanfordliu.DockBar "$APP"

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

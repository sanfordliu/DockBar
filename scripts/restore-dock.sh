#!/bin/bash
# Puts the macOS Dock back if DockBar left it hidden.
# DockBar normally does this itself when it quits. A clean quit already restored
# the Dock, so this script must not write over that.

set -euo pipefail

DOMAIN="com.sanfordliu.DockBar"

if pgrep -x DockBar >/dev/null 2>&1; then
  killall DockBar 2>/dev/null || true
  for _ in $(seq 1 25); do
    if ! pgrep -x DockBar >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done
fi

read_default() {
  defaults read "$DOMAIN" "$1" 2>/dev/null || true
}

WAS_HIDING="$(read_default dockBarIsHidingDock)"
AUTOHIDE="$(read_default savedDockAutohide)"
HAD_DELAY="$(read_default savedDockHadDelay)"
DELAY="$(read_default savedDockAutohideDelay)"
DELAY_NOW="$(defaults read com.apple.dock autohide-delay 2>/dev/null || true)"

hidden_sentinel=0
if awk -v value="$DELAY_NOW" 'BEGIN { exit !((value + 0) >= 999.5 && (value + 0) <= 1000.5) }'; then
  hidden_sentinel=1
fi

if [[ "$WAS_HIDING" != "1" && "$hidden_sentinel" != "1" ]]; then
  echo "The macOS Dock is already restored."
  exit 0
fi

if [[ -n "$AUTOHIDE" ]]; then
  if [[ "$AUTOHIDE" == "1" ]]; then
    defaults write com.apple.dock autohide -bool true
  else
    defaults write com.apple.dock autohide -bool false
  fi
  if [[ "$HAD_DELAY" == "1" && -n "$DELAY" ]]; then
    defaults write com.apple.dock autohide-delay -float "$DELAY"
  else
    defaults delete com.apple.dock autohide-delay 2>/dev/null || true
  fi
elif [[ "$hidden_sentinel" == "1" ]]; then
  defaults delete com.apple.dock autohide-delay 2>/dev/null || true
fi

defaults write "$DOMAIN" dockBarIsHidingDock -bool false
killall Dock
echo "The macOS Dock is restored."

#!/bin/bash
# Puts the macOS Dock back if DockBar is not running.
# DockBar normally does this itself when it quits.

set -euo pipefail

DOMAIN="com.sanfordliu.DockBar"
killall DockBar 2>/dev/null || true
sleep 0.4

read_default() {
  defaults read "$DOMAIN" "$1" 2>/dev/null || true
}

WAS_HIDING="$(read_default dockBarIsHidingDock)"
AUTOHIDE="$(read_default savedDockAutohide)"
HAD_DELAY="$(read_default savedDockHadDelay)"
DELAY="$(read_default savedDockAutohideDelay)"

if [[ "$WAS_HIDING" == "1" && -n "$AUTOHIDE" ]]; then
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
else
  defaults delete com.apple.dock autohide-delay 2>/dev/null || true
  defaults write com.apple.dock autohide -bool false
fi

defaults write "$DOMAIN" dockBarIsHidingDock -bool false
killall Dock
echo "The macOS Dock is restored."

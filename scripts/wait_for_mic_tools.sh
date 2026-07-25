#!/bin/bash
set -euo pipefail
# Avoid zsh/bash nomatch errors when globs miss
shopt -s nullglob 2>/dev/null || true
echo "Waiting for PacketLogger.app and Bluetooth_macOS.mobileconfig…"
open 'https://developer.apple.com/download/all/?q=Additional%20Tools%20for%20Xcode'
open 'https://developer.apple.com/services-account/download?path=/OS_X/OS_X_Logs/Bluetooth_macOS.mobileconfig'
for i in $(seq 1 120); do
  PL=""
  for c in /Applications/PacketLogger.app "$HOME/Downloads/PacketLogger.app" /Volumes/*/Hardware/PacketLogger.app; do
    # shellcheck disable=SC2086
    if [[ -d $c ]]; then PL=$c; break; fi
  done
  CFG=""
  for c in "$HOME/Downloads/Bluetooth_macOS.mobileconfig" /tmp/Bluetooth_macOS.mobileconfig; do
    if [[ -f "$c" ]] && grep -q 'PayloadContent\|PayloadType' "$c" 2>/dev/null; then CFG=$c; break; fi
  done
  # Also accept freshly mounted Additional Tools DMG
  DMG=""
  for f in "$HOME"/Downloads/Additional_Tools*.dmg; do
    DMG=$f
    break
  done
  if [[ -n "${DMG:-}" && -z "$PL" ]]; then
    echo "Mounting $DMG"
    hdiutil attach "$DMG" -nobrowse >/tmp/hypervibe-dmg.txt
    VOL=$(awk -F'\t' '/\/Volumes\//{print $NF}' /tmp/hypervibe-dmg.txt | tail -1)
    if [[ -d "$VOL/Hardware/PacketLogger.app" ]]; then
      cp -R "$VOL/Hardware/PacketLogger.app" /Applications/
      PL=/Applications/PacketLogger.app
    fi
  fi
  if [[ -n "$PL" && -n "$CFG" ]]; then
    echo "FOUND PacketLogger=$PL"
    echo "FOUND profile=$CFG"
    open "$CFG"
    echo "Finish profile install in System Settings → Profiles, then reboot."
    exit 0
  fi
  echo "still waiting ($i) PL=${PL:-no} CFG=${CFG:-no}"
  sleep 5
done
echo "Timed out waiting for downloads." >&2
exit 1

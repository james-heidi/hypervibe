#!/bin/bash
# Install prerequisites for A2854 remote mic (zero extra hardware path).
set -euo pipefail

echo "== HyperVibe remote mic setup =="

need_reboot=0

# 1) BlackHole 2ch
if [[ -d /Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver ]]; then
  echo "✓ BlackHole2ch.driver present"
else
  echo "→ Installing BlackHole 2ch via Homebrew…"
  brew install --cask blackhole-2ch
  need_reboot=1
fi

# 2) Bluetooth logging profile
PROFILE_SRC=""
for c in \
  "$HOME/Downloads/Bluetooth_macOS.mobileconfig" \
  /tmp/Bluetooth_macOS.mobileconfig
do
  if [[ -f "$c" ]] && grep -q 'PayloadContent\|PayloadType' "$c" 2>/dev/null; then
    PROFILE_SRC="$c"
    break
  fi
done

if profiles list 2>/dev/null | grep -qi 'bluetooth'; then
  echo "✓ A Bluetooth-related configuration profile is installed"
else
  if [[ -z "$PROFILE_SRC" ]]; then
    echo "→ Opening Apple Developer Bluetooth profile download…"
    echo "  Sign in, save Bluetooth_macOS.mobileconfig to ~/Downloads, re-run this script."
    open 'https://developer.apple.com/feedback-assistant/profiles-and-logs/?platform=macos&name=bluetooth'
    open 'https://developer.apple.com/services-account/download?path=/OS_X/OS_X_Logs/Bluetooth_macOS.mobileconfig'
  else
    echo "→ Installing Bluetooth logging profile from $PROFILE_SRC"
    open "$PROFILE_SRC"
    echo "  Finish install in System Settings → Privacy & Security → Profiles, then reboot."
    need_reboot=1
  fi
fi

# 3) PacketLogger from Additional Tools for Xcode
PACKETLOGGER=""
for c in \
  /Applications/PacketLogger.app/Contents/Resources/packetlogger \
  "$HOME/Applications/PacketLogger.app/Contents/Resources/packetlogger" \
  "$HOME/Downloads/PacketLogger.app/Contents/Resources/packetlogger"
do
  if [[ -x "$c" ]]; then PACKETLOGGER="$c"; break; fi
done

# Also check mounted Additional Tools DMGs
if [[ -z "$PACKETLOGGER" ]]; then
  for vol in /Volumes/*; do
    cand="$vol/Hardware/PacketLogger.app"
    if [[ -d "$cand" ]]; then
      echo "→ Copying PacketLogger from $cand to /Applications"
      cp -R "$cand" /Applications/
      PACKETLOGGER=/Applications/PacketLogger.app/Contents/Resources/packetlogger
      break
    fi
  done
fi

if [[ -n "$PACKETLOGGER" ]]; then
  echo "✓ PacketLogger at $PACKETLOGGER"
else
  echo "→ Opening Additional Tools for Xcode download page…"
  echo "  Download Additional Tools for Xcode, open the DMG, copy Hardware/PacketLogger.app to /Applications"
  open 'https://developer.apple.com/download/all/?q=Additional%20Tools%20for%20Xcode'
fi

# 4) Allow passwordless packetlogger for HyperVibe (optional sudoers hint)
echo
echo "PacketLogger live HCI requires root. For HyperVibe's sudo -n launch, add a sudoers line:"
echo "  %admin ALL=(root) NOPASSWD: $PACKETLOGGER"
echo "  (replace path after installing PacketLogger)"

# 5) Smoke checks
echo
echo "== Smoke checks =="
echo -n "Remote address: "
/usr/sbin/system_profiler SPBluetoothDataType 2>/dev/null | awk '
  /Apple TV/ && /Remote/ {r=1}
  r && /Address:/ { sub(/^.*Address: */,""); print; exit }
' || echo "(not found)"

if [[ $need_reboot -eq 1 ]]; then
  echo
  echo "⚠ Reboot required for BlackHole / logging profile to take effect."
fi

echo
echo "Done. Then: ./build.sh && ./create_app_bundle.sh && open HyperVibe.app"
echo "Hold Siri and speak; select BlackHole 2ch as input in the dictation app."

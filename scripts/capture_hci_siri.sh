#!/bin/bash
# Phase 1 gate: live PacketLogger HCI while holding Siri.
set -euo pipefail

PACKETLOGGER="${PACKETLOGGER:-}"
if [[ -z "$PACKETLOGGER" ]]; then
  for c in \
    /Applications/PacketLogger.app/Contents/Resources/packetlogger \
    "$HOME/Applications/PacketLogger.app/Contents/Resources/packetlogger" \
    "$HOME/Downloads/PacketLogger.app/Contents/Resources/packetlogger"
  do
    [[ -x "$c" ]] && PACKETLOGGER="$c" && break
  done
fi

if [[ -z "${PACKETLOGGER}" ]]; then
  echo "PacketLogger not found. Run scripts/setup_remote_mic.sh first." >&2
  exit 1
fi

ADDR=$(/usr/sbin/system_profiler SPBluetoothDataType 2>/dev/null | awk '
  /Apple TV/ && /Remote/ {r=1}
  r && /Address:/ { sub(/^.*Address: */,""); print; exit }
')
ADDR=${ADDR:-}
OUT=${1:-/tmp/hypervibe-hci-siri.pklg.txt}

echo "PacketLogger: $PACKETLOGGER"
echo "Remote: ${ADDR:-unknown}"
echo "Hold Siri and speak. Ctrl-C to stop."
echo "Logging text nhdr to $OUT"

# Live convert to nhdr text; filter RECV lines (and optional MAC).
sudo "$PACKETLOGGER" convert -s -f nhdr 2>"${OUT}.err" | tee "$OUT" | awk -v addr="$ADDR" '
  BEGIN { IGNORECASE=1 }
  /Profile Required/ { print "ERROR: Bluetooth logging profile required" > "/dev/stderr"; exit 2 }
  /RECV/ {
    if (addr == "" || index($0, addr) || index($0, "00:00:00:00:00:00")) {
      print
      if ($0 ~ /B8/) frames++
    }
  }
  END { print "frames_with_B8=" frames > "/dev/stderr" }
'

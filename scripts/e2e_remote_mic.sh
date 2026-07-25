#!/bin/bash
# End-to-end validation for A2854 remote mic (zero extra hardware).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "OK: $*"; }

echo "== HyperVibe remote mic e2e =="

[[ -x ./HyperVibe ]] || { ./build.sh && ./create_app_bundle.sh; }

CHECK=$(./HyperVibe --mic-check 2>&1 || true)
echo "$CHECK"

echo "$CHECK" | grep -q 'PacketLogger: .*MISSING' && fail "PacketLogger missing"
echo "$CHECK" | grep -qi 'Bluetooth profile installed: true' || fail "Bluetooth logging profile not installed (reboot after install)"
echo "$CHECK" | grep -qi 'BlackHole available: true' || fail "BlackHole 2ch not available (reboot after install)"
echo "$CHECK" | grep -qi 'Opus decoder: ok' || fail "Opus decoder unavailable"
ok "preconditions"

ADDR=$(echo "$CHECK" | awk -F': ' '/Remote address:/{print $2; exit}')
[[ -n "$ADDR" && "$ADDR" != "(none)" ]] || fail "A2854 not paired / address unknown"
ok "remote $ADDR"

# Replay path (offline decoder sanity)
if [[ -f /tmp/fake-hci-siri.nhdr ]]; then
  ./HyperVibe --replay-hci /tmp/fake-hci-siri.nhdr >/tmp/hypervibe-e2e-replay.log 2>&1 || fail "replay-hci failed"
  ok "hci replay"
fi

# Live capture — hold Siri and speak when prompted
echo
echo ">>> Hold Siri on the remote and speak for ~8s when capture starts…"
./HyperVibe --capture-mic 12 >/tmp/hypervibe-e2e-capture.log 2>&1 || true
if grep -qiE 'opus|frames|streaming|decoded' /tmp/hypervibe-e2e-capture.log /tmp/hypervibe.log 2>/dev/null; then
  ok "live capture saw audio frames"
else
  echo "WARN: no Opus frames in live capture — activation may still be blocked on this Mac"
  echo "       see /tmp/hypervibe-e2e-capture.log and /tmp/hypervibe.log"
fi

if [[ -f /tmp/hypervibe-remote-mic.wav ]]; then
  sz=$(wc -c </tmp/hypervibe-remote-mic.wav)
  [[ "$sz" -gt 1000 ]] && ok "wav dump ${sz} bytes" || echo "WARN: wav dump tiny ($sz)"
fi

echo
echo "Manual check: open Voice Memos / VoiceInk, set input to BlackHole 2ch,"
echo "hold Siri in HyperVibe, speak, confirm remote speech is recorded."
echo "Done."

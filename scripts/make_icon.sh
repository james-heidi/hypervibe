#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
xcrun swiftc -O gen_icon.swift WaveGlyph.swift -o /tmp/hypervibe-gen-icon
/tmp/hypervibe-gen-icon
iconutil -c icns HyperVibe.iconset -o HyperVibe.icns
echo "Wrote HyperVibe.icns"

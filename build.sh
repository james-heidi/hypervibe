#!/bin/bash

# Build script for HyperVibe
# Make sure Xcode Command Line Tools are installed: xcode-select --install

set -e

echo "Building HyperVibe..."

SWIFT_FILES=(
    "main.swift"
    "SiriRemoteApp.swift"
    "MenuBarManager.swift"
    "RemoteDetector.swift"
    "RemoteInputHandler.swift"
    "RemoteWebServer.swift"
    "CursorController.swift"
    "MediaController.swift"
    "MediaKeyInterceptor.swift"
    "TouchHandler.swift"
    "SystemVolume.swift"
    "OpusVoiceDecoder.swift"
    "BlackHoleAudioSink.swift"
    "MicActivator.swift"
    "MicCapturePipeline.swift"
    "RemoteMicController.swift"
    "HCIEventTap.swift"
)

OPUS_INCLUDE="${OPUS_INCLUDE:-Vendor/libopus/include}"
OPUS_LIB="${OPUS_LIB:-Vendor/libopus/lib}"
if [[ -d /opt/homebrew/opt/opus/include && -f /opt/homebrew/opt/opus/lib/libopus.a ]]; then
    OPUS_INCLUDE=/opt/homebrew/opt/opus/include
    OPUS_LIB=/opt/homebrew/opt/opus/lib
fi
# Match host SDK so Homebrew libopus (built for current macOS) links cleanly.
MACOSX_MIN="${MACOSX_MIN:-$(sw_vers -productVersion | cut -d. -f1).0}"

# Find SDK path
SDK_PATH=$(xcrun --show-sdk-path --sdk macosx 2>/dev/null || echo "")

if [ -z "$SDK_PATH" ]; then
    echo "Error: macOS SDK not found. Please install Xcode Command Line Tools:"
    echo "  xcode-select --install"
    exit 1
fi

echo "Using SDK: $SDK_PATH"

# Architectures: host-only by default; HYPERVIBE_UNIVERSAL=1 builds arm64+x86_64 and lipo-merges.
if [ "${HYPERVIBE_UNIVERSAL:-0}" = "1" ]; then
    TARGETS=("arm64-apple-macosx${MACOSX_MIN}" "x86_64-apple-macosx${MACOSX_MIN}")
else
    ARCH=$(uname -m)
    if [ "$ARCH" == "arm64" ]; then
        TARGETS=("arm64-apple-macosx${MACOSX_MIN}")
    else
        TARGETS=("x86_64-apple-macosx${MACOSX_MIN}")
    fi
fi

echo "Building for: ${TARGETS[*]}"

# Remove the previous binary first so a failed build can't get packaged as stale output.
rm -f HyperVibe

# Build one slice per target, then merge.
SLICES=()
for TARGET in "${TARGETS[@]}"; do
    SLICE="HyperVibe.${TARGET%%-*}"
    xcrun swiftc \
        -sdk "$SDK_PATH" \
        -target "$TARGET" \
        -o "$SLICE" \
        "${SWIFT_FILES[@]}" \
        -import-objc-header SiriRemote-Bridging-Header.h \
        -I "$OPUS_INCLUDE" \
        -L "$OPUS_LIB" \
        -lopus \
        -F "$SDK_PATH/System/Library/PrivateFrameworks" \
        -framework IOKit \
        -framework CoreGraphics \
        -framework AudioToolbox \
        -framework Carbon \
        -framework AppKit \
        -framework Network \
        -framework CoreAudio \
        -framework IOBluetooth \
        -framework MultitouchSupport
    SLICES+=("$SLICE")
done

if [ "${#SLICES[@]}" -gt 1 ]; then
    lipo -create "${SLICES[@]}" -output HyperVibe
    rm -f "${SLICES[@]}"
else
    mv "${SLICES[0]}" HyperVibe
fi

if [ $? -eq 0 ]; then
    echo ""
    echo "✓ Build successful!"
    echo ""
    echo "To create a proper macOS app bundle, run:"
    echo "  ./create_app_bundle.sh"
    echo ""
    echo "Or run directly with:"
    echo "  ./HyperVibe"
else
    echo ""
    echo "✗ Build failed!"
    exit 1
fi

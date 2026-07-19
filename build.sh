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
)

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
    TARGETS=("arm64-apple-macosx11.0" "x86_64-apple-macosx11.0")
else
    ARCH=$(uname -m)
    if [ "$ARCH" == "arm64" ]; then
        TARGETS=("arm64-apple-macosx11.0")
    else
        TARGETS=("x86_64-apple-macosx11.0")
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
        -F "$SDK_PATH/System/Library/PrivateFrameworks" \
        -framework IOKit \
        -framework CoreGraphics \
        -framework AudioToolbox \
        -framework Carbon \
        -framework AppKit \
        -framework Network \
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

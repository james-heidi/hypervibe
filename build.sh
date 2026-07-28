#!/bin/bash

# Build script for HyperVibe
# Make sure Xcode Command Line Tools are installed: xcode-select --install

set -euo pipefail

echo "Building HyperVibe..."

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

SWIFT_FILES=(
    "main.swift"
    "SiriRemoteApp.swift"
    "MenuBarManager.swift"
    "RemoteDetector.swift"
    "RemoteInputHandler.swift"
    "CursorController.swift"
    "MediaController.swift"
    "MediaKeyInterceptor.swift"
    "TouchHandler.swift"
    "SystemVolume.swift"
    "OpusVoiceDecoder.swift"
    "HCICaptureBootstrap.swift"
    "MicActivator.swift"
    "MicCapturePipeline.swift"
    "RemoteMicController.swift"
    "RemoteMicLab.swift"
    "TranscriptionEngine.swift"
    "TranscriptionKeychain.swift"
    "OpenAITranscriptionEngine.swift"
    "ParakeetTranscriptionEngine.swift"
    "HCIHelperProtocol.swift"
    "HCIHelperClient.swift"
)

OPUS_INCLUDE="${OPUS_INCLUDE:-Vendor/libopus/include}"
OPUS_LIB="${OPUS_LIB:-Vendor/libopus/lib}"
if [[ -d /opt/homebrew/opt/opus/include && -f /opt/homebrew/opt/opus/lib/libopus.a ]]; then
    OPUS_INCLUDE=/opt/homebrew/opt/opus/include
    OPUS_LIB=/opt/homebrew/opt/opus/lib
fi
# Opus is linked statically (the .a is passed directly to the linker) so the
# shipped app has no Homebrew dylib dependency.
if [[ ! -f "$OPUS_LIB/libopus.a" ]]; then
    echo "Error: libopus.a not found in $OPUS_LIB."
    echo "  Install it with: brew install opus"
    exit 1
fi

# FluidAudio requires macOS 14+. Pin deployment target (do not follow host major).
HOST_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [[ "$HOST_MAJOR" -lt 14 ]]; then
    echo "Error: Parakeet/FluidAudio requires macOS 14 or later (host is $HOST_MAJOR)."
    exit 1
fi
MACOSX_MIN="${MACOSX_MIN:-14.0}"

SDK_PATH=$(xcrun --show-sdk-path --sdk macosx 2>/dev/null || echo "")
if [ -z "$SDK_PATH" ]; then
    echo "Error: macOS SDK not found. Please install Xcode Command Line Tools:"
    echo "  xcode-select --install"
    exit 1
fi

echo "Using SDK: $SDK_PATH"

# Build FluidAudio dependency (models are NOT downloaded here).
FLUID_DEPS="$ROOT/Vendor/FluidAudioDeps"
echo "Building FluidAudio dependency..."
(
    cd "$FLUID_DEPS"
    swift build -c release
)

ARCH=$(uname -m)
if [ "${HYPERVIBE_UNIVERSAL:-0}" = "1" ]; then
    echo "Error: HYPERVIBE_UNIVERSAL is not supported with FluidAudio object linking yet."
    exit 1
fi

if [ "$ARCH" == "arm64" ]; then
    TARGETS=("arm64-apple-macosx${MACOSX_MIN}")
    FLUID_TRIPLE="arm64-apple-macosx"
else
    TARGETS=("x86_64-apple-macosx${MACOSX_MIN}")
    FLUID_TRIPLE="x86_64-apple-macosx"
fi

FLUID_BIN="$FLUID_DEPS/.build/${FLUID_TRIPLE}/release"
if [[ ! -d "$FLUID_BIN/Modules" ]]; then
    # Fallback for hosts where swift uses a different triple folder name.
    FLUID_BIN="$(cd "$FLUID_DEPS" && swift build -c release --show-bin-path)"
fi
FLUID_CHECKOUT="$FLUID_DEPS/.build/checkouts/FluidAudio"
FLUID_FASTCLUSTER_INC="$FLUID_CHECKOUT/Sources/FastClusterWrapper/include"
FLUID_MACHTASK_INC="$FLUID_CHECKOUT/Sources/MachTaskSelfWrapper/include"
echo "FluidAudio bin: $FLUID_BIN"

pack_static_lib() {
    local name="$1"
    local build_dir="$2"
    local out="$FLUID_BIN/lib${name}.a"
    rm -f "$out"
    local objs=()
    while IFS= read -r -d '' obj; do
        objs+=("$obj")
    done < <(find "$build_dir" -name '*.o' -print0)
    if [[ ${#objs[@]} -eq 0 ]]; then
        echo "Error: no object files in $build_dir"
        exit 1
    fi
    ar -rcs "$out" "${objs[@]}"
}

pack_static_lib FluidAudio "$FLUID_BIN/FluidAudio.build"
pack_static_lib FastClusterWrapper "$FLUID_BIN/FastClusterWrapper.build"
pack_static_lib MachTaskSelfWrapper "$FLUID_BIN/MachTaskSelfWrapper.build"

echo "Building for: ${TARGETS[*]}"

rm -f HyperVibe

SLICES=()
for TARGET in "${TARGETS[@]}"; do
    SLICE="HyperVibe.${TARGET%%-*}"
    xcrun swiftc \
        -sdk "$SDK_PATH" \
        -target "$TARGET" \
        -O \
        -o "$SLICE" \
        "${SWIFT_FILES[@]}" \
        -import-objc-header SiriRemote-Bridging-Header.h \
        -I "$OPUS_INCLUDE" \
        -I "$FLUID_BIN/Modules" \
        -I "$FLUID_FASTCLUSTER_INC" \
        -I "$FLUID_MACHTASK_INC" \
        -L "$FLUID_BIN" \
        "$OPUS_LIB/libopus.a" \
        -lFluidAudio \
        -lFastClusterWrapper \
        -lMachTaskSelfWrapper \
        -lc++ \
        -F "$SDK_PATH/System/Library/PrivateFrameworks" \
        -framework IOKit \
        -framework CoreGraphics \
        -framework AudioToolbox \
        -framework Carbon \
        -framework AppKit \
        -framework CoreAudio \
        -framework AVFoundation \
        -framework AVFAudio \
        -framework CoreML \
        -framework Accelerate \
        -framework NaturalLanguage \
        -framework Security \
        -framework MultitouchSupport
    SLICES+=("$SLICE")
done

if [ "${#SLICES[@]}" -gt 1 ]; then
    lipo -create "${SLICES[@]}" -output HyperVibe
    rm -f "${SLICES[@]}"
else
    mv "${SLICES[0]}" HyperVibe
fi

# Privileged helper (LaunchDaemon) — one admin install, then socket IPC.
echo "Building HyperVibeHCIHelper..."
rm -f HyperVibeHCIHelper
HELPER_SLICE="HyperVibeHCIHelper.${TARGETS[0]%%-*}"
xcrun swiftc \
    -sdk "$SDK_PATH" \
    -target "${TARGETS[0]}" \
    -O \
    -framework SystemConfiguration \
    -o "$HELPER_SLICE" \
    HyperVibeHCIHelperMain.swift \
    HCIHelperServer.swift \
    HCIHelperProtocol.swift \
    HCICaptureBootstrap.swift
mv "$HELPER_SLICE" HyperVibeHCIHelper
chmod 755 HyperVibeHCIHelper

echo ""
echo "✓ Build successful!"
echo ""
echo "To create a proper macOS app bundle, run:"
echo "  ./create_app_bundle.sh"
echo ""
echo "Or run directly with:"
echo "  ./HyperVibe"

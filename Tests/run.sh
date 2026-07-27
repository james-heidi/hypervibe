#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

xcrun swiftc \
    Tests/HCICaptureBootstrapTests.swift \
    HCICaptureBootstrap.swift \
    -o /tmp/hypervibe-bootstrap-tests
/tmp/hypervibe-bootstrap-tests

xcrun swiftc \
    Tests/HCIHelperProtocolTests.swift \
    HCIHelperProtocol.swift \
    HCICaptureBootstrap.swift \
    -o /tmp/hypervibe-helper-protocol-tests
/tmp/hypervibe-helper-protocol-tests

# FluidAudio-backed transcription tests
(
    cd Vendor/FluidAudioDeps
    swift build -c release >/tmp/hypervibe-fluidaudio-build.log
)
FLUID_BIN="$(cd Vendor/FluidAudioDeps && swift build -c release --show-bin-path)"
pack_static_lib() {
    local name="$1"
    local build_dir="$2"
    local out="$FLUID_BIN/lib${name}.a"
    rm -f "$out"
    local objs=()
    while IFS= read -r -d '' obj; do
        objs+=("$obj")
    done < <(find "$build_dir" -name '*.o' -print0)
    ar -rcs "$out" "${objs[@]}"
}
pack_static_lib FluidAudio "$FLUID_BIN/FluidAudio.build"
pack_static_lib FastClusterWrapper "$FLUID_BIN/FastClusterWrapper.build"
pack_static_lib MachTaskSelfWrapper "$FLUID_BIN/MachTaskSelfWrapper.build"

SDK_PATH=$(xcrun --show-sdk-path --sdk macosx)
HOST_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
TARGET="$(uname -m)-apple-macosx${HOST_MAJOR}.0"
FLUID_CHECKOUT="$ROOT/Vendor/FluidAudioDeps/.build/checkouts/FluidAudio"

xcrun swiftc \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    Tests/TranscriptionEngineTests.swift \
    TranscriptionEngine.swift \
    TranscriptionKeychain.swift \
    OpenAITranscriptionEngine.swift \
    ParakeetTranscriptionEngine.swift \
    Tests/RMDebugStub.swift \
    -I "$FLUID_BIN/Modules" \
    -I "$FLUID_CHECKOUT/Sources/FastClusterWrapper/include" \
    -I "$FLUID_CHECKOUT/Sources/MachTaskSelfWrapper/include" \
    -L "$FLUID_BIN" \
    -lFluidAudio \
    -lFastClusterWrapper \
    -lMachTaskSelfWrapper \
    -lc++ \
    -framework Foundation \
    -framework Security \
    -framework CoreML \
    -framework AVFoundation \
    -framework AVFAudio \
    -framework Accelerate \
    -framework NaturalLanguage \
    -o /tmp/hypervibe-transcription-tests
/tmp/hypervibe-transcription-tests

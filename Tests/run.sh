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
    ModelPreparation.swift \
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

xcrun swiftc \
    Tests/TranscriptPolisherTests.swift \
    TranscriptPolisher.swift \
    TranscriptionKeychain.swift \
    Tests/TranscriptionEngineErrorStub.swift \
    Tests/RMDebugStub.swift \
    -framework Foundation \
    -framework Security \
    -o /tmp/hypervibe-polisher-tests
/tmp/hypervibe-polisher-tests

xcrun swiftc \
    Tests/PermissionStateTests.swift \
    PermissionState.swift \
    -framework AppKit \
    -framework ApplicationServices \
    -framework CoreGraphics \
    -o /tmp/hypervibe-permission-tests
/tmp/hypervibe-permission-tests

xcrun swiftc \
    Tests/SetupFlowTests.swift \
    SetupFlow.swift \
    PermissionState.swift \
    HelperInstallCoordinator.swift \
    HCIHelperClient.swift \
    HCIHelperProtocol.swift \
    HCICaptureBootstrap.swift \
    Tests/RMDebugStub.swift \
    -framework AppKit \
    -framework ApplicationServices \
    -framework CoreGraphics \
    -o /tmp/hypervibe-setup-tests
/tmp/hypervibe-setup-tests

xcrun swiftc \
    Tests/ButtonMappingStoreTests.swift \
    ButtonMappingStore.swift \
    ButtonActions.swift \
    -framework Foundation \
    -o /tmp/hypervibe-mapping-tests
/tmp/hypervibe-mapping-tests

xcrun swiftc \
    Tests/DictationRecoveryTests.swift \
    DictationRecovery.swift \
    -framework Foundation \
    -o /tmp/hypervibe-recovery-tests
/tmp/hypervibe-recovery-tests

xcrun swiftc \
    Tests/MicReadinessStateTests.swift \
    MicReadinessState.swift \
    -framework Foundation \
    -o /tmp/hypervibe-mic-readiness-tests
/tmp/hypervibe-mic-readiness-tests

xcrun swiftc \
    Tests/WaveGlyphTests.swift \
    WaveGlyph.swift \
    -framework CoreGraphics \
    -framework Foundation \
    -o /tmp/hypervibe-wave-tests
/tmp/hypervibe-wave-tests

SDK_PATH=$(xcrun --show-sdk-path --sdk macosx)
HOST_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
TARGET="$(uname -m)-apple-macosx${HOST_MAJOR}.0"
FLUID_BIN="$(cd Vendor/FluidAudioDeps && swift build -c release --show-bin-path)"
FLUID_CHECKOUT="$ROOT/Vendor/FluidAudioDeps/.build/checkouts/FluidAudio"
xcrun swiftc \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    Tests/ModelPreparationTests.swift \
    ModelPreparation.swift \
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
    -framework CoreML \
    -framework AVFoundation \
    -framework AVFAudio \
    -framework Accelerate \
    -framework NaturalLanguage \
    -o /tmp/hypervibe-modelprep-tests
/tmp/hypervibe-modelprep-tests

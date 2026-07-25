//
//  BlackHoleAudioSink.swift
//  HyperVibe
//
//  Writes PCM into BlackHole 2ch (loopback) so other apps can select it as input.
//

import AudioToolbox
import CoreAudio
import Foundation

/// Plays mono PCM into a virtual loopback output device (BlackHole 2ch).
final class BlackHoleAudioSink {
    /// Prefer BlackHole; `HYPERVIBE_AUDIO_SINK` can override for diagnostics (e.g. LoomAudioDevice).
    static var preferredNames: [String] {
        if let override = ProcessInfo.processInfo.environment["HYPERVIBE_AUDIO_SINK"], !override.isEmpty {
            return [override]
        }
        return ["BlackHole 2ch", "BlackHole"]
    }

    private let queue = DispatchQueue(label: "com.hypervibe.blackhole-sink")
    private var audioUnit: AudioUnit?
    private var deviceID: AudioDeviceID = 0
    private var ring = [Float]()
    private let ringLock = NSLock()
    private let maxRingSamples = 48_000 // ~1 s @ 48 kHz
    private var isRunning = false
    private(set) var deviceName: String?

    var isAvailable: Bool { findBlackHoleDevice() != nil }

    @discardableResult
    func start() -> Bool {
        queue.sync {
            if isRunning { return true }
            guard let found = findBlackHoleDevice() else {
                rmDebug("🎤 BlackHole device not found — install blackhole-2ch and reboot")
                return false
            }
            deviceID = found.id
            deviceName = found.name

            var desc = AudioComponentDescription(
                componentType: kAudioUnitType_Output,
                componentSubType: kAudioUnitSubType_HALOutput,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            )
            guard let component = AudioComponentFindNext(nil, &desc) else {
                rmDebug("🎤 AudioComponentFindNext failed")
                return false
            }

            var unit: AudioUnit?
            guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else {
                rmDebug("🎤 AudioComponentInstanceNew failed")
                return false
            }

            var enableIO: UInt32 = 1
            var disableIO: UInt32 = 0
            var status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output,
                0,
                &enableIO,
                UInt32(MemoryLayout<UInt32>.size)
            )
            guard status == noErr else {
                rmDebug("🎤 EnableIO output failed: \(status)")
                AudioComponentInstanceDispose(unit)
                return false
            }
            status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input,
                1,
                &disableIO,
                UInt32(MemoryLayout<UInt32>.size)
            )
            guard status == noErr else {
                rmDebug("🎤 DisableIO input failed: \(status)")
                AudioComponentInstanceDispose(unit)
                return false
            }

            var dev = deviceID
            status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &dev,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                rmDebug("🎤 Set CurrentDevice failed: \(status)")
                AudioComponentInstanceDispose(unit)
                return false
            }

            var asbd = AudioStreamBasicDescription(
                mSampleRate: Float64(OpusVoiceDecoder.sampleRate),
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: 1,
                mBitsPerChannel: 32,
                mReserved: 0
            )
            status = AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input,
                0,
                &asbd,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            )
            guard status == noErr else {
                rmDebug("🎤 Set StreamFormat failed: \(status)")
                AudioComponentInstanceDispose(unit)
                return false
            }

            var callback = AURenderCallbackStruct(
                inputProc: blackHoleRenderCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            status = AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input,
                0,
                &callback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            )
            guard status == noErr else {
                rmDebug("🎤 SetRenderCallback failed: \(status)")
                AudioComponentInstanceDispose(unit)
                return false
            }

            status = AudioUnitInitialize(unit)
            guard status == noErr else {
                rmDebug("🎤 AudioUnitInitialize failed: \(status)")
                AudioComponentInstanceDispose(unit)
                return false
            }
            status = AudioOutputUnitStart(unit)
            guard status == noErr else {
                rmDebug("🎤 AudioOutputUnitStart failed: \(status)")
                AudioComponentInstanceDispose(unit)
                return false
            }

            audioUnit = unit
            isRunning = true
            rmDebug("🎤 BlackHole sink started on \(found.name) id=\(found.id)")
            return true
        }
    }

    func stop() {
        queue.sync {
            guard isRunning else { return }
            if let unit = audioUnit {
                AudioOutputUnitStop(unit)
                AudioUnitUninitialize(unit)
                AudioComponentInstanceDispose(unit)
            }
            audioUnit = nil
            isRunning = false
            ringLock.lock()
            ring.removeAll(keepingCapacity: true)
            ringLock.unlock()
            rmDebug("🎤 BlackHole sink stopped")
        }
    }

    /// Enqueue s16le mono PCM at 48 kHz.
    func enqueue(pcmS16: [Int16]) {
        guard !pcmS16.isEmpty else { return }
        ringLock.lock()
        for s in pcmS16 {
            ring.append(Float(s) / Float(Int16.max))
        }
        if ring.count > maxRingSamples {
            ring.removeFirst(ring.count - maxRingSamples)
        }
        ringLock.unlock()
    }

    /// Push silence so consumers see stream end quickly.
    func flushSilence(milliseconds: Int = 80) {
        let n = OpusVoiceDecoder.sampleRate * Int32(milliseconds) / 1000
        enqueue(pcmS16: [Int16](repeating: 0, count: Int(n)))
    }

    fileprivate func render(frames: UInt32, bufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        guard abl.count > 0, let raw = abl[0].mData else { return noErr }
        let out = raw.assumingMemoryBound(to: Float.self)
        let count = Int(frames)

        ringLock.lock()
        for i in 0..<count {
            if ring.isEmpty {
                out[i] = 0
            } else {
                out[i] = ring.removeFirst()
            }
        }
        ringLock.unlock()
        abl[0].mDataByteSize = UInt32(count * MemoryLayout<Float>.size)
        return noErr
    }

    private func findBlackHoleDevice() -> (id: AudioDeviceID, name: String)? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else { return nil }

        for id in deviceIDs {
            guard let name = deviceName(id) else { continue }
            for preferred in Self.preferredNames where name.localizedCaseInsensitiveContains(preferred) {
                // Prefer devices that have an output stream (we write as output).
                if deviceHasOutput(id) {
                    return (id, name)
                }
            }
        }
        return nil
    }

    private func deviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private func deviceHasOutput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }
}

private func blackHoleRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let ioData else { return noErr }
    let sink = Unmanaged<BlackHoleAudioSink>.fromOpaque(inRefCon).takeUnretainedValue()
    return sink.render(frames: inNumberFrames, bufferList: ioData)
}

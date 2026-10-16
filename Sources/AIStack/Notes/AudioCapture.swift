import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio

enum CaptureError: LocalizedError {
    case coreAudio(String, OSStatus)
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .coreAudio(let step, let status): return "\(step) failed (\(status))"
        case .noInputDevice: return "No microphone available"
        }
    }
}

extension AVAudioPCMBuffer {
    /// Copies samples into a buffer we own (tap/IOProc buffers are only valid during the callback).
    func deepCopy() -> AVAudioPCMBuffer? {
        guard frameLength > 0, let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            guard let src = source[index].mData, let dst = destination[index].mData else { continue }
            let bytes = min(source[index].mDataByteSize, destination[index].mDataByteSize)
            memcpy(dst, src, Int(bytes))
            destination[index].mDataByteSize = bytes
        }
        return copy
    }
}

enum CA {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func pid(_ object: AudioObjectID) -> pid_t? {
        var addr = address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer)
        }
        guard status == noErr, let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    /// Processes currently recording from any microphone.
    static func microphoneUsers() -> [(pid: pid_t, bundleID: String)] {
        objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).compactMap { process in
            guard uint32(process, kAudioProcessPropertyIsRunningInput) == 1 else { return nil }
            let pid = self.pid(process) ?? -1
            let bundleID = string(process, kAudioProcessPropertyBundleID)
                ?? NSRunningApplicationBundleID(pid)
                ?? "pid:\(pid)"
            return (pid, bundleID)
        }
    }
}

private func NSRunningApplicationBundleID(_ pid: pid_t) -> String? {
    guard pid > 0 else { return nil }
    return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
}

/// The user's microphone ("Me").
final class MicCapture {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private var running = false

    func start() throws {
        running = true
        try startEngine()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as? AVAudioEngine) === self.engine else { return }
            Log.info("Microphone configuration changed; restarting capture", "audio")
            self.restart()
        }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInputDevice }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let copy = buffer.deepCopy() else { return }
            self?.onBuffer?(copy)
        }
        engine.prepare()
        try engine.start()
        Log.info("Mic capture started: \(format.sampleRate) Hz, \(format.channelCount) ch", "audio")
    }

    private func restart() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        do { try startEngine() } catch { Log.error("Mic restart failed: \(error.localizedDescription)", "audio") }
    }

    func stop() {
        running = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Everything the Mac plays ("Them"), via a Core Audio process tap (no screen recording needed).
final class SystemAudioCapture {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private let queue = DispatchQueue(label: "aistack.systemaudio", qos: .userInitiated)

    func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "AI Stack call audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw CaptureError.coreAudio("Creating audio tap", status) }
        tapID = tap

        var addr = CA.address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard status == noErr, let tapFormat = AVAudioFormat(streamDescription: &asbd) else {
            stop()
            throw CaptureError.coreAudio("Reading tap format", status)
        }
        format = tapFormat

        guard let output = CA.defaultOutputDevice(), let outputUID = CA.string(output, kAudioDevicePropertyDeviceUID) else {
            stop()
            throw CaptureError.coreAudio("Finding output device", -1)
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AI Stack Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else { stop(); throw CaptureError.coreAudio("Creating aggregate device", status) }
        aggregateID = device

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            guard let self, let format = self.format,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                  let copy = buffer.deepCopy() else { return }
            self.onBuffer?(copy)
        }
        guard status == noErr else { stop(); throw CaptureError.coreAudio("Creating IO proc", status) }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { stop(); throw CaptureError.coreAudio("Starting system audio", status) }
        Log.info("System audio capture started: \(tapFormat.sampleRate) Hz, \(tapFormat.channelCount) ch", "audio")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}

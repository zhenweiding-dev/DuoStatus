import CoreAudio

struct VolumeState: Equatable {
    var available = false            // whether the default output device exposes a volume
    var level: Float = 0             // 0...1
    var muted = false

    var outputName = ""
    var inputName = ""
}

struct AudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
}

/// Tracks volume and mute on the default output device, re-attaching its listeners
/// whenever that device changes.
final class VolumeMonitor {
    private(set) var state = VolumeState()
    var onChange: (() -> Void)?

    // 'vmvc' —— kAudioHardwareServiceDeviceProperty_VirtualMainVolume，
    // Written as a literal to sidestep the Main/Master rename across SDKs.
    private let virtualMainVolume: AudioObjectPropertySelector = 0x766d7663
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private let defaultDevice = kAudioHardwarePropertyDefaultOutputDevice
    private let defaultInput = kAudioHardwarePropertyDefaultInputDevice

    private var device = AudioDeviceID(kAudioObjectUnknown)
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init() {
        var addr = address(defaultDevice, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectAddPropertyListenerBlock(system, &addr, DispatchQueue.main) { [weak self] _, _ in
            self?.bindDefaultDevice()
        }
        bindDefaultDevice()
    }

    func refresh() {
        let new = read()
        guard new != state else { return }
        state = new
        onChange?()
    }

    // MARK: - Reading CoreAudio properties

    private func address(_ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput,
                         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Returns nil if the property is absent or the read fails. T is only ever
    /// AudioDeviceID / Float32 / UInt32 here, but the compiler can't prove a generic
    /// T is trivial and warns that `&value` "may contain an object reference",
    /// hence the explicit raw buffer.
    private func read<T>(_ selector: AudioObjectPropertySelector,
                         from object: AudioObjectID,
                         scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput,
                         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> T? {
        var addr = address(selector, scope: scope, element: element)
        guard AudioObjectHasProperty(object, &addr) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buffer) == noErr else { return nil }
        return buffer.load(as: T.self)
    }

    // MARK: - Device binding

    private func bindDefaultDevice() {
        let next: AudioDeviceID = read(defaultDevice, from: system,
                                       scope: kAudioObjectPropertyScopeGlobal)
            ?? AudioDeviceID(kAudioObjectUnknown)
        if next != device {
            detachDeviceListeners()
            device = next
            attachDeviceListeners()
        }
        refresh()
    }

    private func attachDeviceListeners() {
        guard device != kAudioObjectUnknown else { return }
        for selector in [virtualMainVolume, kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            var addr = address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
            if AudioObjectAddPropertyListenerBlock(device, &addr, DispatchQueue.main, block) == noErr {
                deviceListeners.append((addr, block))
            }
        }
    }

    private func detachDeviceListeners() {
        guard device != kAudioObjectUnknown else { return }
        for (var addr, block) in deviceListeners {
            AudioObjectRemovePropertyListenerBlock(device, &addr, DispatchQueue.main, block)
        }
        deviceListeners.removeAll()
    }

    // MARK: - Enumerating and switching devices

    private func name(of id: AudioDeviceID) -> String {
        var addr = address(kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
        // This property hands back a +1 retained CFString, so it must go through Unmanaged
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              let value else { return "" }
        return value.takeRetainedValue() as String
    }

    private func hasStreams(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private func devices(scope: AudioObjectPropertyScope) -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { hasStreams($0, scope) }
                  .map { AudioDevice(id: $0, name: name(of: $0)) }
                  .filter { !$0.name.isEmpty }
    }

    var outputDevices: [AudioDevice] { devices(scope: kAudioDevicePropertyScopeOutput) }
    var inputDevices: [AudioDevice] { devices(scope: kAudioDevicePropertyScopeInput) }
    var currentOutput: AudioDeviceID { device }
    var currentInput: AudioDeviceID {
        read(defaultInput, from: system, scope: kAudioObjectPropertyScopeGlobal)
            ?? AudioDeviceID(kAudioObjectUnknown)
    }

    func selectOutput(_ id: AudioDeviceID) { setDefault(defaultDevice, id) }
    func selectInput(_ id: AudioDeviceID) { setDefault(defaultInput, id) }

    private func setDefault(_ selector: AudioObjectPropertySelector, _ id: AudioDeviceID) {
        var addr = address(selector, scope: kAudioObjectPropertyScopeGlobal)
        var value = id
        AudioObjectSetPropertyData(system, &addr, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &value)
        refresh()
    }

    // MARK: - Reading

    private func read() -> VolumeState {
        var s = VolumeState()
        guard device != kAudioObjectUnknown else { return s }

        if let v = volume(virtualMainVolume) ?? averageChannelVolume() {
            s.available = true
            s.level = v
        }
        s.muted = muteFlag() ?? (s.available && s.level <= 0.0001)

        s.outputName = name(of: device)
        let input = currentInput
        if input != kAudioObjectUnknown { s.inputName = name(of: input) }
        return s
    }

    private func volume(_ selector: AudioObjectPropertySelector,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Float? {
        (read(selector, from: device, element: element) as Float32?).map { min(max($0, 0), 1) }
    }

    /// Some devices — most USB and aggregate ones — only expose per-channel volume.
    private func averageChannelVolume() -> Float? {
        let values = [1, 2].compactMap {
            volume(kAudioDevicePropertyVolumeScalar, element: AudioObjectPropertyElement($0))
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float(values.count)
    }

    private func muteFlag() -> Bool? {
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1] {
            if let v: UInt32 = read(kAudioDevicePropertyMute, from: device, element: element) {
                return v != 0
            }
        }
        return nil
    }
}

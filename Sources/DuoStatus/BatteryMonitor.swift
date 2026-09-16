import Foundation
import IOKit.ps

struct BatteryState: Equatable {
    var present = false
    var level: Double = 1.0          // 0...1
    var charging = false             // actively charging
    var pluggedIn = false            // power adapter attached
    var fullyCharged = false
    var lowPowerMode = false
    var minutesRemaining = -1        // -1 = still estimating / unknown

    var cycleCount = 0
    var healthPercent: Int?          // the system's "Maximum Capacity", via system_profiler
    var powerWatts = 0.0             // positive = charging, negative = discharging
    var adapterWatts = 0
    var adapterVolts = 0.0
    var adapterAmps = 0.0
}

/// Reads the internal battery through IOKit Power Sources and calls back when the
/// system posts a power event.
final class BatteryMonitor {
    private(set) var state = BatteryState()
    var onChange: (() -> Void)?

    private var source: CFRunLoopSource?

    init() {
        refresh()

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ raw in
            guard let raw else { return }
            Unmanaged<BatteryMonitor>.fromOpaque(raw).takeUnretainedValue().refresh()
        }, ctx)?.takeRetainedValue() {
            source = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }

        fetchHealth()
        // Health moves over months; once a day is plenty
        Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            self?.fetchHealth()
        }

        // Low Power Mode isn't covered by Power Sources notifications, so watch it separately.
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    /// There is no ready-made health percentage in IORegistry — a full scan turns up
    /// no key matching what the system reports, and computing it from
    /// NominalChargeCapacity/DesignCapacity lands one point off.
    /// system_profiler takes ~0.1s, so just take its authoritative answer.
    private func fetchHealth() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            task.arguments = ["SPPowerDataType"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            guard (try? task.run()) != nil,
                  let data = try? pipe.fileHandleForReading.readToEnd(),
                  let text = String(data: data, encoding: .utf8) else { return }
            task.waitUntilExit()

            let value = text.split(separator: "\n")
                .first { $0.contains("Maximum Capacity") }
                .flatMap { $0.split(separator: ":").last }
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " %")) }
                .flatMap { Int($0) }
            guard let value else { return }
            DispatchQueue.main.async {
                guard let self, self.health != value else { return }
                self.health = value
                self.refresh()
            }
        }
    }

    private var health: Int?

    func refresh() {
        var new = Self.read()
        new.healthPercent = health
        guard new != state else { return }
        state = new
        onChange?()
    }

    /// Cycle count plus instantaneous current and voltage from AppleSmartBattery;
    /// IOPS exposes none of these.
    private static func readSmartBattery(into s: inout BatteryState) {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                              IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return }
        s.cycleCount = d["CycleCount"] as? Int ?? 0
        let mA = Double(d["Amperage"] as? Int ?? 0)
        let mV = Double(d["Voltage"] as? Int ?? 0)
        s.powerWatts = mA * mV / 1_000_000
    }

    private static func readAdapter(into s: inout BatteryState) {
        guard let a = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue()
                as? [String: Any] else { return }
        s.adapterWatts = a["Watts"] as? Int ?? 0
        s.adapterVolts = Double(a["AdapterVoltage"] as? Int ?? 0) / 1000
        s.adapterAmps = Double(a["Current"] as? Int ?? 0) / 1000
    }

    private static func read() -> BatteryState {
        var s = BatteryState()
        s.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return s }

        if let kind = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String? {
            s.pluggedIn = (kind == kIOPSACPowerValue)
        }

        for item in list {
            guard let d = IOPSGetPowerSourceDescription(blob, item)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            guard (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }

            s.present = true
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            s.level = max > 0 ? Swift.min(1.0, Double(cur) / Double(max)) : 0
            s.charging = d[kIOPSIsChargingKey] as? Bool ?? false
            s.fullyCharged = d[kIOPSIsChargedKey] as? Bool ?? false
            if let st = d[kIOPSPowerSourceStateKey] as? String { s.pluggedIn = (st == kIOPSACPowerValue) }
            s.minutesRemaining = s.charging
                ? (d[kIOPSTimeToFullChargeKey] as? Int ?? -1)
                : (d[kIOPSTimeToEmptyKey] as? Int ?? -1)
            break
        }
        readSmartBattery(into: &s)
        if s.pluggedIn { readAdapter(into: &s) }
        return s
    }
}

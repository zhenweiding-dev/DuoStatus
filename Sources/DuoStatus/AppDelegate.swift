import AppKit
import CoreAudio
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let battery = BatteryMonitor()
    private let volume = VolumeMonitor()
    private let network = NetworkMonitor()
    private let throughput = ThroughputMeter()

    private var pollTimer: Timer?
    private var appearanceObservation: NSKeyValueObservation?
    private var renderedModel: StatusIcon.Model?
    private var ping: PingResult?
    private var pinging = false

    /// One closure per row, each writes its own title with the latest value.
    private var liveRows: [() -> Void] = []
    private var liveTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        battery.onChange = { [weak self] in self?.render() }
        volume.onChange = { [weak self] in self?.render() }
        network.onChange = { [weak self] in self?.render() }

        // The icon isn't a template image, so it has to follow the menu bar
        // appearance itself.
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            self?.render(force: true)
        }

        // Safety net: a few devices never post change notifications, and Wi-Fi
        // signal strength has no push event at all. Throughput rides along, so
        // what it reports is a 5-second average.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshAll()
        }

        render(force: true)
    }

    private func refreshAll() {
        battery.refresh()
        volume.refresh()
        network.refresh()
        throughput.sample(interface: network.state.interfaceName)
    }

    /// Measured only while the menu is open. Skipped if one is still in flight
    /// so requests can't pile up.
    private func measurePing() {
        guard !pinging, let gateway = Pinger.defaultGateway() else { return }
        pinging = true
        Pinger.measure(host: gateway, count: 3) { [weak self] result in
            self?.pinging = false
            self?.ping = result
        }
    }

    // MARK: - Live refresh while the menu is open

    /// An open menu puts the run loop in event-tracking mode, where timers
    /// scheduled in the default mode never fire — hence the explicit `.common`.
    /// Stops on close: nobody is looking the rest of the time.
    func menuWillOpen(_ menu: NSMenu) {
        tickLive()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tickLive() }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        liveTimer?.invalidate()
        liveTimer = nil
        liveRows.removeAll()
    }

    private func tickLive() {
        refreshAll()
        measurePing()
        for update in liveRows { update() }
    }

    // MARK: - Status icon

    private func render(force: Bool = false) {
        guard let button = statusItem.button else { return }
        let model = StatusIcon.Model(battery: battery.state,
                                     volume: volume.state,
                                     network: network.state)
        guard force || model != renderedModel else { return }
        renderedModel = model

        let image = StatusIcon.image(for: model, appearance: button.effectiveAppearance)
        button.image = image
        statusItem.length = image.size.width

        // Row prefixes are carried by the menu's section headers; a tooltip has
        // no such context, so it needs them spelled out.
        let s = L.strings
        button.toolTip = [(s.battery, batteryLine()), (s.network, networkLine()), (s.sound, soundLine())]
            .filter { !$0.1.isEmpty }
            .map { "\($0.0) \($0.1)" }
            .joined(separator: "\n")
    }

    // MARK: - Menu

    /// Pin the width to the longest text each row can produce, otherwise the
    /// whole panel resizes every time a number gains or loses a digit.
    private static func menuWidth(for strings: Strings) -> CGFloat {
        let font = NSFont.menuFont(ofSize: 0)
        let widest = strings.widthSamples
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 250
        return ceil(widest) + 64          // icon + insets + submenu arrow
    }

    /// Width left for a device name once the prefix and insets are accounted for.
    private static func deviceNameWidth(for strings: Strings) -> CGFloat {
        let font = NSFont.menuFont(ofSize: 0)
        let prefix = ("\(strings.output) " as NSString).size(withAttributes: [.font: font]).width
        return menuWidth(for: strings) - 64 - prefix
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshAll()
        menu.removeAllItems()
        liveRows.removeAll()

        let s = L.strings
        menu.minimumWidth = Self.menuWidth(for: s)

        menu.addItem(.sectionHeader(title: s.battery))
        live(menu, symbol: { [weak self] in self?.batterySymbol() ?? "battery.50percent" }) {
            [weak self] in self?.batteryLine() ?? ""
        }
        live(menu, symbol: { [weak self] in
            self?.battery.state.pluggedIn == true ? "powerplug.fill" : "timer"
        }) { [weak self] in self?.powerLine() ?? "" }

        menu.addItem(.sectionHeader(title: s.network))
        live(menu, symbol: { [weak self] in self?.networkSymbol() ?? "wifi" }) {
            [weak self] in self?.networkLine() ?? ""
        }
        live(menu, symbol: { "arrow.up.arrow.down" }) { [weak self] in self?.linkLine() ?? "" }

        menu.addItem(.sectionHeader(title: s.sound))
        live(menu, symbol: { [weak self] in
            self?.volume.state.muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill"
        }) { [weak self] in self?.soundLine() ?? "" }
        menu.addItem(deviceItem(title: s.output, symbol: "hifispeaker.fill", scope: .output))
        menu.addItem(deviceItem(title: s.input, symbol: "mic.fill", scope: .input))

        menu.addItem(.separator())
        menu.addItem(languageItem())

        let login = NSMenuItem(title: s.openAtLogin, action: #selector(toggleLoginItem), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self
        menu.addItem(login)

        let quit = NSMenuItem(title: s.quit,
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    /// Adds a read-only row with an SF Symbol and registers how to refresh it.
    private func live(_ menu: NSMenu, symbol: @escaping () -> String,
                      _ text: @escaping () -> String) {
        let item = NSMenuItem(title: text(), action: nil, keyEquivalent: "")
        item.isEnabled = false
        Self.apply(symbol: symbol(), to: item)
        menu.addItem(item)
        liveRows.append { [weak item] in
            guard let item else { return }
            item.title = text()
            Self.apply(symbol: symbol(), to: item)
        }
    }

    /// From macOS 27 on, AppKit hides menu item images unless told otherwise.
    private static func apply(symbol: String, to item: NSMenuItem) {
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
    }

    private func batterySymbol() -> String {
        let s = battery.state
        if s.charging { return "battery.100percent.bolt" }
        switch s.level {
        case ..<0.15: return "battery.0percent"
        case ..<0.40: return "battery.25percent"
        case ..<0.65: return "battery.50percent"
        case ..<0.90: return "battery.75percent"
        default:      return "battery.100percent"
        }
    }

    private func networkSymbol() -> String {
        let s = network.state
        switch s.kind {
        case .wired, .cellular, .other: return s.online ? "globe" : "globe.badge.chevron.backward"
        case .wifi:    return s.online ? "wifi" : "wifi.exclamationmark"
        case .offline: return "wifi.slash"
        }
    }

    private func languageItem() -> NSMenuItem {
        let submenu = NSMenu()
        for language in AppLanguage.allCases {
            let entry = NSMenuItem(title: language.menuTitle,
                                   action: #selector(selectLanguage(_:)), keyEquivalent: "")
            entry.state = L.language == language ? .on : .off
            entry.representedObject = language.rawValue
            entry.target = self
            submenu.addItem(entry)
        }
        let item = NSMenuItem(title: L.strings.language, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private enum DeviceScope { case output, input }

    private func deviceItem(title: String, symbol: String, scope: DeviceScope) -> NSMenuItem {
        let item = NSMenuItem()
        let submenu = NSMenu()
        item.submenu = submenu
        Self.apply(symbol: symbol, to: item)

        let refresh: () -> Void = { [weak self, weak item, weak submenu] in
            guard let self, let item, let submenu else { return }
            let state = self.volume.state
            let name = scope == .output ? state.outputName : state.inputName
            let current = scope == .output ? self.volume.currentOutput : self.volume.currentInput

            let shown = Self.fit(name.isEmpty ? "—" : name,
                                 within: Self.deviceNameWidth(for: L.strings))
            // Same grey as the other status rows. `isEnabled = false` would look
            // right but makes the submenu unreachable, hence the attributed title.
            item.attributedTitle = NSAttributedString(string: "\(title) \(shown)", attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])

            let devices = scope == .output ? self.volume.outputDevices : self.volume.inputDevices
            if submenu.items.count != devices.count {
                submenu.removeAllItems()
                for device in devices {
                    let entry = NSMenuItem(
                        title: device.name,
                        action: scope == .output ? #selector(self.selectOutput(_:))
                                                 : #selector(self.selectInput(_:)),
                        keyEquivalent: "")
                    entry.representedObject = device.id
                    entry.target = self
                    submenu.addItem(entry)
                }
            }
            for (entry, device) in zip(submenu.items, devices) {
                entry.state = device.id == current ? .on : .off
            }
        }
        refresh()
        liveRows.append(refresh)
        return item
    }

    /// Truncates from the tail with an ellipsis. Device names vary wildly in
    /// length and a long one would widen the whole panel.
    private static func fit(_ text: String, within maxWidth: CGFloat) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0)]
        guard (text as NSString).size(withAttributes: attrs).width > maxWidth else { return text }
        var cut = text
        while !cut.isEmpty,
              ((cut + "…") as NSString).size(withAttributes: attrs).width > maxWidth {
            cut.removeLast()
        }
        return cut + "…"
    }

    // MARK: - Row text

    private func batteryLine() -> String {
        let b = battery.state, s = L.strings
        guard b.present else { return "" }
        var parts = ["\(Int(round(b.level * 100)))%"]
        if let health = b.healthPercent { parts.append(s.health(health)) }
        if b.cycleCount > 0 { parts.append(s.cycles(b.cycleCount)) }
        if b.lowPowerMode { parts.append(s.lowPowerMode) }
        return parts.joined(separator: " · ")
    }

    private func powerLine() -> String {
        let b = battery.state, s = L.strings
        guard b.present else { return "" }
        if b.pluggedIn {
            var parts: [String] = []
            if b.adapterWatts > 0 { parts.append("\(b.adapterWatts)W") }
            if b.adapterVolts > 0 {
                parts.append(String(format: "%.0fV %.2fA", b.adapterVolts, b.adapterAmps))
            }
            if b.charging, b.powerWatts > 0.1 { parts.append(s.charging(b.powerWatts)) }
            return parts.isEmpty ? s.powerConnected : parts.joined(separator: " · ")
        }
        guard b.minutesRemaining > 0 else { return s.onBatteryEstimating }
        return s.onBattery(b.minutesRemaining / 60, b.minutesRemaining % 60)
    }

    private func networkLine() -> String {
        let n = network.state, s = L.strings
        let state = n.online ? s.connected : s.noInternet
        switch n.kind {
        case .offline:  return n.wifiPowerOn ? s.notConnected : s.wifiOff
        case .wired:    return "\(s.ethernet) · \(state)"
        case .cellular: return s.cellular
        case .other:    return state
        case .wifi:     return "Wi-Fi · \(state)"
        }
    }

    /// Rates and latency on one line. The two directions share a unit and the
    /// latency/loss labels are dropped — this is the widest row, and spelling
    /// them out costs 55pt. The ⇅ symbol already says it is about traffic.
    private func linkLine() -> String {
        let r = throughput.rate, s = L.strings
        let useMB = max(r.down, r.up) >= 1_048_576
        let scale = useMB ? 1_048_576.0 : 1024.0
        var line = "↓\(Self.compact(r.down / scale)) ↑\(Self.compact(r.up / scale)) "
            + (useMB ? "MB/s" : "KB/s")
        guard let p = ping else { return line + s.measuring }
        line += p.lossPercent == 100
            ? s.noResponse
            : " · \(Self.compact(p.milliseconds))ms · \(p.lossPercent)%"
        return line
    }

    /// Drop the decimal past three digits — this row sets the panel width, and
    /// "1250.0" wastes 20pt over "1250".
    private static func compact(_ value: Double) -> String {
        String(format: value >= 100 ? "%.0f" : "%.1f", value)
    }

    private func soundLine() -> String {
        let v = volume.state, s = L.strings
        guard v.available else { return s.volumeUnavailable }
        return v.muted ? s.muted : "\(Int(round(v.level * 100)))%"
    }

    // MARK: - Actions

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = AppLanguage(rawValue: raw) else { return }
        L.language = language
        render(force: true)          // refreshes the tooltip; the menu rebuilds on open
    }

    @objc private func selectOutput(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? AudioDeviceID { volume.selectOutput(id) }
    }

    @objc private func selectInput(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? AudioDeviceID { volume.selectInput(id) }
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L.strings.loginItemFailed
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

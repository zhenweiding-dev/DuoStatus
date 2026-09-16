import CoreWLAN
import Network

enum NetworkKind: Equatable { case wifi, wired, cellular, other, offline }

struct NetworkState: Equatable {
    var kind: NetworkKind = .offline
    var online = false
    var bars = 3                 // 0...3; treated as full when signal can't be read
    var wifiPowerOn = true
    var interfaceName = ""       // active interface, sampled for throughput
}

/// NWPathMonitor answers "what are we on, and does it work"; CoreWLAN supplies the
/// Wi-Fi signal bars.
///
/// RSSI only, never SSID — the name needs Location permission and the bars don't,
/// and asking for that authorisation to fill one menu row isn't worth it.
final class NetworkMonitor {
    private(set) var state = NetworkState()
    var onChange: (() -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "io.github.zhenweiding-dev.duostatus.network")
    private var path: NWPath?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.path = path
                self?.refresh()
            }
        }
        monitor.start(queue: queue)
        refresh()
    }

    func refresh() {
        let new = read()
        guard new != state else { return }
        state = new
        onChange?()
    }

    private func read() -> NetworkState {
        var s = NetworkState()

        guard let path else { return s }
        s.online = (path.status == .satisfied)
        s.interfaceName = path.availableInterfaces.first?.name ?? ""

        if path.usesInterfaceType(.wifi) {
            s.kind = .wifi
        } else if path.usesInterfaceType(.wiredEthernet) {
            s.kind = .wired
        } else if path.usesInterfaceType(.cellular) {
            s.kind = .cellular
        } else if s.online {
            s.kind = .other
        } else {
            s.kind = .offline
        }

        // Read the radio when on Wi-Fi, and also when offline on a machine that has
        // a Wi-Fi interface — that's what separates "Wi-Fi is off" from "connected
        // but no internet".
        if let iface = CWWiFiClient.shared().interface(), s.kind == .wifi || !s.online {
            s.wifiPowerOn = iface.powerOn()
            if !s.wifiPowerOn { s.kind = .offline }

            // rssiValue() returns 0 when it can't be read; treat that as full bars.
            let raw = iface.rssiValue()
            s.bars = raw == 0 ? 3 : Self.bars(forRSSI: raw)
        }

        if !s.online { s.bars = 0 }
        return s
    }

    private static func bars(forRSSI rssi: Int) -> Int {
        if rssi >= -60 { return 3 }
        if rssi >= -70 { return 2 }
        if rssi >= -80 { return 1 }
        return 0
    }
}

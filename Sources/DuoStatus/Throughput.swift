import Foundation

/// Differences in the interface's byte counters. The kernel maintains them and
/// reading one is a single getifaddrs call, so this rides the existing 5-second
/// poll instead of running its own timer — what it reports is a 5-second average.
struct Throughput: Equatable {
    var down = 0.0      // bytes per second
    var up = 0.0
}

final class ThroughputMeter {
    private(set) var rate = Throughput()
    private var last: (rx: UInt64, tx: UInt64, at: Date)?

    func sample(interface: String) {
        guard let now = Self.counters(for: interface) else { last = nil; return }
        let at = Date()
        defer { last = (now.rx, now.tx, at) }
        guard let prev = last else { return }
        let dt = at.timeIntervalSince(prev.at)
        guard dt > 0.1, now.rx >= prev.rx, now.tx >= prev.tx else { return }
        rate = Throughput(down: Double(now.rx - prev.rx) / dt,
                          up: Double(now.tx - prev.tx) / dt)
    }

    private static func counters(for name: String) -> (rx: UInt64, tx: UInt64)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return nil }
        defer { freeifaddrs(head) }
        var p: UnsafeMutablePointer<ifaddrs>? = head
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard String(cString: cur.pointee.ifa_name) == name,
                  cur.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let raw = cur.pointee.ifa_data else { continue }
            let d = raw.assumingMemoryBound(to: if_data.self).pointee
            return (UInt64(d.ifi_ibytes), UInt64(d.ifi_obytes))
        }
        return nil
    }

}

import Foundation

struct PingResult: Equatable {
    var milliseconds = 0.0
    var lossPercent = 0
}

/// Gateway latency and packet loss. macOS permits unprivileged
/// SOCK_DGRAM + IPPROTO_ICMP, so there's no `ping` subprocess to fork and no root
/// needed. Measured asynchronously while the menu is open — never on a background
/// timer.
enum Pinger {
    static func measure(host: String, count: Int = 4,
                        completion: @escaping (PingResult?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = run(host: host, count: count)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func run(host: String, count: Int) -> PingResult? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr(host)
        guard addr.sin_addr.s_addr != INADDR_NONE else { return nil }

        var samples: [Double] = []
        var lost = 0
        for seq in 0..<count {
            var packet = [UInt8](repeating: 0, count: 16)
            packet[0] = 8                                   // echo request
            packet[6] = UInt8(seq >> 8); packet[7] = UInt8(seq & 0xff)
            let sum = checksum(packet)
            packet[2] = UInt8(sum >> 8); packet[3] = UInt8(sum & 0xff)

            let start = Date()
            let sent = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, packet, packet.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard sent >= 0 else { lost += 1; continue }
            var buffer = [UInt8](repeating: 0, count: 128)
            if recvfrom(fd, &buffer, buffer.count, 0, nil, nil) > 0 {
                samples.append(Date().timeIntervalSince(start) * 1000)
            } else {
                lost += 1
            }
            if seq < count - 1 { usleep(100_000) }
        }
        guard !samples.isEmpty else { return PingResult(milliseconds: 0, lossPercent: 100) }
        return PingResult(milliseconds: samples.reduce(0, +) / Double(samples.count),
                          lossPercent: lost * 100 / count)
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0, i = 0
        while i + 1 < bytes.count { sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1]); i += 2 }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return UInt16(~sum & 0xffff)
    }

    /// The default gateway, read from the routing table via sysctl rather than by
    /// forking `route`.
    static func defaultGateway() -> String? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY]
        var size = 0
        guard sysctl(&mib, 6, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 6, &buf, &size, nil, 0) == 0 else { return nil }

        var offset = 0
        while offset + MemoryLayout<rt_msghdr>.size <= size {
            let hdr = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self) }
            guard hdr.rtm_msglen > 0 else { break }
            defer { offset += Int(hdr.rtm_msglen) }
            // Only the default route, i.e. destination 0.0.0.0
            guard hdr.rtm_flags & RTF_GATEWAY != 0, hdr.rtm_addrs & RTA_DST != 0,
                  hdr.rtm_addrs & RTA_GATEWAY != 0 else { continue }
            var p = offset + MemoryLayout<rt_msghdr>.size
            var dstIsDefault = false
            for slot in 0..<2 {                       // RTA_DST, RTA_GATEWAY
                guard p + 2 <= size else { break }
                let len = Int(buf[p])
                let family = buf[p + 1]
                if slot == 0 {
                    dstIsDefault = (family == UInt8(AF_INET) && len >= 8
                        && buf[p + 4] == 0 && buf[p + 5] == 0 && buf[p + 6] == 0 && buf[p + 7] == 0)
                    if !dstIsDefault { break }
                } else if dstIsDefault, family == UInt8(AF_INET), len >= 8 {
                    return "\(buf[p + 4]).\(buf[p + 5]).\(buf[p + 6]).\(buf[p + 7])"
                }
                p += len == 0 ? 4 : (len + 3) & ~3
            }
        }
        return nil
    }
}

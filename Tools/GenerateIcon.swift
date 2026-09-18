import AppKit

// The app icon is the badge itself, drawn by the same code the menu bar uses, so the
// two can't drift apart. StatusIcon.image goes through a drawingHandler, which means
// it re-renders crisply at any size.
//
// Near-black plate with a faint grid, in the manner Apple gives its own system
// utilities, and the battery ring in the badge's own green — the one element that
// still reads when the icon is scaled to 16px.

private func badge() -> NSImage {
    var battery = BatteryState()
    battery.present = true
    battery.level = 1
    battery.charging = true          // green ring
    battery.pluggedIn = true
    var network = NetworkState()
    network.kind = .wifi
    network.bars = 3
    network.online = true
    network.wifiPowerOn = true
    return StatusIcon.image(
        for: .init(battery: battery,
                   volume: VolumeState(available: true, level: 1, muted: false),
                   network: network),
        appearance: NSAppearance(named: .darkAqua)!)
}

private func render(_ px: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Apple's macOS grid: on a 1024 canvas the rounded square is 824 wide, r = 185.4.
    let scale = px / 1024
    let side = 824 * scale
    let inset = (px - side) / 2
    let plate = NSBezierPath(
        roundedRect: NSRect(x: inset, y: inset, width: side, height: side),
        xRadius: 185.4 * scale, yRadius: 185.4 * scale)

    NSGraphicsContext.current!.cgContext.saveGState()
    plate.addClip()
    NSGradient(starting: NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.08, alpha: 1),
               ending: NSColor(calibratedRed: 0.01, green: 0.01, blue: 0.02, alpha: 1))!
        .draw(in: NSRect(x: inset, y: inset, width: side, height: side), angle: -90)

    // Faint grid. Only resolves above ~200px, but it gives the large sizes some texture.
    NSColor(calibratedRed: 0.35, green: 0.95, blue: 0.55, alpha: 0.07).setStroke()
    let grid = NSBezierPath()
    grid.lineWidth = 1.5 * scale
    let step = side / 9
    for i in 1..<9 {
        let offset = step * CGFloat(i)
        grid.move(to: NSPoint(x: inset + offset, y: inset))
        grid.line(to: NSPoint(x: inset + offset, y: inset + side))
        grid.move(to: NSPoint(x: inset, y: inset + offset))
        grid.line(to: NSPoint(x: inset + side, y: inset + offset))
    }
    grid.stroke()
    NSGraphicsContext.current!.cgContext.restoreGState()

    // Specular sheen across the top: what makes Apple's plates look lit rather than flat
    NSGraphicsContext.current!.cgContext.saveGState()
    plate.addClip()
    NSGradient(colors: [NSColor(white: 1, alpha: 0.16), NSColor(white: 1, alpha: 0)])!
        .draw(in: NSRect(x: inset, y: inset + side / 2, width: side, height: side / 2), angle: -90)
    NSGraphicsContext.current!.cgContext.restoreGState()

    NSColor(white: 1, alpha: 0.12).setStroke()      // edge, so it reads on light backgrounds
    plate.lineWidth = 2 * scale
    plate.stroke()

    let art = side * 0.76
    NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
        badge().draw(in: NSRect(x: (px - art) / 2, y: (px - art) / 2, width: art, height: art),
                     from: .zero, operation: .sourceOver, fraction: 1)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

@main
enum GenerateIcon {
    static func main() throws {
        let out = CommandLine.arguments[1]
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        for (name, px) in [("icon_16x16", 16.0), ("icon_16x16@2x", 32), ("icon_32x32", 32),
                           ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
                           ("icon_256x256", 256), ("icon_256x256@2x", 512),
                           ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
            try render(CGFloat(px)).write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
        }
    }
}

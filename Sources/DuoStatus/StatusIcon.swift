import AppKit

/// The round three-in-one menu bar badge. The composition comes from the
/// "ring + Wi-Fi + signal dots" cluster in the iPhone Duo status bar (iOS 27).
///
/// One ring is cut into two blocks:
///   · top, a 206.4° continuous arc — battery, filling clockwise from the left end
///   · bottom, five dots            — volume, centred on straight down
///   · centre                       — network (Wi-Fi arcs + wedge, or a globe)
///
/// The dots are cellular signal in the original; a Mac has no cellular, so they
/// show system volume instead.
enum StatusIcon {

    /// Every size derives from R. The proportions were measured off the reference
    /// art, then re-tuned for menu bar scale (heavier strokes, Wi-Fi filling the
    /// ring) — this is not a uniform scale-down.
    enum M {
        static let canvas: CGFloat = 22

        /// The ink is exactly a circle of radius R, so R = canvas/2 and the centre
        /// sits in the middle: the battery arc crosses 0°/90°/180°, reaching ±R on
        /// the left, right and top, and the middle one of the five dots lands on
        /// 270°, reaching -R at the bottom.
        /// Make volumeCount even, or stop the arc crossing the horizontal, and this
        /// no longer holds.
        static let R = canvas / 2
        static let center = NSPoint(x: R, y: R)

        static let ringStroke = 0.170 * R
        static let ringRadius = 0.915 * R
        static let dotRadius = ringStroke / 2        // dot diameter == ring stroke
        static let dim: CGFloat = 0.28               // opacity of anything not lit

        static let wifiStroke = 0.140 * R
        static let wifiRadii = [0.375 * R, 0.655 * R]
        static let wifiWedge = 0.170 * R
        static let wifiOrigin = NSPoint(x: center.x, y: center.y - 0.345 * R)
        static let wifiArc = (from: CGFloat(46.4), to: CGFloat(133.6))

        static let globeRadius = 0.34 * R
        static let innerCenter = NSPoint(x: center.x, y: center.y - 0.05 * R)  // optical centre of the inner glyph

        // MARK: Angles
        //
        // Spacing comes in two tiers. Within a group (dot to dot) it is the Wi-Fi
        // stroke width — measured off the reference, the gap between the two Wi-Fi
        // arcs is exactly that. Between groups (battery block to volume block) it is
        // 3.12 times wider, so you read two functional blocks first and their
        // subdivisions second; one shared value would flatten that hierarchy.
        //
        // 3.12 is solved backwards: for five dots (77.6°) to sit against a 206.4°
        // battery arc, each gap takes (360 - 206.4 - 77.6) / 2 = 38.0°.

        static let volumeCount = 5

        /// Converts an edge-to-edge gap into an angle on the circle. Each round cap
        /// eats stroke/2 outwards and that has to be added back — otherwise every
        /// degree of gap you ask for is a degree you lose.
        static func angle(edgeGap: CGFloat) -> CGFloat {
            (edgeGap + ringStroke) / ringRadius * 180 / .pi
        }
        static let dotGap = angle(edgeGap: wifiStroke)             // 19.4°
        static let groupGap = angle(edgeGap: wifiStroke * 3.12)    // 38.0°

        // Dot centre spacing is exactly dotGap: centre distance = gap + diameter,
        // the same expression as above.
        static let volumeSpan = CGFloat(volumeCount - 1) * dotGap  // 77.6°
        static let dotAngles = (0..<volumeCount).map {
            270 - volumeSpan / 2 + CGFloat($0) * dotGap
        }

        // The battery arc takes whatever is left
        static let arcSpan = 360 - volumeSpan - 2 * groupGap       // 206.4°
        static let ringStart = 90 + arcSpan / 2                    // left end, fills clockwise
        static let ringEnd = 90 - arcSpan / 2
    }

    /// Equatable lets AppDelegate ask "is this what I drew last time?" directly.
    struct Model: Equatable {
        var battery: BatteryState?
        var volume: VolumeState?
        var network: NetworkState?
    }

    static func image(for model: Model, appearance: NSAppearance) -> NSImage {
        let image = NSImage(size: NSSize(width: M.canvas, height: M.canvas), flipped: false) { _ in
            appearance.performAsCurrentDrawingAppearance {
                let base = NSColor.labelColor
                if let b = model.battery, b.present { drawRing(b, base) }
                if let v = model.volume { drawVolumeDots(v, base) }
                if let n = model.network { drawNetwork(n, base) }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Brushes

    private static func arc(_ center: NSPoint, _ radius: CGFloat,
                            _ from: CGFloat, _ to: CGFloat,
                            width: CGFloat, color: NSColor, clockwise: Bool = false) {
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius,
                       startAngle: from, endAngle: to, clockwise: clockwise)
        path.lineWidth = width
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    private static func dot(at center: NSPoint, radius: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                    width: radius * 2, height: radius * 2)).fill()
    }

    // MARK: - Top block: battery

    private static func drawRing(_ state: BatteryState, _ base: NSColor) {
        arc(M.center, M.ringRadius, M.ringStart, M.ringEnd,
            width: M.ringStroke, color: base.withAlphaComponent(M.dim), clockwise: true)

        let level = max(0, min(1, state.level))
        guard level > 0 else { return }
        arc(M.center, M.ringRadius, M.ringStart, M.ringStart - M.arcSpan * level,
            width: M.ringStroke, color: color(for: state, base: base), clockwise: true)
    }

    private static func color(for state: BatteryState, base: NSColor) -> NSColor {
        if state.charging || (state.pluggedIn && state.fullyCharged) { return .systemGreen }
        if state.lowPowerMode { return .systemYellow }
        if state.level <= 0.20 { return .systemRed }
        return base
    }

    // MARK: - Bottom block: volume

    private static func drawVolumeDots(_ state: VolumeState, _ base: NSColor) {
        let lit = (!state.available || state.muted)
            ? 0 : min(M.volumeCount, Int(ceil(Double(state.level) * Double(M.volumeCount))))
        // Muted is one shade fainter than merely sitting at zero
        let off = base.withAlphaComponent(state.muted ? M.dim * 0.6 : M.dim)

        for (i, deg) in M.dotAngles.enumerated() {
            let t = deg * .pi / 180
            let p = NSPoint(x: M.center.x + M.ringRadius * cos(t),
                            y: M.center.y + M.ringRadius * sin(t))
            dot(at: p, radius: M.dotRadius, color: i < lit ? base : off)
        }
    }

    // MARK: - Centre: network

    private static func drawNetwork(_ state: NetworkState, _ base: NSColor) {
        switch state.kind {
        case .wired, .cellular, .other:
            drawGlobe(online: state.online, base: base)
        case .wifi, .offline:
            drawWiFi(bars: state.bars, online: state.online,
                     slashed: !state.online || !state.wifiPowerOn, base: base)
        }
    }

    private static func drawWiFi(bars: Int, online: Bool, slashed: Bool, base: NSColor) {
        // The innermost shape is a filled sector: swing an arc out from the fan's
        // origin and close back to it, then stroke a thin rounded edge to blunt the tip.
        let wedgeColor = online ? base : base.withAlphaComponent(M.dim)
        let wedge = NSBezierPath()
        wedge.move(to: M.wifiOrigin)
        wedge.appendArc(withCenter: M.wifiOrigin, radius: M.wifiWedge,
                        startAngle: M.wifiArc.from, endAngle: M.wifiArc.to)
        wedge.close()
        wedge.lineWidth = M.wifiStroke * 0.37
        wedge.lineJoinStyle = .round
        wedgeColor.setFill(); wedgeColor.setStroke()
        wedge.fill(); wedge.stroke()

        // Lit from the inside out: one bar is the wedge alone, two adds the middle
        // arc, three adds the outer one
        for (i, r) in M.wifiRadii.enumerated() {
            arc(M.wifiOrigin, r, M.wifiArc.from, M.wifiArc.to, width: M.wifiStroke,
                color: bars >= (i + 2) ? base : base.withAlphaComponent(M.dim))
        }

        if slashed { drawSlash(halfWidth: 0.40 * M.R, aspect: 0.80, base: base) }
    }

    private static func drawGlobe(online: Bool, base: NSColor) {
        let c = M.innerCenter, r = M.globeRadius, w = M.wifiStroke * 0.82
        base.setStroke()

        let outline = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        outline.lineWidth = w
        outline.stroke()

        let equator = NSBezierPath()
        equator.move(to: NSPoint(x: c.x - r, y: c.y))
        equator.line(to: NSPoint(x: c.x + r, y: c.y))
        equator.lineWidth = w * 0.85
        equator.stroke()

        let meridian = NSBezierPath(ovalIn: NSRect(x: c.x - r * 0.48, y: c.y - r,
                                                   width: r * 0.96, height: r * 2))
        meridian.lineWidth = w * 0.85
        meridian.stroke()

        if !online { drawSlash(halfWidth: r * 1.35, aspect: 1.0, base: base) }
    }

    /// The slash across the centre glyph. A wider transparent stroke punches a gap
    /// first, then the solid line goes on top, so the two don't smear together.
    private static func drawSlash(halfWidth: CGFloat, aspect: CGFloat, base: NSColor) {
        let c = M.innerCenter
        let path = NSBezierPath()
        path.move(to: NSPoint(x: c.x - halfWidth, y: c.y + halfWidth * aspect))
        path.line(to: NSPoint(x: c.x + halfWidth, y: c.y - halfWidth * aspect))
        path.lineCapStyle = .round

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        NSColor.black.setStroke()
        path.lineWidth = M.wifiStroke + 1.4
        path.stroke()
        ctx.restoreGState()

        base.setStroke()
        path.lineWidth = M.wifiStroke
        path.stroke()
    }
}

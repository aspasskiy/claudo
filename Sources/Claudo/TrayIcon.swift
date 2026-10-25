import AppKit

/// The menu bar glyph for today's progress, a ball of yarn that untangles as tasks get done, plus a coral dot
/// while Claude's new suggestions are unseen. While Today is still an earlier day's plan it goes quiet: a faint
/// ball, no progress.
enum TrayIcon {
    enum State: Equatable {
        case noPlan
        case planning
        case progress(done: Int, total: Int)
    }

    static let coral = NSColor.adaptive(light: 0xD97757, dark: 0xE8896A)

    static func image(_ state: State, unseen: Bool, stale: Bool = false) -> NSImage {
        yarn(state, unseen: unseen, stale: stale && state != .noPlan && state != .planning)
    }

    /// Faded strokes for a stale plan: present, but asking for nothing.
    private static let staleAlpha: CGFloat = 0.5

    // MARK: Yarn

    /// A ball of yarn trailing a loose end, as tangled as today is open: two strands wound side by side,
    /// then one crossing strand per open task, up to `crossings.count`. It untangles as tasks get done and
    /// lies wound and neat when the day is. A spark in place of the strands while Claude plans; a stale
    /// plan leaves the neat ball, faded.
    private static func yarn(_ state: State, unseen: Bool, stale: Bool = false) -> NSImage {
        composed(size: NSSize(width: 19, height: 16)) { rect in
            let ink = stale ? NSColor.labelColor.withAlphaComponent(staleAlpha) : NSColor.labelColor
            let center = NSPoint(x: 7.6, y: 8.9)
            let r: CGFloat = 6.2
            let line: CGFloat = stale ? 1.25 : 1.45
            ink.setStroke()

            let disc = NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            let ball = NSBezierPath(ovalIn: disc)
            ball.lineWidth = line
            ball.stroke()
            // The loose end: off the ball's bottom, a lazy wave out to the right.
            let start = -70 * CGFloat.pi / 180
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: center.x + cos(start) * r, y: center.y + sin(start) * r))
            tail.curve(to: NSPoint(x: 18, y: 2.2), controlPoint1: NSPoint(x: 10.4, y: 0.4),
                       controlPoint2: NSPoint(x: 14.6, y: 4.2))
            tail.lineWidth = line
            tail.lineCapStyle = .round
            tail.stroke()

            var open = 0
            if !stale, case .progress(let done, let total) = state { open = max(total - done, 0) }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: disc).addClip()
            if state == .planning {
                // Claude's spark where the strands were.
                let spark = NSBezierPath()
                for i in 0..<8 {
                    let a = CGFloat(i) * .pi / 4
                    let reach: CGFloat = i % 2 == 0 ? 3.7 : 2.5
                    spark.move(to: center)
                    spark.line(to: NSPoint(x: center.x + cos(a) * reach, y: center.y + sin(a) * reach))
                }
                spark.lineWidth = 1.25
                spark.lineCapStyle = .round
                spark.stroke()
            } else {
                for strand in wound + crossings.prefix(open) {
                    // An arc of a big circle centered outside the ball crosses it as a curved strand,
                    // `offset` radii from the ball's center.
                    let angle = strand.angle * .pi / 180
                    let distance = r * 2.2
                    let c = NSPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
                    let arc = NSBezierPath()
                    arc.appendArc(withCenter: c, radius: distance - r * strand.offset, startAngle: 0, endAngle: 360)
                    arc.lineWidth = stale ? 0.95 : 1.1
                    arc.stroke()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            if unseen { drawDot(in: rect) }
        }
    }

    /// (direction of the arc's far center in degrees, how far past the ball's center the strand runs, in radii).
    /// The wound pair always shows; each open task adds the next crossing, at an angle the others don't share.
    private static let wound: [(angle: CGFloat, offset: CGFloat)] = [(-40, 0.5), (-40, -0.1)]
    private static let crossings: [(angle: CGFloat, offset: CGFloat)] = [
        (55, 0.2), (150, 0.4), (95, -0.45), (5, -0.6), (-115, 0.15),
    ]

    // MARK: Drawing helpers

    /// Drawn lazily inside the status button, so labelColor follows the menu bar's appearance.
    private static func composed(size: NSSize, _ draw: @escaping (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(rect)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Coral dot at the top right, cut out of whatever is under it.
    private static func drawDot(in rect: NSRect) {
        let r: CGFloat = 2.6
        let c = NSPoint(x: rect.maxX - r - 0.5, y: rect.maxY - r - 0.5)
        if let ctx = NSGraphicsContext.current {
            ctx.saveGraphicsState()
            ctx.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: c.x - r - 1.2, y: c.y - r - 1.2, width: (r + 1.2) * 2, height: (r + 1.2) * 2)).fill()
            ctx.restoreGraphicsState()
        }
        coral.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
    }
}

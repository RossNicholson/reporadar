import AppKit

/// The menu bar icon: a radar scope with its sweep, and a blip when a repo
/// needs you. A template image, so it follows the menu bar's colours.
enum MenuBarIcon {
    static func image(blip: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            NSColor.black.set()

            let scope = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            scope.lineWidth = 1.5
            scope.stroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 5.5, dy: 5.5))
            ring.lineWidth = 1
            NSColor.black.withAlphaComponent(0.55).set()
            ring.stroke()

            // The sweep: a faded wedge behind the line
            let radius = rect.width / 2 - 2.25
            let wedge = NSBezierPath()
            wedge.move(to: center)
            wedge.appendArc(withCenter: center, radius: radius, startAngle: 45, endAngle: 100)
            wedge.close()
            NSColor.black.withAlphaComponent(0.35).set()
            wedge.fill()

            NSColor.black.set()
            let line = NSBezierPath()
            line.move(to: center)
            line.line(to: NSPoint(x: center.x + radius * cos(.pi / 4), y: center.y + radius * sin(.pi / 4)))
            line.lineWidth = 1.5
            line.lineCapStyle = .round
            line.stroke()
            NSBezierPath(ovalIn: NSRect(x: center.x - 1.25, y: center.y - 1.25, width: 2.5, height: 2.5)).fill()

            if blip {
                NSBezierPath(ovalIn: NSRect(x: center.x - 6.3, y: center.y - 3.2, width: 2.7, height: 2.7)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Repo Radar"
        return image
    }
}

import SwiftUI

/// RepoRadar's mascot: a little radar dish with a face, on a stand, its
/// antenna sending out waves. Drawn in the rubber-hose style of BrewDock's mug
/// and ClawdBar's cat: thick ink outlines, pastel fills, big eyes. `tilt`
/// turns the dish, which the panel animates while it scans.
struct Mascot: View {
    enum Mood { case happy, alert }

    var mood: Mood = .happy
    var size: CGFloat = 72
    var disc: Color? = AppColors.butter
    /// Degrees the dish turns from its resting angle
    var tilt: Double = 0
    var waves = true

    private static let ink = Color(hex: 0x232428)
    private static let dish = Color(hex: 0xFBF6E9)
    private static let bowl = Color(hex: 0xC2E6D6)        // mint
    private static let bowlShade = Color(hex: 0xA7D8C2)
    private static let stand = Color(hex: 0xC3C7F6)       // periwinkle
    private static let knob = Color(hex: 0xEE9C86)        // coral
    private static let blush = Color(hex: 0xF6C3B4)
    private static let sclera = Color(hex: 0xFFFFFF)

    var body: some View {
        Canvas { context, canvasSize in
            // Draw in a 100×100 space
            let scale = min(canvasSize.width, canvasSize.height) / 100
            context.scaleBy(x: scale, y: scale)
            draw(in: &context)
        }
        .frame(width: size, height: size)
        .background { if let disc { Circle().fill(disc) } }
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext) {
        let ink = Self.ink
        let outline = StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)

        // The stand: a post on a rounded foot
        var post = Path()
        post.move(to: CGPoint(x: 50, y: 68))
        post.addLine(to: CGPoint(x: 50, y: 81))
        context.stroke(post, with: .color(ink), style: StrokeStyle(lineWidth: 5.5, lineCap: .round))
        context.stroke(post, with: .color(Self.stand), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        let foot = Path(roundedRect: CGRect(x: 36, y: 79, width: 28, height: 10), cornerRadius: 5)
        context.fill(foot, with: .color(Self.stand))
        context.stroke(foot, with: .color(ink), style: outline)

        // The dish turns about its middle
        var dish = context
        dish.translateBy(x: 50, y: 50)
        dish.rotate(by: .degrees(-14 + tilt))

        // Antenna behind the dish: a strut up to a knob, sending waves
        var strut = Path()
        strut.move(to: CGPoint(x: 0, y: -20))
        strut.addQuadCurve(to: CGPoint(x: 4, y: -31), control: CGPoint(x: -1, y: -27))
        dish.stroke(strut, with: .color(ink), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
        let knob = Path(ellipseIn: CGRect(x: 0.5, y: -38.5, width: 8, height: 8))
        dish.fill(knob, with: .color(Self.knob))
        dish.stroke(knob, with: .color(ink), lineWidth: 2.2)
        if waves {
            for radius in [8.0, 12.5] {
                var wave = Path()
                wave.addArc(center: CGPoint(x: 4.5, y: -34.5), radius: radius,
                            startAngle: .degrees(-45), endAngle: .degrees(15), clockwise: false)
                dish.stroke(wave, with: .color(ink.opacity(radius > 10 ? 0.45 : 0.8)),
                            style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            }
        }

        // The dish: a rim around a hollow bowl
        let rim = Path(ellipseIn: CGRect(x: -26, y: -22, width: 52, height: 44))
        dish.fill(rim, with: .color(Self.dish))
        dish.stroke(rim, with: .color(ink), style: outline)
        let bowl = Path(ellipseIn: CGRect(x: -20.5, y: -16.5, width: 41, height: 33))
        dish.fill(bowl, with: .color(Self.bowl))
        dish.drawLayer { layer in
            layer.clip(to: bowl)
            layer.fill(Path(ellipseIn: CGRect(x: -30, y: -22, width: 26, height: 48)), with: .color(Self.bowlShade))
        }
        dish.stroke(bowl, with: .color(ink), lineWidth: 1.8)

        // Face
        for x in [-10.0, 2.5] {
            let eye = Path(ellipseIn: CGRect(x: x, y: -10, width: 8, height: 10.5))
            dish.fill(eye, with: .color(Self.sclera))
            dish.stroke(eye, with: .color(ink), lineWidth: 2)
            switch mood {
            case .happy:
                dish.fill(Path(ellipseIn: CGRect(x: x + 2.3, y: -6.8, width: 4.8, height: 6.4)), with: .color(ink))
                dish.fill(Path(ellipseIn: CGRect(x: x + 3.2, y: -6.1, width: 1.8, height: 1.8)), with: .color(.white))
            case .alert:
                // Small pupils: it's spotted something
                dish.fill(Path(ellipseIn: CGRect(x: x + 2.7, y: -5.8, width: 3, height: 3.6)), with: .color(ink))
            }
        }
        for x in [-15.5, 8.5] {
            dish.fill(Path(ellipseIn: CGRect(x: x, y: 2.5, width: 7, height: 3.6)), with: .color(Self.blush))
        }
        var mouth = Path()
        switch mood {
        case .happy:
            mouth.move(to: CGPoint(x: -5.5, y: 5))
            mouth.addQuadCurve(to: CGPoint(x: 4.5, y: 5), control: CGPoint(x: -0.5, y: 11))
            dish.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        case .alert:
            mouth = Path(ellipseIn: CGRect(x: -3, y: 4.5, width: 5, height: 5.5))
            dish.fill(mouth, with: .color(ink))
        }
    }
}

/// The dish swaying while RepoRadar scans or fetches
struct ScanningMascot: View {
    var busy: Bool
    var mood: Mascot.Mood = .happy
    var size: CGFloat = PanelMetrics.mascot

    var body: some View {
        if busy {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                Mascot(mood: mood, size: size, tilt: sin(t * 3) * 16)
            }
        } else {
            Mascot(mood: mood, size: size)
        }
    }
}

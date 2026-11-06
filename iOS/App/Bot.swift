import SwiftUI

/// What an agent is doing, as its face shows it.
enum BotMood: Equatable {
    /// In a list, far away: faded and still.
    case far
    /// Present but not paying attention: still.
    case idle
    /// You've arrived; it's in 3D audio and its eyes turn to you.
    case arrived
    /// You're looking at it; the ring is filling.
    case focused
    /// Just woke: happy eyes, one small hop.
    case awake
    case speaking
    /// Eyes widen and tilt to listen.
    case listening
    /// Eyes drift up and across.
    case thinking
    /// Asleep after the conversation ended.
    case ended
    /// Offline or out of compute: grey and worried.
    case error

    /// Moods with continuous motion. Everything else is drawn once.
    var isAnimated: Bool {
        switch self {
        case .far, .idle, .ended, .error: false
        default: true
        }
    }
}

/// An agent's face: a flat body in one of five shapes with a diagonal gradient and two
/// ink eyes. Still in lists; the eyes only move when the agent is paying attention.
struct BotView: View {
    let color: BotColor
    let shape: BotShape
    var mood: BotMood = .idle
    var size: CGFloat = 44
    /// -1…1: where the eyes look (toward you), used when arrived or focused.
    var look: Double = 0
    var seed: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hops = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !mood.isAnimated || reduceMotion)) { context in
            face(time: mood.isAnimated && !reduceMotion ? context.date.timeIntervalSinceReferenceDate : nil)
        }
        .frame(width: size, height: size)
        .opacity(mood == .far ? 0.45 : 1)
        .keyframeAnimator(initialValue: 0.0, trigger: hops) { content, lift in
            content.offset(y: -lift)
        } keyframes: { _ in
            SpringKeyframe(size * 0.16, duration: 0.16, spring: .snappy)
            SpringKeyframe(0, duration: 0.42, spring: .bouncy)
        }
        .onChange(of: mood) { _, new in if new == .awake, !reduceMotion { hops += 1 } }
        .onAppear { if mood == .awake, !reduceMotion { hops += 1 } }
        .animation(Motion.snappy, value: mood)
        .accessibilityHidden(true)
    }

    // MARK: - Drawing

    private func face(time t: Double?) -> some View {
        let s = size
        let base = mood == .error ? Color(white: 0.68) : color.color
        var bob: CGFloat = 0
        if let t, mood == .focused || mood == .listening { bob = CGFloat(sin(t * .pi)) * s * 0.025 }

        return ZStack {
            BotBody(shape: shape)
                .fill(LinearGradient(colors: [base.mix(with: .white, by: 0.3), base.mix(with: .black, by: 0.05)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            eyes(time: t)
                .offset(y: eyeLine * s - s / 2)
            if showsMouth {
                mouth(time: t).offset(y: (eyeLine + 0.22) * s - s / 2)
            }
        }
        .rotationEffect(.degrees(mood == .listening ? 7 : 0))
        .offset(y: -bob)
    }

    /// Vertical position of the eyes as a fraction of size (the drop's body sits lower).
    private var eyeLine: CGFloat {
        switch shape {
        case .drop: 0.6
        case .capsule: 0.45
        default: 0.47
        }
    }

    private var showsMouth: Bool { mood == .speaking || mood == .error }

    @ViewBuilder private func eyes(time t: Double?) -> some View {
        let s = size
        let spacing = s * 0.15
        HStack(spacing: spacing * 2 - s * 0.14) {
            eye(left: true, time: t)
            eye(left: false, time: t)
        }
        .offset(gaze(time: t))
    }

    @ViewBuilder private func eye(left: Bool, time t: Double?) -> some View {
        let s = size
        let ink = Color(white: 0.11)
        switch mood {
        case .awake:
            // Happy eyes: little upturned arcs.
            HappyEye().stroke(ink, style: StrokeStyle(lineWidth: s * 0.06, lineCap: .round))
                .frame(width: s * 0.15, height: s * 0.1)
        case .ended:
            // Asleep: closed, gently curved down.
            HappyEye().rotation(.degrees(180)).stroke(ink.opacity(0.8), style: StrokeStyle(lineWidth: s * 0.05, lineCap: .round))
                .frame(width: s * 0.14, height: s * 0.07)
        default:
            let scale = eyeScale
            let tilt: Double = mood == .error ? (left ? 14 : -14) : -8
            Ellipse().fill(ink)
                .frame(width: s * 0.14 * scale, height: s * 0.23 * scale)
                .scaleEffect(y: blink(time: t))
                .rotationEffect(.degrees(tilt))
        }
    }

    private var eyeScale: CGFloat {
        switch mood {
        case .listening: 1.16
        case .focused: 1.06
        case .error: 0.82
        default: 1
        }
    }

    @ViewBuilder private func mouth(time t: Double?) -> some View {
        let s = size
        let ink = Color(white: 0.11)
        if mood == .error {
            Capsule().fill(ink).frame(width: s * 0.12, height: s * 0.035)
        } else {
            let open = CGFloat(mouthOpen(time: t))
            Capsule().fill(ink).frame(width: s * 0.13, height: s * 0.06 * open)
        }
    }

    private func mouthOpen(time t: Double?) -> Double {
        guard let t else { return 1 }
        let chatter = abs(sin(t * 9.7)) * (0.65 + 0.35 * sin(t * 5.3))
        return 0.55 + 0.9 * chatter
    }

    /// Eye offset: looking at you, or drifting while thinking.
    private func gaze(time t: Double?) -> CGSize {
        let s = size
        if mood == .thinking, let t {
            let wave = CGFloat(sin(t * 2 * .pi / 2.6))
            return CGSize(width: wave * s * 0.05, height: -s * 0.04 - abs(wave) * s * 0.015)
        }
        let follows = mood == .arrived || mood == .focused || mood == .idle || mood == .listening
        return CGSize(width: follows ? CGFloat(look) * s * 0.06 : 0, height: 0)
    }

    /// Eyes close for a moment every few seconds, each agent on its own rhythm.
    private func blink(time t: Double?) -> CGFloat {
        guard let t else { return 1 }
        let period = 4.2 + seed * 1.6
        let phase = (t + seed * 10).truncatingRemainder(dividingBy: period) / period
        let d = abs(phase - 0.94)
        return d < 0.025 ? 0.1 + 0.9 * (d / 0.025) : 1
    }
}

extension BotView {
    init(agent: Agent, mood: BotMood = .idle, size: CGFloat = 44, look: Double = 0) {
        self.init(color: agent.botColor, shape: agent.botShape, mood: mood, size: size, look: look, seed: agent.seed)
    }
}

/// An upturned arc (∩), for happy eyes; flipped, a closed sleepy eye.
private struct HappyEye: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.midX, y: r.minY - r.height * 0.9))
        return p
    }
}

/// The five body shapes, each filling the same visual weight in a square.
struct BotBody: Shape {
    let shape: BotShape

    func path(in r: CGRect) -> Path {
        let w = r.width
        switch shape {
        case .circle:
            return Circle().path(in: r)
        case .squircle:
            return RoundedRectangle(cornerRadius: w * 0.32, style: .continuous).path(in: r.insetBy(dx: w * 0.04, dy: w * 0.04))
        case .capsule:
            return Capsule(style: .continuous).path(in: r.insetBy(dx: w * 0.1, dy: 0))
        case .hexagon:
            let c = CGPoint(x: r.midX, y: r.midY)
            let points = (0..<6).map { i -> CGPoint in
                let a = CGFloat(i * 60 - 90) * .pi / 180
                return CGPoint(x: c.x + cos(a) * w * 0.52, y: c.y + sin(a) * w * 0.52)
            }
            return roundedPolygon(points, radius: w * 0.12)
        case .drop:
            // A round body with a soft point on top.
            let c = CGPoint(x: r.midX, y: r.minY + w * 0.59)
            let radius = w * 0.4
            var p = Path()
            let start: CGFloat = -50, end: CGFloat = 230
            for (i, deg) in stride(from: start, through: end, by: 5).enumerated() {
                let a = deg * .pi / 180
                let pt = CGPoint(x: c.x + cos(a) * radius, y: c.y + sin(a) * radius)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            let right = CGPoint(x: c.x + cos(start * .pi / 180) * radius, y: c.y + sin(start * .pi / 180) * radius)
            p.addQuadCurve(to: right, control: CGPoint(x: r.midX, y: r.minY - w * 0.27))
            p.closeSubpath()
            return p
        }
    }

    private func roundedPolygon(_ pts: [CGPoint], radius: CGFloat) -> Path {
        var p = Path()
        let n = pts.count
        let mid = { (a: CGPoint, b: CGPoint) in CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        p.move(to: mid(pts[n - 1], pts[0]))
        for i in 0..<n {
            p.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % n], radius: radius)
        }
        p.closeSubpath()
        return p
    }
}

/// The stare ring: a light track and an ink arc that fills over three seconds.
struct StareRing: View {
    let progress: Double
    var diameter: CGFloat
    var lineWidth: CGFloat = 5

    var body: some View {
        ZStack {
            Circle().stroke(Color(.systemGray5), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.12), value: progress)
        }
        .frame(width: diameter, height: diameter)
    }
}

#Preview("Cast") {
    VStack(spacing: 20) {
        HStack {
            ForEach(Array(BotColor.allCases.enumerated()), id: \.offset) { i, c in
                BotView(color: c, shape: BotShape.allCases[i % 5], size: 40)
            }
        }
        HStack(spacing: 16) {
            ForEach([BotMood.far, .idle, .arrived, .focused, .awake], id: \.self) { m in
                BotView(color: .cyan, shape: .circle, mood: m, size: 56, look: 0.6)
            }
        }
        HStack(spacing: 16) {
            ForEach([BotMood.speaking, .listening, .thinking, .ended, .error], id: \.self) { m in
                BotView(color: .violet, shape: .squircle, mood: m, size: 56)
            }
        }
    }
    .padding()
}

extension BotMood: Hashable {}

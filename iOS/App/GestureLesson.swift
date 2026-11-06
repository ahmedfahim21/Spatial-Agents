import SwiftUI

/// One AirPods reading, as gestures see it: degrees, + = right / up.
struct MotionSample {
    let t: Double
    let yaw: Double
    let pitch: Double
}

/// Measures recorded head movements, and turns a person's own yes, no and turns into the
/// thresholds the detectors use.
enum GestureLesson {
    struct Swings { var count: Int; var peaks: [Double]; var span: Double }

    static func values(_ s: [MotionSample], pitch: Bool) -> [Double] {
        if pitch { return s.map(\.pitch) }
        guard var prev = s.first?.yaw else { return [] }
        return s.map { prev += normalizeAngle($0.yaw - prev); return prev }
    }

    /// Back-and-forth swings along one axis, each with its peak speed, the way the detector
    /// counts them (but with a threshold that adapts to the movement).
    static func swings(_ s: [MotionSample], pitch: Bool) -> Swings {
        let v = values(s, pitch: pitch)
        guard v.count > 2 else { return Swings(count: 0, peaks: [], span: 0) }
        var speeds: [Double] = [0], sp = 0.0
        for i in 1..<v.count {
            let dt = max(s[i].t - s[i - 1].t, 0.001)
            sp = 0.6 * ((v[i] - v[i - 1]) / dt) + 0.4 * sp
            speeds.append(sp)
        }
        let threshold = max(20, 0.3 * (speeds.map(abs).max() ?? 0))
        var count = 0, peaks: [Double] = [], lastSign = 0, start: Double?, end = 0.0
        for (i, x) in speeds.enumerated() where abs(x) > threshold {
            let sign = x > 0 ? 1 : -1
            if sign != lastSign {
                count += 1
                peaks.append(abs(x))
                lastSign = sign
                if start == nil { start = s[i].t }
            } else {
                peaks[peaks.count - 1] = max(peaks[peaks.count - 1], abs(x))
            }
            end = s[i].t
        }
        return Swings(count: count, peaks: peaks, span: start.map { end - $0 } ?? 0)
    }

    static func range(_ s: [MotionSample], pitch: Bool) -> Double {
        let v = values(s, pitch: pitch)
        return (v.max() ?? 0) - (v.min() ?? 0)
    }

    static func wobble(_ s: [MotionSample], pitch: Bool) -> Double {
        GestureDetector.wobble(s.map(\.t), values(s, pitch: pitch))
    }

    /// A turn: how far (signed, + = right) and how long its middle 80% took.
    static func turn(_ s: [MotionSample]) -> (degrees: Double, seconds: Double) {
        let v = values(s, pitch: false)
        guard let v0 = v.first, let far = v.max(by: { abs($0 - v0) < abs($1 - v0) }) else { return (0, 0) }
        let d = far - v0
        guard abs(d) > 1 else { return (d, 0) }
        let t10 = zip(s, v).first { ($1 - v0) / d >= 0.1 }?.0.t
        let t90 = zip(s, v).first { ($1 - v0) / d >= 0.9 }?.0.t
        return (d, max(0, (t90 ?? 0) - (t10 ?? 0)))
    }

    static func isYes(_ s: [MotionSample]) -> Bool {
        swings(s, pitch: true).count >= 2 && range(s, pitch: true) >= 4
    }

    static func isNo(_ s: [MotionSample]) -> Bool {
        swings(s, pitch: false).count >= 2 && range(s, pitch: false) >= 6
    }

    static func isTurn(_ s: [MotionSample], right: Bool) -> Bool {
        let d = turn(s).degrees
        return abs(d) >= 6 && (d > 0) == right
    }

    private static func median(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        let s = x.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    private static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(max(x, lo), hi) }

    /// Thresholds from what you did: about half of your own movement, kept above how much
    /// your head moves anyway while you talk.
    static func profile(still: [MotionSample], yes: [[MotionSample]], no: [[MotionSample]], turns: [[MotionSample]]) -> GestureProfile {
        var p = MobileState.defaultProfile
        let stillPitch = swings(still, pitch: true).peaks.max() ?? 0
        let stillYaw = swings(still, pitch: false).peaks.max() ?? 0
        let stillPitchRange = range(still, pitch: true), stillYawRange = range(still, pitch: false)

        if !yes.isEmpty {
            let sw = yes.map { swings($0, pitch: true) }
            p.nodSwings = Int(clamp(median(sw.map { Double($0.count) }) - 1, 2, 3).rounded())
            // The weakest of the swings a yes needs: every one of them has to clear the bar.
            let weakest = sw.map { $0.peaks.sorted(by: >).dropFirst(p.nodSwings - 1).first ?? $0.peaks.min() ?? 0 }
            p.nodSpeed = clamp(0.6 * median(weakest), max(20, 1.3 * stillPitch), 90)
            p.nodSize = clamp(0.5 * median(yes.map { range($0, pitch: true) }), max(5, 1.2 * stillPitchRange), 25)
            let ratios = yes.map { wobble($0, pitch: true) / max(wobble($0, pitch: false), 1) }
            p.nodRatio = clamp(0.6 * median(ratios), 0.7, 1.5)
        }
        if !no.isEmpty {
            let sw = no.map { swings($0, pitch: false) }
            p.shakeSwings = Int(clamp(median(sw.map { Double($0.count) }) - 1, 2, 3).rounded())
            let weakest = sw.map { $0.peaks.sorted(by: >).dropFirst(p.shakeSwings - 1).first ?? $0.peaks.min() ?? 0 }
            p.shakeSpeed = clamp(0.6 * median(weakest), max(30, 1.3 * stillYaw), 150)
            p.shakeSize = clamp(0.5 * median(no.map { range($0, pitch: false) }), 8, 30)
        }
        let spans = yes.map { swings($0, pitch: true).span } + no.map { swings($0, pitch: false).span }
        if !spans.isEmpty { p.window = clamp(1.4 * median(spans) + 0.3, 1.0, 2.2) }
        if !turns.isEmpty {
            let t = turns.map(turn)
            p.turnSize = clamp(0.5 * median(t.map { abs($0.degrees) }), max(8, 1.5 * stillYawRange), 35)
            p.turnTime = clamp(1.8 * median(t.map(\.seconds)), 0.4, 1.2)
        }
        return p
    }
}

/// Settings → Teach your gestures: you do each gesture a few times, and Air Agents learns
/// what your yes, no and turns look like.
struct GestureLessonView: View {
    @Environment(MobileState.self) private var state
    @Environment(\.dismiss) private var dismiss

    private enum Kind { case still, yes, no, left, right }
    private struct Step {
        let kind: Kind
        let title: String
        let detail: String
        let symbol: String
        let attempts: Int
        let seconds: Double
    }
    private let steps: [Step] = [
        Step(kind: .still, title: "Just talk", detail: "Say something out loud, the way you'd talk to an agent: “What's on my calendar today?”",
             symbol: "waveform", attempts: 1, seconds: 4),
        Step(kind: .yes, title: "Double nod for yes", detail: "Nod the way you'd say “yes, yes”.",
             symbol: "arrow.up.and.down", attempts: 3, seconds: 2.8),
        Step(kind: .no, title: "Double shake for no", detail: "Shake your head the way you'd say “no, no”.",
             symbol: "arrow.left.and.right", attempts: 3, seconds: 2.8),
        Step(kind: .left, title: "Turn left", detail: "A quick turn toward someone on your left. Then come back.",
             symbol: "arrow.turn.up.left", attempts: 3, seconds: 1.8),
        Step(kind: .right, title: "Turn right", detail: "A quick turn toward someone on your right. Then come back.",
             symbol: "arrow.turn.up.right", attempts: 3, seconds: 1.8),
    ]

    @State private var started = false
    @State private var done = false
    @State private var stepIndex = 0
    @State private var attempt = 0
    @State private var status = ""
    @State private var listening = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                if done { finished } else if started { lesson } else { intro }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Your gestures")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(done ? "Done" : "Cancel") { dismiss() } }
            }
        }
        .tint(.primary)
        .onAppear { state.training = true }
        .onDisappear {
            task?.cancel()
            state.training = false
        }
    }

    private var intro: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "airpods.pro").font(.system(size: 56, weight: .light))
            Text("Teach Air Agents your gestures").font(.title2.bold()).multilineTextAlignment(.center)
            Text("Everyone nods and shakes a little differently. Do each one a few times, the way you naturally would, and Air Agents learns yours. About a minute.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 10) {
                Label("Double nod: yes", systemImage: "arrow.up.and.down")
                Label("Double shake: no", systemImage: "arrow.left.and.right")
                Label("Turn left or right: pick that agent", systemImage: "arrow.left.arrow.right")
            }
            .font(.subheadline)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            Spacer()
            if !state.hasHeadData {
                Text("Put in your AirPods to start.").font(.footnote).foregroundStyle(.orange)
            }
            Button("Start") { start() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!state.hasHeadData)
        }
    }

    private var lesson: some View {
        let step = steps[min(stepIndex, steps.count - 1)]
        return VStack(spacing: 18) {
            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { i in
                    Capsule().fill(i <= stepIndex ? Color.primary : Color(.systemGray4)).frame(height: 4)
                }
            }
            .padding(.top, 4)
            Spacer()
            ZStack {
                Circle().fill(Color(.secondarySystemGroupedBackground)).frame(width: 170, height: 170)
                Circle().stroke(listening ? Color.green : Color.clear, lineWidth: 5).frame(width: 170, height: 170)
                    .scaleEffect(listening ? 1.06 : 1)
                    .animation(listening ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default, value: listening)
                Image(systemName: step.symbol).font(.system(size: 54, weight: .semibold))
            }
            Text(step.title).font(.title2.bold())
            Text(step.detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if step.attempts > 1 {
                Text("\(min(attempt + 1, step.attempts)) of \(step.attempts)")
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(status).font(.headline).foregroundStyle(listening ? .green : .primary)
                .contentTransition(.opacity)
                .animation(Motion.snappy, value: status)
            Spacer()
        }
    }

    private var finished: some View {
        let p = state.gestureProfile
        return VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 52)).foregroundStyle(.green)
            Text("Learnt your gestures").font(.title2.bold())
            VStack(spacing: 0) {
                row("Yes", p.nodSwings >= 3 ? "Double nod" : "Nod")
                RowDivider(leading: 16)
                row("No", p.shakeSwings >= 3 ? "Double shake" : "Shake")
                RowDivider(leading: 16)
                row("Pick left or right", "Turn \(Int(p.turnSize))°")
            }
            .card()
            Text("Try them").font(.headline).padding(.top, 8)
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                Text(state.lastMove.flatMap { Date().timeIntervalSince($0.at) < 2.5 ? $0.name : nil } ?? "…")
                    .font(.system(size: 34, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .card()
            }
            Text("Too hard or too easy to trigger? Adjust Sensitivity in Settings.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
            HStack(spacing: 10) {
                Button("Teach again") { start() }.buttonStyle(SecondaryButtonStyle(fullWidth: false))
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func start() {
        started = true
        done = false
        task?.cancel()
        task = Task { await run() }
    }

    private func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    private func run() async {
        var still: [MotionSample] = []
        var yes: [[MotionSample]] = [], no: [[MotionSample]] = [], turns: [[MotionSample]] = []
        for (i, step) in steps.enumerated() {
            stepIndex = i
            attempt = 0
            var misses = 0
            while attempt < step.attempts {
                status = "Get ready…"
                await pause(1.2)
                guard !Task.isCancelled else { return }
                status = "Now"
                listening = true
                state.haptics.tap(intensity: 0.8, sharpness: 0.6)
                let s = await state.recordMotion(seconds: step.seconds)
                listening = false
                guard !Task.isCancelled else { return }
                if s.count < 10 {
                    status = "No head movement. Are your AirPods in?"
                    await pause(1.8)
                    continue
                }
                let good: Bool
                switch step.kind {
                case .still: good = true
                case .yes: good = GestureLesson.isYes(s)
                case .no: good = GestureLesson.isNo(s)
                case .left: good = GestureLesson.isTurn(s, right: false)
                case .right: good = GestureLesson.isTurn(s, right: true)
                }
                // Three misses in a row: take it as it comes rather than loop forever.
                if good || misses >= 2 {
                    switch step.kind {
                    case .still: still = s
                    case .yes: yes.append(s)
                    case .no: no.append(s)
                    case .left, .right: turns.append(s)
                    }
                    attempt += 1
                    misses = 0
                    status = "Got it"
                    state.haptics.tap(intensity: 0.5, sharpness: 0.3)
                } else {
                    misses += 1
                    status = "Didn't catch that. Once more, a little bigger."
                    state.haptics.failure()
                }
                await pause(step.kind == .left || step.kind == .right ? 1.4 : 0.8)
                if step.kind == .left || step.kind == .right, attempt < step.attempts {
                    status = "Back to the middle"
                    await pause(1.0)
                }
            }
        }
        guard !Task.isCancelled else { return }
        let p = GestureLesson.profile(still: still, yes: yes.filter(GestureLesson.isYes), no: no.filter(GestureLesson.isNo),
                                      turns: turns.filter { abs(GestureLesson.turn($0).degrees) >= 6 })
        print("Agentsphere: learnt gestures \(p)")
        state.gestureProfile = p
        done = true
    }
}

import AVFoundation
import CoreLocation
import CoreMotion
import Speech
import SwiftUI

/// First launch: what the app does in three pages, then the four permissions it needs.
struct OnboardingView: View {
    @Environment(MobileState.self) private var state
    let finish: () -> Void
    @State private var page = 0
    private let pages = 4

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if page < pages - 1 {
                    Button("Skip") { withAnimation(Motion.smooth) { page = pages - 1 } }
                        .foregroundStyle(.primary)
                        .transition(.opacity)
                }
            }
            .frame(height: 44)
            .padding(.horizontal, 20)

            TabView(selection: $page) {
                IntroPage(art: AnyView(LookArt()),
                          title: "Turn, then double nod",
                          text: "Turn your head left or right and that agent lights up. Double nod and it says hello, then just talk. Double shake or say bye to end.")
                    .tag(0)
                IntroPage(art: AnyView(FindArt()),
                          title: "Find agents around you",
                          text: "Agents live in real places. Follow the arrow, feel the pulses, and hear them call as you get closer.")
                    .tag(1)
                IntroPage(art: AnyView(WithMeArt()),
                          title: "Bring yours along",
                          text: "Personal agents travel with you, arranged around your head. Turn to one and it's there.")
                    .tag(2)
                PermissionsPage().tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            VStack(spacing: 18) {
                HStack(spacing: 7) {
                    ForEach(0..<pages, id: \.self) { i in
                        Capsule()
                            .fill(i == page ? Color.primary : Color(.systemGray4))
                            .frame(width: i == page ? 18 : 7, height: 7)
                    }
                }
                .animation(Motion.snappy, value: page)
                if page == pages - 1 {
                    Text("No account needed.").font(.footnote).foregroundStyle(.secondary)
                }
                Button(page == pages - 1 ? "Get started" : "Continue") {
                    if page == pages - 1 { finish() } else { withAnimation(Motion.smooth) { page += 1 } }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .background(Color(.systemBackground))
        .animation(Motion.snappy, value: page)
    }
}

private struct IntroPage: View {
    let art: AnyView
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            art.frame(height: 260)
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.4)
                .multilineTextAlignment(.center)
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

/// The loop: you look (the ring draws round), you nod (a little nod badge), it wakes with a hop.
private struct LookArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { ctx in
            let t = reduceMotion ? 1.5 : ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 5.5)
            let looking = t > 0.8 && t < 4.8
            let nodding = t > 2.0 && t < 2.9
            ZStack {
                FocusRing(active: looking, diameter: 176, lineWidth: 5)
                BotView(color: .cyan, shape: .circle, mood: t < 0.8 ? .idle : t < 2.9 ? .focused : .awake, size: 132)
                NodBadge(nodding: nodding)
                    .offset(x: 70, y: 70)
                    .opacity(nodding ? 1 : 0)
                    .animation(Motion.snappy, value: nodding)
            }
        }
    }
}

/// A small head that dips once: "nod".
private struct NodBadge: View {
    let nodding: Bool
    var body: some View {
        Image(systemName: "person.fill")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Color(.systemBackground))
            .frame(width: 40, height: 40)
            .background(Color.primary, in: Circle())
            .keyframeAnimator(initialValue: 0.0, trigger: nodding) { content, tilt in
                content.rotation3DEffect(.degrees(tilt), axis: (x: 1, y: 0, z: 0))
            } keyframes: { _ in
                SpringKeyframe(28, duration: 0.18, spring: .snappy)
                SpringKeyframe(0, duration: 0.3, spring: .snappy)
            }
    }
}

private struct FindArt: View {
    var body: some View {
        ZStack {
            Circle().stroke(Color(.systemGray5), lineWidth: 1).frame(width: 220, height: 220)
            Circle().stroke(Color(.systemGray5), lineWidth: 1).frame(width: 140, height: 140)
            Image(systemName: "location.north.fill")
                .font(.system(size: 54))
                .rotationEffect(.degrees(28))
            BotView(color: .violet, shape: .squircle, mood: .arrived, size: 56, look: -0.6)
                .offset(x: 70, y: -92)
            BotView(color: .pink, shape: .drop, mood: .far, size: 34)
                .offset(x: -96, y: 40)
            BotView(color: .green, shape: .capsule, mood: .far, size: 30)
                .offset(x: 30, y: 104)
        }
    }
}

private struct WithMeArt: View {
    var body: some View {
        ZStack {
            Circle().stroke(Color(.systemGray4), lineWidth: 0.75).frame(width: 200, height: 200)
            Circle().fill(Color(.secondarySystemGroupedBackground)).frame(width: 44, height: 44)
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                .overlay(Image(systemName: "person.fill").foregroundStyle(.secondary))
            BotView(color: .blue, shape: .hexagon, mood: .focused, size: 54).offset(y: -100)
            BotView(color: .yellow, shape: .squircle, mood: .idle, size: 50, look: 0.6).offset(x: -82, y: -57)
            BotView(color: .green, shape: .drop, mood: .idle, size: 50, look: -0.6).offset(x: 82, y: -57)
        }
    }
}

/// Location, Motion, Microphone, Speech: each asked for in place, with why.
private struct PermissionsPage: View {
    @Environment(MobileState.self) private var state
    @State private var motion = false
    @State private var mic = false
    @State private var speech = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Text("Four permissions, then you're in")
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.4)
                Text("Each one powers part of finding and talking. You can change them in Settings.")
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                row("location.fill", .blue, "Location", "Shows which agents are near and how far.",
                    granted: state.location.isAuthorized) { state.location.start() }
                RowDivider(leading: 60)
                row("airpods", .gray, "Motion", "Reads AirPods head tracking, so you can look at agents.",
                    granted: motion) {
                    state.startHeadTracking()
                    Task {
                        for _ in 0..<40 where !motion {
                            try? await Task.sleep(for: .milliseconds(250))
                            motion = HeadTracker.authorization == "authorized"
                        }
                    }
                }
                RowDivider(leading: 60)
                row("mic.fill", .orange, "Microphone", "Only open while you're talking to an agent.", granted: mic) {
                    Task { mic = await AVAudioApplication.requestRecordPermission() }
                }
                RowDivider(leading: 60)
                row("waveform", .indigo, "Speech recognition", "Turns what you say into text the agent can answer.", granted: speech) {
                    SFSpeechRecognizer.requestAuthorization { status in
                        Task { @MainActor in speech = status == .authorized }
                    }
                }
            }
            .card()
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 20)
        .onAppear {
            // Read current answers only once this page shows.
            motion = HeadTracker.authorization == "authorized"
            mic = AVAudioApplication.shared.recordPermission == .granted
            speech = SFSpeechRecognizer.authorizationStatus() == .authorized
        }
    }

    private func row(_ icon: String, _ tint: Color, _ title: String, _ detail: String,
                     granted: Bool, ask: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if granted {
                Image(systemName: "checkmark").font(.body.weight(.semibold))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                Button("Allow", action: ask)
                    .buttonStyle(SecondaryButtonStyle(fullWidth: false))
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .animation(Motion.lively, value: granted)
    }
}

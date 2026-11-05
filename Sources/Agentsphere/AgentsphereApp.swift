import AppKit
import SwiftUI

@main
struct AgentsphereApp: App {
    @StateObject private var state = AppState()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        WindowGroup("Agentsphere") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 960, minHeight: 620)
        }
        .windowResizability(.contentMinSize)

        Window("Sound Lab", id: "lab") {
            SoundLabView()
                .environmentObject(state)
                .environmentObject(state.lab)
        }
        .windowResizability(.contentMinSize)
    }
}

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            RadarView()
                .padding(24)
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            ControlPanel()
                .frame(width: 440)
        }
    }
}

// MARK: - The room

struct RadarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let r = max(60, size / 2 - 60)

            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                    .frame(width: r * 2, height: r * 2)
                    .position(center)
                Circle()
                    .stroke(Color.secondary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(width: r, height: r)
                    .position(center)

                FocusCone(yaw: state.headYaw, width: state.focusWidth)
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: r * 2, height: r * 2)
                    .position(center)
                    // AirPods report ~25 times a second; glide between updates.
                    .animation(.linear(duration: 0.045), value: state.headYaw)

                Image(systemName: "person.crop.circle")
                    .font(.system(size: 34))
                    .foregroundStyle(.primary)
                    .position(center)

                Text("FRONT")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .position(x: center.x, y: center.y - r - 24)

                ForEach(state.sessions) { s in
                    AgentDot(session: s,
                             focused: s.id == state.focusedId,
                             selected: s.id == state.selectedId)
                        .position(point(center: center, radius: r, azimuth: s.azimuth))
                        .gesture(
                            DragGesture(coordinateSpace: .named("room"))
                                .onChanged { v in
                                    let dx = v.location.x - center.x
                                    let dy = v.location.y - center.y
                                    state.setAzimuth(s.id, Double(atan2(dx, -dy)) * 180 / .pi)
                                }
                        )
                        .onTapGesture { state.selectedId = s.id }
                }

                if state.sessions.isEmpty {
                    Text("Add a Claude Code session, then drag it to where you want it to sit.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(width: 260)
                        .position(x: center.x, y: center.y + 60)
                }
            }
            .coordinateSpace(name: "room")
        }
    }

    private func point(center: CGPoint, radius: CGFloat, azimuth: Double) -> CGPoint {
        let a = azimuth * .pi / 180
        return CGPoint(x: center.x + radius * CGFloat(sin(a)),
                       y: center.y - radius * CGFloat(cos(a)))
    }
}

/// The wedge you're currently facing.
struct FocusCone: Shape {
    var yaw: Double
    var width: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(yaw, width) }
        set { yaw = newValue.first; width = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        p.move(to: c)
        let steps = 24
        for i in 0...steps {
            let deg = yaw - width + 2 * width * Double(i) / Double(steps)
            let a = deg * .pi / 180
            p.addLine(to: CGPoint(x: c.x + r * CGFloat(sin(a)), y: c.y - r * CGFloat(cos(a))))
        }
        p.closeSubpath()
        return p
    }
}

struct AgentDot: View {
    let session: AgentSession
    let focused: Bool
    let selected: Bool

    private var color: Color {
        switch session.status {
        case .idle: return .gray
        case .working: return .orange
        case .asking: return .purple
        case .waiting: return .green
        case .error: return .red
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if focused {
                    Circle().stroke(Color.accentColor, lineWidth: 3).frame(width: 50, height: 50)
                }
                Circle().fill(color).frame(width: 38, height: 38)
                Image(systemName: session.status == .asking ? "hand.raised.fill" : session.status == .working ? "ellipsis" : "terminal")
                    .foregroundStyle(.white)
            }
            Text(session.name).font(.caption.bold()).lineLimit(1)
            Text(session.status.rawValue).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(6)
        .frame(width: 120)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
}

// MARK: - Controls

struct ControlPanel: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Agentsphere").font(.title2.bold())
                Spacer()
                Button("Sound Lab") { openWindow(id: "lab") }
                    .keyboardShortcut("l", modifiers: .option)
                Button("Add Claude session…") { state.addSession() }
            }

            GroupBox("Head") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(state.headStatus).font(.caption).foregroundStyle(.secondary)
                    Text("Facing \(Int(state.headYaw))° → \(state.target?.name ?? "nobody")")
                        .monospacedDigit()
                    HStack {
                        Button("Recenter") { state.recenter() }
                            .keyboardShortcut("r", modifiers: .option)
                        Toggle("Invert direction", isOn: $state.invertHead)
                    }
                    HStack {
                        Text("Pitch \(Int(state.headPitch))°").monospacedDigit()
                        Spacer()
                        Text("Last gesture: \(state.lastGesture)").bold()
                    }
                    HStack {
                        Text("Gesture sensitivity")
                        Slider(value: $state.gestureSensitivity, in: 0.5...2)
                        Text(String(format: "%.1f×", state.gestureSensitivity)).monospacedDigit().frame(width: 44)
                    }
                    HStack {
                        Text("Focus width")
                        Slider(value: $state.focusWidth, in: 10...60)
                        Text("±\(Int(state.focusWidth))°").monospacedDigit().frame(width: 44)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Approvals (\(state.pending.count) waiting)") {
                VStack(alignment: .leading, spacing: 8) {
                    if let r = state.activeRequest {
                        let name = state.sessions.first { $0.id == r.agentId }?.name ?? "?"
                        Text("\(name) \(r.summary)").bold()
                        Text("\(r.toolName) · \(r.hash.prefix(12))").font(.caption.monospaced()).foregroundStyle(.secondary)
                        HStack {
                            Button("Approve (nod)") { state.decideActive(true) }
                                .keyboardShortcut("y", modifiers: .option)
                                .tint(.green)
                            Button("Deny (shake)") { state.decideActive(false) }
                                .keyboardShortcut("n", modifiers: .option)
                                .tint(.red)
                            Text("⌥Y / ⌥N").font(.caption).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Text("Nothing waiting. Nod to approve, shake to deny.").foregroundStyle(.secondary)
                    }
                    Text(state.serverStatus).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Talk to \(state.target?.name ?? "…")") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button(state.isListening ? "Stop & send" : "Talk") { state.toggleListening() }
                            .keyboardShortcut(.space, modifiers: .option)
                            .buttonStyle(.borderedProminent)
                            .tint(state.isListening ? .red : .accentColor)
                        Text("⌥Space").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Repeat last reply") { state.repeatLast() }
                    }
                    if state.isListening {
                        Text(state.transcript.isEmpty ? "Listening…" : state.transcript)
                            .italic()
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        TextField("Or type an instruction", text: $state.typed)
                            .onSubmit { state.sendTyped() }
                        Button("Send") { state.sendTyped() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let i = state.sessions.firstIndex(where: { $0.id == state.selectedId }) {
                GroupBox("Selected agent") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Name", text: $state.sessions[i].name)
                        Text(state.sessions[i].directory.path)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Text("Position \(Int(state.sessions[i].azimuth))° · Session \(state.sessions[i].claudeSessionId?.prefix(8).description ?? "new")")
                            .font(.caption).monospacedDigit()
                        Button("Remove", role: .destructive) { state.removeSession(state.sessions[i].id) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            GroupBox("Claude flags") {
                TextField("Extra arguments", text: $state.extraArgs)
                    .font(.system(.body, design: .monospaced))
            }

            Text("Log").font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(state.log) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.speaker).font(.caption.bold())
                                    .foregroundStyle(entry.fromUser ? Color.accentColor : .primary)
                                Text(entry.text).font(.callout).textSelection(.enabled)
                            }
                            .id(entry.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: state.log.count) { _, _ in
                    if let last = state.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .padding(18)
    }
}

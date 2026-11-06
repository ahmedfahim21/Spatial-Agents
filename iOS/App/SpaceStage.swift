import SwiftUI

/// Your personal space from your own eyes: a window on your left and one on your right; the
/// picked one is ringed. Editing: tap a window to choose who sits in it.
struct SpaceStage: View {
    @Environment(MobileState.self) private var state
    var editing = false

    // The visible span: 75° either side.
    private let azRange = 75.0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                ForEach(Zone.allCases) { zone in
                    window(zone).position(x: xPos(zone.azimuth, w), y: h / 2)
                }
            }
        }
        .animation(Motion.smooth, value: state.zones)
    }

    @ViewBuilder private func window(_ zone: Zone) -> some View {
        let agent = state.agent(in: zone)
        let pane = VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.systemGroupedBackground))
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(agent == nil ? Color(.systemGray3) : Color(.systemGray4),
                                  style: StrokeStyle(lineWidth: 1.5, dash: agent == nil ? [4, 5] : []))
                if let a = agent {
                    let focused = state.focusedId == a.id && !editing
                    FocusRing(active: focused, diameter: 78, lineWidth: 3, showsTrack: false)
                    BotView(agent: a, mood: editing ? .idle : state.mood(for: a), size: 60,
                            look: zone == .left ? 0.6 : -0.6)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 104, height: 112)
            VStack(spacing: 1) {
                Text(zone.windowName.uppercased())
                    .font(.system(size: 9, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(.tertiary)
                Text(agent?.name ?? "Empty")
                    .font(.caption.weight(agent == nil ? .regular : .semibold))
                    .foregroundStyle(agent == nil ? .secondary : .primary)
                    .lineLimit(1)
            }
            .frame(width: 120)
        }
        .contentShape(Rectangle())

        if editing {
            Menu {
                Section(zone.windowName) {
                    ForEach(state.bodyAgents) { a in
                        Button {
                            state.setWindow(zone, to: a.id)
                            state.haptics.tap(intensity: 0.6, sharpness: 0.5)
                            state.preview(a.id)
                        } label: {
                            if agent?.id == a.id {
                                Label(a.name, systemImage: "checkmark")
                            } else if let other = state.zones[a.id] {
                                Text("\(a.name) (\(other.name.lowercased()))")
                            } else {
                                Text(a.name)
                            }
                        }
                    }
                }
                if let a = agent {
                    Button { state.preview(a.id) } label: { Label("Hear it from here", systemImage: "speaker.wave.2") }
                    Button(role: .destructive) { state.setWindow(zone, to: nil) } label: {
                        Label("Leave empty", systemImage: "xmark")
                    }
                }
            } label: { pane }
            .buttonStyle(PressableStyle())
            .disabled(state.bodyAgents.isEmpty)
        } else {
            pane.onTapGesture { if let a = agent { state.wake(a) } }
        }
    }

    private func xPos(_ az: Double, _ w: CGFloat) -> CGFloat {
        let inset: CGFloat = 70
        return inset + CGFloat((az + azRange) / (2 * azRange)) * (w - 2 * inset)
    }
}

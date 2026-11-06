import SwiftUI

/// Your personal space from your own eyes: six zones in front of you (three at eye level,
/// three above) and a dot where you're looking. Editing: drag agents between zones, tap
/// one to hear it from there.
struct SpaceStage: View {
    @Environment(MobileState.self) private var state
    var editing = false

    // The visible window: 100° either side, from 28° below eye level to 58° above.
    private let azRange = 100.0
    private let elLow = -28.0, elHigh = 58.0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                Path { p in
                    let y = yPos(0, h)
                    p.move(to: CGPoint(x: 20, y: y)); p.addLine(to: CGPoint(x: w - 20, y: y))
                }
                .stroke(Color(.systemGray4), style: StrokeStyle(lineWidth: 1, dash: [3, 6]))
                Text("EYE LEVEL").font(.system(size: 9, weight: .semibold)).tracking(1.5)
                    .foregroundStyle(.tertiary)
                    .position(x: 46, y: yPos(0, h) - 9)
                Text("FORWARD").font(.system(size: 9, weight: .semibold)).tracking(1.5)
                    .foregroundStyle(.tertiary)
                    .position(x: xPos(0, w), y: h - 14)

                ForEach(Zone.allCases) { zone in
                    slot(zone).position(x: xPos(zone.azimuth, w), y: yPos(zone.elevation, h))
                }
                gazeDot(w: w, h: h)
            }
        }
        .animation(Motion.smooth, value: state.zones)
    }

    @ViewBuilder private func slot(_ zone: Zone) -> some View {
        let agent = state.agent(in: zone)
        VStack(spacing: 6) {
            ZStack {
                if let a = agent {
                    let focused = state.focusedId == a.id && !editing
                    FocusRing(active: focused, diameter: 74, lineWidth: 3, showsTrack: false)
                    BotView(agent: a, mood: editing ? .idle : state.mood(for: a), size: 58)
                        .draggable(a.id.uuidString) { BotView(agent: a, size: 58) }
                        .onTapGesture { if editing { state.preview(a.id) } else { state.wake(a) } }
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else {
                    Circle()
                        .strokeBorder(Color(.systemGray3), style: StrokeStyle(lineWidth: 1.5, dash: [4, 5]))
                        .frame(width: 58, height: 58)
                        .overlay {
                            if editing { Image(systemName: "plus").foregroundStyle(.tertiary) }
                        }
                }
            }
            .frame(width: 76, height: 76)
            Text(agent?.name ?? zone.name)
                .font(.caption2.weight(agent == nil ? .regular : .semibold))
                .foregroundStyle(agent == nil ? .tertiary : .primary)
                .lineLimit(1)
                .frame(width: 92)
        }
        .dropDestination(for: String.self) { items, _ in
            guard editing, let s = items.first, let id = UUID(uuidString: s) else { return false }
            state.move(id, to: zone)
            state.haptics.tap(intensity: 0.6, sharpness: 0.5)
            return true
        }
    }

    @ViewBuilder private func gazeDot(w: CGFloat, h: CGFloat) -> some View {
        if state.hasHeadData {
            let yaw = state.headYaw, pitch = state.headPitch
            ZStack {
                Circle().fill(Color.primary.opacity(0.08)).frame(width: 34, height: 34)
                Circle().stroke(Color.primary, lineWidth: 2).frame(width: 16, height: 16)
                Circle().fill(Color.primary).frame(width: 4, height: 4)
            }
            .position(x: xPos(max(-azRange, min(azRange, yaw)), w), y: yPos(max(elLow, min(elHigh, pitch)), h))
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private func xPos(_ az: Double, _ w: CGFloat) -> CGFloat {
        let inset: CGFloat = 48
        return inset + CGFloat((az + azRange) / (2 * azRange)) * (w - 2 * inset)
    }

    private func yPos(_ el: Double, _ h: CGFloat) -> CGFloat {
        let inset: CGFloat = 52
        return inset + CGFloat((elHigh - el) / (elHigh - elLow)) * (h - 2 * inset)
    }
}

import SwiftUI

/// Your personal space seen from your own eyes: six zones in front of you (three at eye
/// level, three above) and a dot showing where you're looking. In editing mode, drag
/// agents between zones and tap one to hear it from there.
struct SpaceStage: View {
    @EnvironmentObject var state: MobileState
    @EnvironmentObject var head: HeadMotion
    var editing = false

    // The visible window: 100° either side, from 28° below eye level to 58° above.
    private let azRange = 100.0
    private let elLow = -28.0, elHigh = 58.0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 28)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.06), Color.white.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: 28).stroke(Color.white.opacity(0.08))
                // Eye-level horizon and the "forward" tick.
                Path { p in
                    let y = yPos(0, h)
                    p.move(to: CGPoint(x: 18, y: y)); p.addLine(to: CGPoint(x: w - 18, y: y))
                }
                .stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [4, 6]))
                Text("FORWARD").font(.system(size: 9, weight: .semibold)).tracking(2)
                    .foregroundStyle(.white.opacity(0.3))
                    .position(x: xPos(0, w), y: h - 14)

                ForEach(Zone.allCases) { zone in
                    slot(zone)
                        .position(x: xPos(zone.azimuth, w), y: yPos(zone.elevation, h))
                }
                gazeDot(w: w, h: h)
            }
        }
    }

    // MARK: - Pieces

    @ViewBuilder private func slot(_ zone: Zone) -> some View {
        let agent = state.agent(in: zone)
        VStack(spacing: 6) {
            ZStack {
                if let a = agent {
                    AgentOrb(agent: a, size: 62,
                             stare: state.focusedId == a.id && !editing ? state.stareProgress : 0,
                             active: state.activeId == a.id,
                             focused: state.focusedId == a.id)
                        .draggable(a.id.uuidString) { AgentOrb(agent: a, size: 62) }
                        .onTapGesture { if editing { state.preview(a.id) } else { state.wake(a) } }
                } else {
                    Circle()
                        .strokeBorder(Color.white.opacity(editing ? 0.35 : 0.12), style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                        .frame(width: 62, height: 62)
                        .overlay(Image(systemName: "plus").foregroundStyle(.white.opacity(editing ? 0.4 : 0)))
                }
            }
            Text(agent?.name ?? zone.name)
                .font(.caption2.weight(agent == nil ? .regular : .semibold))
                .foregroundStyle(agent == nil ? .white.opacity(0.35) : .white.opacity(0.85))
                .lineLimit(1)
                .frame(width: 90)
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
            let yaw = head.yaw, pitch = head.pitch - state.pitchZero
            let offscreen = abs(yaw) > azRange
            ZStack {
                Circle().fill(Color.white.opacity(0.18)).frame(width: 30, height: 30).blur(radius: 6)
                Circle().stroke(Color.white.opacity(0.9), lineWidth: 2).frame(width: 16, height: 16)
                Circle().fill(Color.white).frame(width: 4, height: 4)
            }
            .overlay(alignment: yaw < 0 ? .leading : .trailing) {
                if offscreen {
                    Image(systemName: yaw < 0 ? "chevron.left" : "chevron.right")
                        .font(.caption.bold()).offset(x: yaw < 0 ? -14 : 14)
                }
            }
            .position(x: xPos(max(-azRange, min(azRange, yaw)), w), y: yPos(max(elLow, min(elHigh, pitch)), h))
            .animation(.linear(duration: 0.06), value: yaw)
            .allowsHitTesting(false)
        }
    }

    private func xPos(_ az: Double, _ w: CGFloat) -> CGFloat {
        let inset: CGFloat = 46
        return inset + CGFloat((az + azRange) / (2 * azRange)) * (w - 2 * inset)
    }

    private func yPos(_ el: Double, _ h: CGFloat) -> CGFloat {
        let inset: CGFloat = 48
        return inset + CGFloat((elHigh - el) / (elHigh - elLow)) * (h - 2 * inset)
    }
}

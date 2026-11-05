import SwiftUI

struct SoundLabView: View {
    @EnvironmentObject var lab: SoundLab
    @EnvironmentObject var state: AppState
    @State private var viewRadius: Double = 10
    @State private var logScale = false
    @State private var newSound: LabSound = .beep

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                LabMap(viewRadius: viewRadius, logScale: logScale, newSound: newSound)
                    .padding(16)
                HStack {
                    Text("View radius")
                    // Log slider: 1 m ... 500 m.
                    Slider(value: Binding(get: { log10(viewRadius) }, set: { viewRadius = pow(10, $0) }), in: 0...log10(500))
                    Text(Self.meters(viewRadius)).monospacedDigit().frame(width: 60, alignment: .trailing)
                    Toggle("Log distance", isOn: $logScale)
                }
                .padding(.horizontal, 16)
                Text("Drag sounds anywhere · double-click empty space to add a \(newSound.rawValue.lowercased()) there · up is in front of you")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 10)
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            ScrollView { LabPanel(newSound: $newSound).padding(16) }
                .frame(width: 360)
        }
        .frame(minWidth: 900, minHeight: 640)
        .onAppear { lab.activate() }
        .onDisappear { lab.deactivate() }
    }

    static func meters(_ d: Double) -> String {
        d < 10 ? String(format: "%.1f m", d) : String(format: "%.0f m", d)
    }
}

// MARK: - Map

struct LabMap: View {
    @EnvironmentObject var lab: SoundLab
    let viewRadius: Double
    let logScale: Bool
    let newSound: LabSound

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let r = max(80, min(geo.size.width, geo.size.height) / 2 - 20)

            ZStack {
                Color(nsColor: .textBackgroundColor).opacity(0.001) // makes empty space hit-testable

                ForEach(rings(), id: \.self) { d in
                    let pr = px(d, r)
                    Circle()
                        .stroke(Color.secondary.opacity(d == rings().last ? 0.4 : 0.18), lineWidth: 1)
                        .frame(width: pr * 2, height: pr * 2)
                        .position(center)
                    Text(SoundLabView.meters(d))
                        .font(.caption2).foregroundStyle(.secondary)
                        .position(x: center.x + 4 + pr * 0.707 + 14, y: center.y - pr * 0.707)
                }
                Path { p in
                    p.move(to: CGPoint(x: center.x - r, y: center.y)); p.addLine(to: CGPoint(x: center.x + r, y: center.y))
                    p.move(to: CGPoint(x: center.x, y: center.y - r)); p.addLine(to: CGPoint(x: center.x, y: center.y + r))
                }
                .stroke(Color.secondary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                Text("FRONT").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .position(x: center.x, y: center.y - r - 10)

                // You, with a wedge showing where your head points.
                FocusCone(yaw: lab.followHead ? lab.headYaw : 0, width: 20)
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: 90, height: 90)
                    .position(center)
                    .animation(.linear(duration: 0.045), value: lab.headYaw)
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 26))
                    .position(center)

                ForEach(lab.sources) { s in
                    LabDot(source: s, selected: s.id == lab.selectedId)
                        .position(point(s, center: center, r: r))
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .named("lab"))
                                .onChanged { v in
                                    lab.selectedId = s.id
                                    let w = world(v.location, center: center, r: r)
                                    lab.move(s.id, right: w.right, forward: w.forward)
                                }
                        )
                        .onTapGesture { lab.selectedId = s.id }
                }
            }
            .coordinateSpace(name: "lab")
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(count: 2, coordinateSpace: .named("lab")).onEnded { v in
                    let w = world(v.location, center: center, r: r)
                    lab.add(newSound, right: w.right, forward: w.forward)
                }
            )
        }
    }

    /// Distance → screen radius.
    private func px(_ d: Double, _ r: CGFloat) -> CGFloat {
        logScale ? r * CGFloat(log1p(d) / log1p(viewRadius)) : r * CGFloat(d / viewRadius)
    }

    /// Screen radius → distance.
    private func dist(_ p: CGFloat, _ r: CGFloat) -> Double {
        let f = Double(p / r)
        return logScale ? expm1(f * log1p(viewRadius)) : f * viewRadius
    }

    private func point(_ s: LabSource, center: CGPoint, r: CGFloat) -> CGPoint {
        let pr = px(s.groundDistance, r)
        let a = s.azimuth * .pi / 180
        return CGPoint(x: center.x + pr * CGFloat(sin(a)), y: center.y - pr * CGFloat(cos(a)))
    }

    private func world(_ p: CGPoint, center: CGPoint, r: CGFloat) -> (right: Double, forward: Double) {
        let dx = p.x - center.x, dy = center.y - p.y
        let d = dist((dx * dx + dy * dy).squareRoot(), r)
        let a = atan2(Double(dx), Double(dy))
        return (sin(a) * d, cos(a) * d)
    }

    /// Nice ring distances inside the view.
    private func rings() -> [Double] {
        let steps: [Double] = [0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500]
        let inside = steps.filter { $0 < viewRadius * 0.98 && px($0, 100) > 10 }
        return Array(inside.suffix(logScale ? 6 : 4)) + [viewRadius]
    }
}

struct LabDot: View {
    let source: LabSource
    let selected: Bool

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                if selected { Circle().stroke(Color.accentColor, lineWidth: 3).frame(width: 40, height: 40) }
                Circle().fill(source.playing ? Color.orange : Color.gray).frame(width: 30, height: 30)
                Image(systemName: source.sound.symbol).font(.system(size: 13)).foregroundStyle(.white)
            }
            Text(source.name).font(.caption2.bold()).lineLimit(1)
            Text(SoundLabView.meters(source.distance)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }
        .frame(width: 90)
        .contentShape(Rectangle())
    }
}

// MARK: - Panel

struct LabPanel: View {
    @EnvironmentObject var lab: SoundLab
    @EnvironmentObject var state: AppState
    @Binding var newSound: LabSound

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sound Lab").font(.title2.bold())

            GroupBox("Sources") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Picker("", selection: $newSound) {
                            ForEach(LabSound.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        Button("Add in front") { lab.add(newSound, right: 0, forward: 3) }
                            .disabled(lab.sources.count >= SoundLab.maxSources)
                    }
                    HStack {
                        Button("Play all") { lab.setAll(playing: true) }
                        Button("Stop all") { lab.setAll(playing: false) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let s = lab.sources.first(where: { $0.id == lab.selectedId }) {
                SourceEditor(source: s)
            }

            GroupBox("Head") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Follow AirPods head tracking", isOn: $lab.followHead)
                    Toggle("Use macOS head tracking (lower latency)", isOn: $lab.systemHeadTracking)
                        .disabled(!lab.systemHeadTrackingAvailable)
                    Text("Check the direction: put a sound in front and turn right. It should slide to your LEFT ear. If it goes right, tick Invert direction in the main window.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("Facing \(Int(lab.headYaw))°").monospacedDigit()
                        Spacer()
                        Button("Recenter") { state.recenter() }
                    }
                    Text(state.headStatus).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Rendering") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Algorithm", selection: $lab.algorithm) {
                        ForEach(LabAlgorithm.allCases) { Text($0.rawValue).tag($0) }
                    }
                    LabSlider(label: "Master", value: $lab.masterVolume, range: 0...1, format: "%.2f")
                    LabSlider(label: "Back dark", value: $lab.backDarkening, range: 0...24, format: "%.0f dB")
                    Text("Front vs back is the hardest cue: the built-in HRTF only makes sounds behind you ~5 dB duller. Back darkening adds more, and turning your head a little resolves the rest.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            GroupBox("Distance") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Model", selection: $lab.distanceModel) {
                        ForEach(LabDistanceModel.allCases) { Text($0.rawValue).tag($0) }
                    }
                    LabSlider(label: "Reference", value: $lab.referenceDistance, range: 0.1...20, format: "%.1f m")
                    LabSlider(label: "Maximum", value: $lab.maximumDistance, range: 1...1000, format: "%.0f m")
                    LabSlider(label: "Rolloff", value: $lab.rolloff, range: 0...4, format: "%.2f")
                    Text("Full loudness inside the reference distance; quieter beyond it. Linear reaches silence at the maximum.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            GroupBox("Room") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Reverb", isOn: $lab.reverbOn)
                    Picker("Preset", selection: $lab.reverb) {
                        ForEach(LabReverb.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .disabled(!lab.reverbOn)
                    LabSlider(label: "Level", value: $lab.reverbLevel, range: -40...40, format: "%.0f dB")
                        .disabled(!lab.reverbOn)
                    Text("A little reverb helps sounds feel out in the room rather than inside your head.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct SourceEditor: View {
    @EnvironmentObject var lab: SoundLab
    let source: LabSource

    private func bind<T>(_ key: WritableKeyPath<LabSource, T>) -> Binding<T> {
        Binding(get: { lab.sources.first { $0.id == source.id }?[keyPath: key] ?? source[keyPath: key] },
                set: { v in lab.update(source.id) { $0[keyPath: key] = v } })
    }

    var body: some View {
        GroupBox(source.name) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker("", selection: bind(\.sound)) {
                        ForEach(LabSound.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().frame(width: 110)
                    Toggle("Playing", isOn: bind(\.playing))
                    Spacer()
                    Button { lab.retrigger(source.id) } label: { Image(systemName: "arrow.counterclockwise") }
                        .help("Restart from the beginning")
                    Button(role: .destructive) { lab.remove(source.id) } label: { Image(systemName: "trash") }
                }

                let rel = normalizeAngle(source.azimuth - (lab.followHead ? lab.headYaw : 0))
                Text("\(SoundLabView.meters(source.distance)) away · \(Int(source.azimuth))° in room · \(Int(rel))° from your nose")
                    .font(.caption).monospacedDigit()
                Text(String(format: "Distance model: %.1f dB", lab.expectedGainDB(at: source.distance)))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)

                LabSlider(label: "Distance", value: Binding(
                    get: { source.groundDistance },
                    set: { d in
                        let a = source.azimuth * .pi / 180
                        lab.move(source.id, right: sin(a) * d, forward: cos(a) * d)
                    }), range: 0...500, format: "%.1f m", logarithmic: true)
                LabSlider(label: "Direction", value: Binding(
                    get: { source.azimuth },
                    set: { a in
                        let d = max(source.groundDistance, 0.1), r = a * .pi / 180
                        lab.move(source.id, right: sin(r) * d, forward: cos(r) * d)
                    }), range: -180...180, format: "%.0f°")
                LabSlider(label: "Height", value: bind(\.height), range: -10...10, format: "%.1f m")
                LabSlider(label: "Orbit", value: bind(\.orbitSpeed), range: -180...180, format: "%.0f°/s")
                LabSlider(label: "Gain", value: bind(\.gain), range: 0...2, format: "%.2f")
                LabSlider(label: "Reverb mix", value: bind(\.reverbBlend), range: 0...1, format: "%.2f")
                LabSlider(label: "Obstruction", value: bind(\.obstruction), range: -60...0, format: "%.0f dB")
                LabSlider(label: "Occlusion", value: bind(\.occlusion), range: -60...0, format: "%.0f dB")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct LabSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var logarithmic = false

    var body: some View {
        HStack {
            Text(label).frame(width: 82, alignment: .leading)
            if logarithmic {
                // log1p mapping so 0–5 m and 100–500 m both get room on the slider.
                Slider(value: Binding(get: { log1p(value) }, set: { value = expm1($0) }),
                       in: log1p(range.lowerBound)...log1p(range.upperBound))
            } else {
                Slider(value: $value, in: range)
            }
            Text(String(format: format, value)).monospacedDigit().frame(width: 64, alignment: .trailing)
        }
    }
}

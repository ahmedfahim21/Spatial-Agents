import SwiftUI

/// Who sits in your left and right windows at a time of day: Morning might be your planner
/// and notes, Evening your coach and journal. Outside every time set, your usual pair applies.
struct Lineup: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Minutes after midnight. `end` before `start` runs past midnight (e.g. 22:00–06:00).
    var start: Int
    var end: Int
    var left: UUID?
    var right: UUID?

    subscript(zone: Zone) -> UUID? {
        get { zone == .left ? left : right }
        set { if zone == .left { left = newValue } else { right = newValue } }
    }

    func contains(minute m: Int) -> Bool {
        start == end ? true : start < end ? (m >= start && m < end) : (m >= start || m < end)
    }

    var hours: String { "\(Self.clock(start))–\(Self.clock(end))" }

    static func clock(_ minutes: Int) -> String {
        var c = DateComponents()
        c.hour = minutes / 60
        c.minute = minutes % 60
        let date = Calendar.current.date(from: c) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func minute(of date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Starting points for a new one.
    static let presets: [(name: String, start: Int, end: Int)] = [
        ("Morning", 6 * 60, 12 * 60),
        ("Work", 9 * 60, 18 * 60),
        ("Evening", 18 * 60, 23 * 60),
        ("Night", 23 * 60, 6 * 60),
    ]
}

enum LineupStore {
    static func load() -> [Lineup] {
        guard let data = UserDefaults.standard.data(forKey: "lineups") else { return [] }
        return (try? JSONDecoder().decode([Lineup].self, from: data)) ?? []
    }

    static func save(_ lineups: [Lineup]) {
        if let data = try? JSONEncoder().encode(lineups) { UserDefaults.standard.set(data, forKey: "lineups") }
    }
}

// MARK: - Screens

/// Settings and With me: your pairs by time of day.
struct LineupsView: View {
    @Environment(MobileState.self) private var state
    @State private var editing: Lineup?

    var body: some View {
        List {
            Section {
                ForEach(state.lineups) { l in
                    Button { editing = l } label: { row(l) }
                        .buttonStyle(.plain)
                }
                .onDelete { state.deleteLineups(at: $0) }
                Menu {
                    ForEach(Lineup.presets, id: \.name) { p in
                        Button("\(p.name) · \(Lineup.clock(p.start))–\(Lineup.clock(p.end))") {
                            editing = Lineup(name: p.name, start: p.start, end: p.end,
                                             left: state.agent(in: .left)?.id, right: state.agent(in: .right)?.id)
                        }
                    }
                    Button("Custom") {
                        editing = Lineup(name: "", start: 12 * 60, end: 14 * 60,
                                         left: state.agent(in: .left)?.id, right: state.agent(in: .right)?.id)
                    }
                } label: {
                    Label("Add a time of day", systemImage: "plus")
                }
            } footer: {
                Text("At each time your windows switch to that pair, and they say hello from their sides. Outside these times your usual pair stays. If times overlap, the one higher in the list wins.")
            }
        }
        .navigationTitle("Times of day")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { l in
            LineupEditor(lineup: l, isNew: !state.lineups.contains { $0.id == l.id })
        }
    }

    private func row(_ l: Lineup) -> some View {
        let active = state.activeLineupId == l.id
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(l.name).font(.body.weight(.semibold))
                    if active {
                        Text("Now").font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.green.opacity(0.18), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text(l.hours).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            pair(l)
        }
        .contentShape(Rectangle())
    }

    private func pair(_ l: Lineup) -> some View {
        HStack(spacing: -6) {
            ForEach([Zone.left, .right]) { z in
                if let a = state.agent(l[z]) {
                    BotView(agent: a, size: 30)
                } else {
                    Circle().strokeBorder(Color(.systemGray3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(width: 30, height: 30)
                }
            }
        }
        .accessibilityLabel("Left \(state.agent(l.left)?.name ?? "empty"), right \(state.agent(l.right)?.name ?? "empty")")
    }
}

private struct LineupEditor: View {
    @Environment(MobileState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State var lineup: Lineup
    let isNew: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, like Morning", text: $lineup.name)
                    DatePicker("Starts", selection: time(\.start), displayedComponents: .hourAndMinute)
                    DatePicker("Ends", selection: time(\.end), displayedComponents: .hourAndMinute)
                }
                Section {
                    agentPicker("Left window", zone: .left)
                    agentPicker("Right window", zone: .right)
                } footer: {
                    Text("Turn left or right to pick one, then double nod to talk.")
                }
                if !isNew {
                    Section {
                        Button("Delete", role: .destructive) {
                            state.deleteLineup(lineup.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New time of day" : lineup.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if lineup.name.trimmingCharacters(in: .whitespaces).isEmpty { lineup.name = "Custom" }
                        state.saveLineup(lineup)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func agentPicker(_ title: String, zone: Zone) -> some View {
        Picker(title, selection: Binding(get: { lineup[zone] }, set: { new in
            // The same agent can't sit on both sides: picking it here moves it from the other.
            let other: Zone = zone == .left ? .right : .left
            if new != nil, lineup[other] == new { lineup[other] = lineup[zone] }
            lineup[zone] = new
        })) {
            Text("Empty").tag(UUID?.none)
            ForEach(state.bodyAgents) { a in
                Text(a.name).tag(UUID?.some(a.id))
            }
        }
    }

    private func time(_ key: WritableKeyPath<Lineup, Int>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: lineup[keyPath: key] / 60, minute: lineup[keyPath: key] % 60,
                                      second: 0, of: Date()) ?? Date()
            },
            set: { lineup[keyPath: key] = Lineup.minute(of: $0) }
        )
    }
}

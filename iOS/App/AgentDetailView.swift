import SwiftUI

/// One of your agents: talk to it, find it, share it, or delete it.
struct AgentDetailView: View {
    @Environment(MobileState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let agentId: UUID
    @State private var finding = false
    @State private var confirmDelete = false

    var body: some View {
        if let agent = state.agent(agentId) {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 10) {
                        BotView(agent: agent, mood: state.mood(for: agent), size: 96)
                        Text(agent.name).font(.system(size: 28, weight: .bold)).multilineTextAlignment(.center)
                        Text(subtitle(agent)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)

                    HStack(spacing: 10) {
                        if agent.isGeo {
                            tile("Find", "location.fill") { finding = true }
                        }
                        tile("Talk", "mic.fill") { state.wake(agent) }
                        ShareLink(item: shareText(agent)) {
                            tileLabel("Share", "square.and.arrow.up")
                        }
                        .buttonStyle(PressableStyle())
                    }

                    VStack(spacing: 8) {
                        SectionLabel("About")
                        VStack(spacing: 0) {
                            row("Voice", VoicePalette.voices[agent.voiceIndex].name)
                            if let zone = state.zones[agent.id], !agent.isGeo {
                                RowDivider(); row("Sits", zone.name)
                            }
                            if agent.isGeo {
                                RowDivider(); row("Reach", "\(Int(agent.radiusM)) m")
                                if let d = state.distance(to: agent) {
                                    RowDivider(); row("Distance", Words.distance(d))
                                }
                            }
                            RowDivider(); row("Price", agent.pricing == "paid" ? "Paid" : "Free")
                        }
                        .card()
                    }

                    if !agent.greeting.isEmpty || !(agent.context ?? "").isEmpty {
                        VStack(spacing: 8) {
                            SectionLabel("What it knows")
                            VStack(alignment: .leading, spacing: 12) {
                                if !agent.greeting.isEmpty {
                                    Text("“\(agent.greeting)”").font(.body)
                                }
                                if let context = agent.context, !context.isEmpty {
                                    Text(context).font(.subheadline).foregroundStyle(.secondary).lineLimit(8)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .card()
                        }
                    }

                    Button(role: .destructive) { confirmDelete = true } label: {
                        Text("Delete agent").frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(PressableStyle())
                    .foregroundStyle(.red)
                    .card()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Delete \(agent.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task {
                        await state.delete(agent)
                        dismiss()
                    }
                }
            } message: {
                Text("It disappears for everyone. This can't be undone.")
            }
            .fullScreenCover(isPresented: $finding) { FindView(agentId: agent.id) }
        }
    }

    private func subtitle(_ a: Agent) -> String {
        var parts = [a.isPublic ? "Public" : "Private"]
        if a.isPublic { parts.append(a.pricing == "paid" ? "Paid" : "Free") }
        if a.isGeo {
            if let d = state.distance(to: a) { parts.append("\(Words.distance(d)) away") }
        } else {
            parts.append("With you")
        }
        return parts.joined(separator: " · ")
    }

    private func shareText(_ a: Agent) -> String {
        a.isGeo && a.isPublic
            ? "Come find \(a.name) on Agentsphere. Look at it and nod, and it'll talk to you."
            : "I've got \(a.name) on Agentsphere: an agent that sits around my head and talks when I look at it."
    }

    private func tile(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { tileLabel(title, icon) }
            .buttonStyle(PressableStyle())
    }

    private func tileLabel(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold))
            Text(title).font(.footnote.weight(.semibold))
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, minHeight: 60)
        .card()
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
    }
}

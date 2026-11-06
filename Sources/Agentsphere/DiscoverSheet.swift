import SwiftUI

/// Pick a Claude Code session to put in the room, without opening Finder.
struct DiscoverSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [DiscoveredSession] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return state.discovered }
        return state.discovered.filter {
            [$0.title, $0.lastPrompt, $0.directory.path].contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Add a Claude session").font(.title2.bold())
                Spacer()
                if state.scanning { ProgressView().controlSize(.small) }
                Button { state.refreshDiscovery() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan")
            }
            TextField("Search by title, prompt or folder", text: $query)
                .textFieldStyle(.roundedBorder)

            List {
                let live = filtered.filter(\.isLive)
                let recent = filtered.filter { !$0.isLive }
                if !live.isEmpty {
                    Section("Live now") { ForEach(live) { SessionRow(session: $0) } }
                }
                Section("Recent") {
                    if recent.isEmpty && !state.scanning {
                        Text("No recent sessions found in ~/.claude/projects.").foregroundStyle(.secondary)
                    }
                    ForEach(recent) { SessionRow(session: $0) }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            HStack {
                Button("Other folder…") {
                    dismiss()
                    DispatchQueue.main.async { state.addSession() }
                }
                Spacer()
                Text("Live sessions are forked on the first turn so your terminal keeps its own history.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 720, height: 540)
        .onAppear { state.refreshDiscovery() }
    }
}

struct SessionRow: View {
    @EnvironmentObject var state: AppState
    let session: DiscoveredSession

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(session.isLive ? (session.liveStatus == "busy" ? Color.orange : Color.green) : Color.secondary.opacity(0.3))
                .frame(width: 9, height: 9)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(!session.title.isEmpty ? session.title : !session.lastPrompt.isEmpty ? "“\(session.lastPrompt)”" : "Untitled session").font(.body.weight(.semibold)).lineLimit(1)
                    if session.isLive {
                        Text(session.liveStatus ?? "live").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.green.opacity(0.18), in: Capsule())
                    }
                }
                Text("\(session.folderName) · \(session.lastActive.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
                if !session.lastPrompt.isEmpty && !session.title.isEmpty {
                    Text("“\(session.lastPrompt)”").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(session.directory.path).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if state.isAttached(session) {
                Text("In the room").font(.caption).foregroundStyle(.secondary)
            } else {
                // Deferred: changing the room while the list is mid-update re-enters NSTableView.
                Button("Attach") { DispatchQueue.main.async { state.attach(session) } }
                    .help(session.isLive ? "Continue this conversation (forked, since it's open elsewhere)" : "Continue this conversation")
                Button("New here") { DispatchQueue.main.async { state.attach(session, fresh: true) } }
                    .help("Start a fresh session in \(session.folderName)")
            }
        }
        .padding(.vertical, 3)
    }
}

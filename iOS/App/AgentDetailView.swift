import SwiftUI

/// One of your agents: talk to it, find it, share it, or delete it.
struct AgentDetailView: View {
    @Environment(MobileState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let agentId: UUID
    @State private var finding = false
    @State private var confirmDelete = false
    @State private var menu: [CatalogItem] = []
    @State private var sales: [Sale] = []
    @State private var balance: Double?
    @State private var editing = false

    var body: some View {
        if let agent = state.agent(agentId) {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 10) {
                        BotView(agent: agent, mood: state.mood(for: agent), size: 96)
                        AgentTitle(agent: agent, font: .system(size: 28, weight: .bold), badgeSize: 22)
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
                            if agent.isPublic {
                                RowDivider(); row("Payments", agent.pricing == "paid" ? "On" : "Off")
                            }
                        }
                        .card()
                    }

                    if agent.pricing == "paid", let account = agent.walletAddress {
                        shop(account)
                    }

                    if !menu.isEmpty {
                        VStack(spacing: 8) {
                            SectionLabel("Menu")
                            VStack(spacing: 0) {
                                ForEach(Array(menu.enumerated()), id: \.element.key) { i, item in
                                    if i > 0 { RowDivider() }
                                    row(item.name, Money.usd(item.priceUsdc))
                                }
                            }
                            .card()
                        }
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
            .toolbar {
                if state.owns(agent.id) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit") { editing = true }.fontWeight(.semibold)
                    }
                }
            }
            .sheet(isPresented: $editing) { EditAgentView(agent: agent) }
            // Reloads after an edit too (pricing or the wallet can change).
            .task(id: "\(agent.pricing)\(agent.walletAddress ?? "")\(editing)") {
                guard !editing else { return }
                await loadShop(agent)
            }
            .refreshable { await loadShop(agent) }
        }
    }

    private func loadShop(_ a: Agent) async {
        guard a.pricing == "paid" else { menu = []; sales = []; balance = nil; return }
        async let items = try? Backend.shared.catalog(agentId: a.id)
        async let sold = state.owns(a.id) ? (try? Backend.shared.sales(agentId: a.id)) : nil
        async let held = balance(of: a.walletAddress)
        menu = await items ?? []
        sales = await sold ?? []
        balance = await held
    }

    private func balance(of account: String?) async -> Double? {
        guard let account else { return nil }
        return await Backend.shared.usdcBalance(account: account)
    }

    /// The shop's own Hedera wallet and what it has sold.
    private func shop(_ account: String) -> some View {
        VStack(spacing: 8) {
            SectionLabel("Shop")
            VStack(spacing: 0) {
                HStack {
                    Text("Wallet")
                    Spacer()
                    if let url = HashScan.account(account) {
                        Link(destination: url) {
                            HStack(spacing: 4) {
                                Text(account).monospacedDigit()
                                Image(systemName: "arrow.up.right").font(.caption.weight(.semibold))
                            }
                        }
                        .tint(.blue)
                    }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 46)
                RowDivider(); row("Balance", balance.map { "\(Money.usd($0)) USDC" } ?? "–")
                if state.owns(agentId) {
                    RowDivider(); row("Sold", sales.isEmpty ? "Nothing yet" : "\(sales.count) · \(Money.usd(sales.reduce(0) { $0 + $1.amountUsdc }))")
                }
            }
            .card()

            if !sales.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(sales.enumerated()), id: \.element.id) { i, sale in
                        if i > 0 { RowDivider() }
                        SaleRow(sale: sale)
                    }
                }
                .card()
            }
        }
    }

    private func subtitle(_ a: Agent) -> String {
        var parts = [a.isPublic ? "Public" : "Private"]
        if a.isPublic { parts.append(a.pricing == "paid" ? "Shop" : "Free") }
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

/// One sale: what, how much, when, and its receipt on HashScan.
private struct SaleRow: View {
    let sale: Sale

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sale.qty > 1 ? "\(sale.qty) × \(sale.itemName)" : sale.itemName)
                HStack(spacing: 4) {
                    if let d = sale.date { Text(d, format: .relative(presentation: .named)) }
                    if sale.checkpoint {
                        Text("·")
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.white, .blue)
                        Text("approved")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Money.usd(sale.amountUsdc)).monospacedDigit()
            if let url = sale.receiptURL {
                Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                    .tint(.blue)
                    .accessibilityLabel("Receipt on HashScan")
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }
}

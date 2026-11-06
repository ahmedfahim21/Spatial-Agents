import AuthenticationServices
import SwiftUI

// MARK: - Models

/// Something a shop agent sells, priced in USDC.
struct CatalogItem: Identifiable, Codable, Hashable {
    var id: UUID?
    var name: String
    var note: String = ""
    var priceUsdc: Double

    /// For lists while editing (items get a server id once saved).
    var key: String { id?.uuidString ?? "\(name)-\(priceUsdc)" }
}

/// What the server says about an order: from the chat stream or from `pay`.
struct OrderUpdate: Decodable, Sendable {
    struct Receipt: Decodable, Sendable {
        let itemName: String
        let qty: Int
        let amountUsdc: Double
        let hederaTx: String
        let hashscanUrl: String?
        let checkpoint: Bool?
    }
    struct Approval: Decodable, Sendable {
        let id: String
        let itemId: UUID?
        let itemName: String
        let qty: Int
        let amountUsdc: Double
        let reason: String?
    }
    let status: String
    let itemName: String?
    let qty: Int?
    let amountUsdc: Double?
    let error: String?
    let order: Receipt?
    let approval: Approval?
}

/// An order in a conversation, drawn as a card under the agent's reply.
struct OrderCard: Equatable {
    enum Status: Equatable { case paying, paid, needsApproval, approving, denied, cancelled, failed }
    var status: Status
    var itemName: String
    var qty: Int
    var amount: Double
    var detail: String?
    var hederaTx: String?
    var receiptURL: URL?
    var approvalId: String?
    var itemId: UUID?
    var checkpoint = false

    var title: String { qty > 1 ? "\(qty) × \(itemName)" : itemName }

    /// In words, for the agent's memory of the conversation.
    var outcome: String {
        switch status {
        case .paid: "paid"
        case .needsApproval, .approving: "waiting for the visitor's approval"
        case .paying: "paying"
        case .denied, .cancelled, .failed: "not paid"
        }
    }

    /// Folds a server update into the card.
    mutating func apply(_ u: OrderUpdate) {
        switch u.status {
        case "paying":
            status = .paying
        case "paid":
            status = .paid
            if let r = u.order {
                itemName = r.itemName; qty = r.qty; amount = r.amountUsdc
                hederaTx = r.hederaTx
                receiptURL = r.hashscanUrl.flatMap(URL.init(string:))
                checkpoint = r.checkpoint ?? checkpoint
            }
            detail = nil
        case "checkpoint":
            status = .needsApproval
            if let a = u.approval {
                itemName = a.itemName; qty = a.qty; amount = a.amountUsdc
                approvalId = a.id
                itemId = a.itemId ?? itemId
                detail = a.reason
            }
        case "denied":
            status = .denied
            detail = u.error
        default:
            status = .failed
            detail = u.error
        }
    }

    init(_ u: OrderUpdate) {
        status = .paying
        itemName = u.itemName ?? u.order?.itemName ?? u.approval?.itemName ?? "Order"
        qty = u.qty ?? u.order?.qty ?? u.approval?.qty ?? 1
        amount = u.amountUsdc ?? u.order?.amountUsdc ?? u.approval?.amountUsdc ?? 0
        apply(u)
    }
}

struct WalletInfo: Decodable {
    let accountId: String?
    let accountUrl: String?
    let usdc: Double?
    let spentTodayUsdc: Double
    let autoLimitUsdc: Double
    let dailyBudgetUsdc: Double
}

struct WorldIdentity: Decodable {
    let acr: String?
    let verifiedAt: String

    var level: String { WorldLevel.name(acr) }
    var date: Date? { WorldLevel.date(verifiedAt) }
}

/// What the verified badge shows about a shop (never who the person is).
struct ShopProfile: Decodable {
    let verified: Bool
    let acr: String?
    let verifiedAt: String?
    let walletAccount: String?
    let auditTopic: String?
    let pricing: String?
}

enum WorldLevel {
    static func name(_ acr: String?) -> String {
        guard let acr else { return "Verified" }
        if acr.contains("orb") { return "Orb" }
        if acr.contains("selfie") { return "Selfie Check" }
        return "Verified"
    }

    /// Postgres timestamps ("2026-11-06T12:00:00.123456+00:00"): the seconds are enough.
    static func date(_ s: String?) -> Date? {
        guard let s, s.count >= 19 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: String(s.prefix(19)))
    }
}

enum Money {
    static func usd(_ v: Double) -> String { String(format: "$%.2f", v) }
}

enum HashScan {
    static func account(_ id: String) -> URL? { URL(string: "https://hashscan.io/testnet/account/\(id)") }
    static func topic(_ id: String) -> URL? { URL(string: "https://hashscan.io/testnet/topic/\(id)") }
}

// MARK: - World ID sign-in

/// Opens World ID (auth.world.org) in a secure web sheet and waits for our server's verdict.
/// The verdict is decided on the server; the redirect only says how it went.
@MainActor
final class WorldAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum Outcome: Equatable {
        case ok, denied, cancelled
        case failed(String)
    }

    private var session: ASWebAuthenticationSession?

    func run(purpose: String, approvalId: String? = nil) async -> Outcome {
        let url: URL
        do {
            url = try await Backend.shared.worldStart(purpose: purpose, approvalId: approvalId)
        } catch {
            return .failed(error.localizedDescription)
        }
        return await withCheckedContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: "agentsphere") { callback, error in
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    cont.resume(returning: .cancelled)
                    return
                }
                guard let callback, let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
                    cont.resume(returning: .failed(error?.localizedDescription ?? "World ID didn't answer"))
                    return
                }
                let value = { (name: String) in items.first { $0.name == name }?.value }
                switch value("result") {
                case "ok": cont.resume(returning: .ok)
                case "denied": cont.resume(returning: .denied)
                default: cont.resume(returning: .failed(value("detail") ?? "Verification failed"))
                }
            }
            // A fresh check every time, with no saved session to fall back on.
            s.prefersEphemeralWebBrowserSession = true
            s.presentationContextProvider = self
            session = s
            if !s.start() { cont.resume(returning: .failed("Couldn't open World ID")) }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}

// MARK: - Verified badge

/// A blue seal next to the name of an agent whose owner verified with World ID.
/// Tap it to see what that means.
struct VerifiedBadge: View {
    let agent: Agent
    var size: CGFloat = 15
    var tappable = true
    @State private var showing = false

    var body: some View {
        let seal = Image(systemName: "checkmark.seal.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white, .blue)
            .accessibilityLabel("Verified human")
        if tappable {
            Button { showing = true } label: { seal.padding(4).contentShape(Rectangle()) }
                .buttonStyle(PressableStyle())
                .sheet(isPresented: $showing) {
                    VerifiedSheet(agent: agent)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
        } else {
            seal
        }
    }
}

/// The agent's name with its badge when verified.
struct AgentTitle: View {
    @Environment(MobileState.self) private var state
    let agent: Agent
    var font: Font = .headline
    var badgeSize: CGFloat = 15
    var tappable = true

    var body: some View {
        HStack(spacing: 4) {
            Text(agent.name).font(font).lineLimit(1)
            if state.isVerified(agent) { VerifiedBadge(agent: agent, size: badgeSize, tappable: tappable) }
        }
    }
}

/// What the badge proves, and what it doesn't.
struct VerifiedSheet: View {
    let agent: Agent
    @State private var profile: ShopProfile?
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(.white, .blue)
                        .symbolEffect(.bounce, value: profile?.verified)
                    Text("Verified human").font(.title2.bold())
                    Text("The person behind \(agent.name) proved with World ID that they're a real, unique human.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)

                VStack(spacing: 0) {
                    row("Verified with", profile.map { WorldLevel.name($0.acr) } ?? "World ID")
                    if let d = WorldLevel.date(profile?.verifiedAt) {
                        RowDivider(); row("Since", d.formatted(date: .abbreviated, time: .omitted))
                    }
                    RowDivider(); row("Issuer", "auth.world.org (sandbox)")
                    if let acct = profile?.walletAccount, profile?.pricing == "paid" {
                        RowDivider(); link("Shop wallet", acct, HashScan.account(acct))
                    }
                    if let topic = profile?.auditTopic, profile?.pricing == "paid" {
                        RowDivider(); link("Payment log", topic, HashScan.topic(topic))
                    }
                }
                .card()
                .redacted(reason: profile == nil && !failed ? .placeholder : [])

                Text("World ID shares no name or personal details, only that one unique person verified. It doesn't vouch for what they sell.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .task {
            do { profile = try await Backend.shared.shopProfile(agentId: agent.id) } catch { failed = true }
        }
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

    private func link(_ label: String, _ value: String, _ url: URL?) -> some View {
        HStack {
            Text(label)
            Spacer()
            if let url {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Text(value).monospacedDigit()
                        Image(systemName: "arrow.up.right").font(.caption.weight(.semibold))
                    }
                }
                .tint(.blue)
            } else {
                Text(value).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
    }
}

// MARK: - Orders in a conversation

/// An order the agent placed: paying, paid (with its Hedera receipt), or waiting for you to
/// approve it with World ID.
struct OrderCardView: View {
    @Environment(MobileState.self) private var state
    let card: OrderCard
    let messageId: UUID
    let agentId: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title).font(.headline)
                    Text(statusText).font(.subheadline).foregroundStyle(statusColor)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 8)
                Text(Money.usd(card.amount)).font(.title3.weight(.semibold)).monospacedDigit()
                    .strikethrough(struck, color: .secondary)
                    .foregroundStyle(struck ? .secondary : .primary)
            }

            switch card.status {
            case .paying, .approving:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(card.status == .approving ? "Waiting for World ID…" : "Paying with your wallet on Hedera…")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            case .paid:
                if let url = card.receiptURL {
                    Link(destination: url) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("View receipt on HashScan").font(.footnote.weight(.semibold))
                            Image(systemName: "arrow.up.right").font(.caption2.weight(.bold))
                        }
                    }
                    .tint(.primary)
                }
            case .needsApproval:
                Button { state.approveOrder(messageId: messageId, agentId: agentId) } label: {
                    Label("Approve with World ID", systemImage: "checkmark.seal.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                Text("Large purchases need a quick check that it's really you. Nothing is paid until then.")
                    .font(.caption).foregroundStyle(.secondary)
            case .denied, .cancelled, .failed:
                if let detail = card.detail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(statusColor.opacity(card.status == .paid ? 0.35 : 0), lineWidth: 1)
        }
        .animation(Motion.snappy, value: card.status)
    }

    private var struck: Bool { [.denied, .cancelled, .failed].contains(card.status) }

    private var statusText: String {
        switch card.status {
        case .paying: "Paying…"
        case .paid: card.checkpoint ? "Paid · approved with World ID" : "Paid in USDC"
        case .needsApproval: card.detail ?? "Needs your approval"
        case .approving: "Approving…"
        case .denied: "Not approved · nothing paid"
        case .cancelled: "Cancelled · nothing paid"
        case .failed: "Didn't go through · nothing paid"
        }
    }

    private var statusColor: Color {
        switch card.status {
        case .paid: .green
        case .needsApproval, .approving: .blue
        case .denied, .cancelled, .failed: .orange
        case .paying: .secondary
        }
    }
}

// MARK: - Catalog editing (Create)

/// One editable row of a shop's catalog.
struct CatalogDraft: Identifiable, Equatable {
    let id = UUID()
    var name = ""
    var price = ""

    var priceValue: Double? {
        Double(price.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "$", with: ""))
    }
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && (priceValue ?? 0) > 0 && (priceValue ?? 0) <= 1000
    }
    var isBlank: Bool { name.trimmingCharacters(in: .whitespaces).isEmpty && price.isEmpty }
    var item: CatalogItem? {
        guard isValid, let p = priceValue else { return nil }
        return CatalogItem(name: name.trimmingCharacters(in: .whitespaces), priceUsdc: (p * 100).rounded() / 100)
    }
}

/// Payments for a public agent: verify with World ID, then list what it sells.
struct PaymentsSection: View {
    @Environment(MobileState.self) private var state
    @Binding var enabled: Bool
    @Binding var items: [CatalogDraft]
    @State private var verifying = false
    @State private var problem: String?

    var body: some View {
        Section {
            Toggle("Accept payments", isOn: $enabled.animation(Motion.snappy)).tint(.green)
            if enabled {
                if let identity = state.worldIdentity {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.white, .blue)
                        Text("Verified human")
                        Spacer()
                        Text(identity.level).foregroundStyle(.secondary)
                    }
                } else {
                    Button { verify() } label: {
                        HStack {
                            Label("Verify with World ID", systemImage: "checkmark.seal")
                            Spacer()
                            if verifying { ProgressView() }
                        }
                    }
                    .disabled(verifying)
                }
                ForEach($items) { $item in
                    HStack(spacing: 10) {
                        TextField("Cappuccino", text: $item.name)
                        HStack(spacing: 2) {
                            Text("$").foregroundStyle(.secondary)
                            TextField("3.50", text: $item.price)
                                .keyboardType(.decimalPad)
                                .frame(width: 64)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                .onDelete { items.remove(atOffsets: $0) }
                Button {
                    withAnimation(Motion.snappy) { items.append(CatalogDraft()) }
                } label: {
                    Label("Add item", systemImage: "plus")
                }
                .disabled(items.count >= 30)
            }
        } header: { Text("Payments") } footer: {
            if let problem {
                Text(problem).foregroundStyle(.orange)
            } else if enabled, state.worldIdentity == nil {
                Text("Verify once with World ID and your agents get a blue badge showing a real human runs them. Visitors pay in USDC on Hedera.")
            } else if enabled {
                Text("Visitors' wallets pay in USDC on Hedera. Your agent gets its own wallet, and knows the menu.")
            } else {
                Text("Let people buy from this agent by talking to it.")
            }
        }
    }

    private func verify() {
        verifying = true
        problem = nil
        Task {
            switch await state.verifyWithWorld() {
            case .ok: break
            case .cancelled: break
            case .denied: problem = "World ID didn't confirm a verified human."
            case .failed(let why): problem = why
            }
            verifying = false
        }
    }
}

// MARK: - Wallet (Settings)

/// Your wallet agent: its Hedera account, balance, and when it has to ask you first.
struct WalletSection: View {
    @Environment(MobileState.self) private var state
    @State private var info: WalletInfo?
    @State private var autoLimit = 5.0
    @State private var budget = 20.0
    @State private var loaded = false
    @State private var verifying = false

    var body: some View {
        Section {
            if let acct = info?.accountId {
                LabeledContent("Account") {
                    if let url = HashScan.account(acct) {
                        Link(acct, destination: url).monospacedDigit()
                    }
                }
                LabeledContent("Balance", value: info?.usdc.map { "\(Money.usd($0)) USDC" } ?? "–")
            } else {
                LabeledContent("Account", value: loaded ? "Created on your first purchase" : "…")
            }
            Stepper(value: $autoLimit, in: 0...100, step: 1) {
                LabeledContent("Ask above", value: Money.usd(autoLimit))
            }
            Stepper(value: $budget, in: 0...500, step: 5) {
                LabeledContent("Daily budget", value: Money.usd(budget))
            }
            if let identity = state.worldIdentity {
                LabeledContent("World ID") {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.white, .blue)
                        Text(identity.level)
                    }
                }
            } else {
                Button(verifying ? "Opening World ID…" : "Verify with World ID") {
                    verifying = true
                    Task { _ = await state.verifyWithWorld(); verifying = false }
                }
                .disabled(verifying)
            }
        } header: { Text("Wallet") } footer: {
            Text("Your wallet agent pays shop agents for you in test USDC on Hedera. Above \(Money.usd(autoLimit)), or past today's budget, it asks you to approve with World ID first.")
        }
        .task { await load() }
        .onChange(of: autoLimit) { _, _ in saveSoon() }
        .onChange(of: budget) { _, _ in saveSoon() }
    }

    private func load() async {
        guard let w = try? await Backend.shared.wallet() else { loaded = true; return }
        info = w
        autoLimit = w.autoLimitUsdc
        budget = w.dailyBudgetUsdc
        loaded = true
    }

    @State private var pendingSave: Task<Void, Never>?

    /// Steppers fire on every tap: save once they settle.
    private func saveSoon() {
        guard loaded else { return }
        pendingSave?.cancel()
        let (a, b) = (autoLimit, budget)
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            try? await Backend.shared.saveLimits(autoLimit: a, dailyBudget: b)
        }
    }
}

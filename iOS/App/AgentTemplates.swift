import SwiftUI

/// A starting point for a new agent: picking one fills in the form, and everything stays
/// editable. Contexts work as written; the bracketed bit is where your own details go.
struct AgentTemplate: Identifiable, Equatable {
    let id: String
    let title: String
    let flavor: AgentFlavor
    let name: String
    let greeting: String
    let context: String
    let color: BotColor
    let shape: BotShape
    let voice: String
    var radius = 25.0
    /// A starter menu (name, price in $); turns payments on.
    var menu: [(String, String)] = []

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }

    static let all: [AgentTemplate] = [
        AgentTemplate(
            id: "planner", title: "Daily planner", flavor: .withMe, name: "Daily Planner",
            greeting: "Morning. Want to plan the day?",
            context: """
            You help me plan my day and stay on track. Ask what's on today, help me pick the three things that matter most, and suggest an order with rough times. Keep replies to one or two short sentences, since I'm listening, not reading. Check in on what's done when I come back.
            About me: [your working hours, regular commitments, what you're focused on this week]
            """,
            color: .blue, shape: .hexagon, voice: VoicePalette.voices[0].id),
        AgentTemplate(
            id: "notes", title: "Notes", flavor: .withMe, name: "Notes",
            greeting: "What should I jot down?",
            context: """
            You're my notebook. When I tell you something, confirm it in a few words and remember it. When I ask, read back what I told you, newest first, or just the notes about what I ask for. Never add things I didn't say. Keep replies short.
            """,
            color: .yellow, shape: .squircle, voice: VoicePalette.voices[2].id),
        AgentTemplate(
            id: "coach", title: "Pitch coach", flavor: .withMe, name: "Pitch Coach",
            greeting: "Run me through your pitch.",
            context: """
            You're a friendly, direct pitch coach. Let me practise my pitch out loud, then give one specific thing that worked and one thing to fix. Ask the questions a judge or investor would ask. Keep each reply to two sentences.
            My pitch is about: [your project or company, who it's for, what you want from the audience]
            """,
            color: .green, shape: .drop, voice: VoicePalette.voices[1].id),
        AgentTemplate(
            id: "study", title: "Study buddy", flavor: .withMe, name: "Study Buddy",
            greeting: "What are we learning today?",
            context: """
            You help me learn. Explain things simply, one idea at a time, then check I've got it with a quick question. Quiz me when I ask. Keep replies short and spoken, no lists.
            I'm studying: [subject, level, upcoming exam or goal]
            """,
            color: .violet, shape: .circle, voice: VoicePalette.voices[4].id),
        AgentTemplate(
            id: "helpdesk", title: "Help desk", flavor: .publicPlace, name: "Help Desk",
            greeting: "Hi, I'm the help desk. Ask me about Wi-Fi, food, or where things are.",
            context: """
            You're the help desk for this place. Answer visitors' questions about directions, timings, Wi-Fi, food and who to ask, in one or two short sentences. Be warm and quick. If you don't know, say so and point them to a person who would.
            Details: [schedule, Wi-Fi name and password, where food and toilets are, who to contact]
            """,
            color: .cyan, shape: .circle, voice: VoicePalette.voices[0].id, radius: 40),
        AgentTemplate(
            id: "guide", title: "Tour guide", flavor: .publicPlace, name: "Tour Guide",
            greeting: "Welcome! Want to hear the story of this place?",
            context: """
            You're a tour guide for this spot. Tell visitors its story in short, vivid pieces, one at a time, and ask if they want more. Answer questions about what's around. Two or three sentences per reply.
            About this place: [history, interesting facts, what to see nearby]
            """,
            color: .orange, shape: .capsule, voice: VoicePalette.voices[5].id, radius: 30),
        AgentTemplate(
            id: "cafe", title: "Café", flavor: .publicPlace, name: "Café",
            greeting: "Hi! Can I get you something?",
            context: """
            You're the friendly counter at this café. Help visitors choose from the menu, suggest something if they're unsure, and take their order. Keep replies short. Confirm the item before ordering.
            About the café: [opening hours, specials, where to pick up orders]
            """,
            color: .red, shape: .squircle, voice: VoicePalette.voices[6].id, radius: 20,
            menu: [("Cappuccino", "3.00"), ("Masala chai", "1.50"), ("Croissant", "2.50")]),
        AgentTemplate(
            id: "home", title: "Home", flavor: .privatePlace, name: "Home",
            greeting: "Welcome home. Need anything?",
            context: """
            You know my home. Answer questions about where things are, the Wi-Fi, appliances and reminders I've left you. Keep replies short.
            Details: [Wi-Fi, where spare keys and tools are, bin days, anything you tend to forget]
            """,
            color: .pink, shape: .hexagon, voice: VoicePalette.voices[3].id, radius: 30),
    ]
}

/// The row of templates at the top of Create.
struct TemplatePicker: View {
    let selected: AgentTemplate?
    /// Leading and trailing space before the first and after the last card.
    var inset: CGFloat = 20
    let pick: (AgentTemplate) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(AgentTemplate.all) { t in
                    let on = selected == t
                    Button { pick(t) } label: {
                        VStack(spacing: 6) {
                            BotView(color: t.color, shape: t.shape, mood: on ? .arrived : .idle, size: 34, seed: 0.3)
                            Text(t.title).font(.caption.weight(.semibold)).foregroundStyle(Color.primary).lineLimit(1)
                            Text(t.flavor.rawValue).font(.caption2).foregroundStyle(Color.secondary).lineLimit(1)
                        }
                        .frame(width: 92, height: 92)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(on ? Color.primary : .clear, lineWidth: 2)
                        }
                    }
                    .buttonStyle(PressableStyle())
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, inset)
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }
}

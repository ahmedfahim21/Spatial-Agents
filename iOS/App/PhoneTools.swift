import AlarmKit
import CoreLocation
import EventKit
import HealthKit
import MapKit
import SwiftUI

/// What a personal agent may use on your iPhone. Chosen per agent (Access in Create/Edit);
/// the server only offers these tools to the owner of a private agent.
enum AgentTool: String, CaseIterable, Identifiable {
    case calendar, reminders, health, maps, weather, timers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .health: "Health"
        case .maps: "Maps"
        case .weather: "Weather"
        case .timers: "Alarms and timers"
        }
    }

    var icon: String {
        switch self {
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .health: "heart.fill"
        case .maps: "map.fill"
        case .weather: "cloud.sun.fill"
        case .timers: "alarm.fill"
        }
    }

    var tint: Color {
        switch self {
        case .calendar: .red
        case .reminders: .orange
        case .health: .pink
        case .maps: .green
        case .weather: .blue
        case .timers: .indigo
        }
    }

    /// The tool group a function the model called belongs to.
    static func owning(_ function: String) -> AgentTool? {
        switch function {
        case "calendar_events", "calendar_add_event": .calendar
        case "reminders_list", "reminders_add", "reminders_complete": .reminders
        case "health_summary": .health
        case "places_search", "directions": .maps
        case "weather": .weather
        case "set_alarm", "set_timer": .timers
        default: nil
        }
    }

    /// Shown in the conversation while it runs.
    static func activity(_ function: String) -> String {
        switch function {
        case "calendar_events": "Checked your calendar"
        case "calendar_add_event": "Added to your calendar"
        case "reminders_list": "Checked your reminders"
        case "reminders_add": "Added a reminder"
        case "reminders_complete": "Ticked off a reminder"
        case "health_summary": "Checked Apple Health"
        case "places_search": "Searched nearby"
        case "directions": "Checked travel time"
        case "weather": "Checked the weather"
        case "set_alarm": "Set an alarm"
        case "set_timer": "Started a timer"
        default: "Used a tool"
        }
    }

    /// Health needs a capability the app's signing has to include; hidden until it does.
    static var available: [AgentTool] { allCases.filter { $0 != .health || PhoneTools.healthAvailable } }
}

/// Which tools each agent may use, kept on this phone (it's about this phone's data).
/// New personal agents get everything available.
enum ToolAccess {
    static func tools(for id: UUID) -> Set<AgentTool> {
        guard let saved = UserDefaults.standard.stringArray(forKey: "tools.\(id.uuidString)") else { return Set(AgentTool.available) }
        return Set(saved.compactMap(AgentTool.init).filter(AgentTool.available.contains))
    }

    static func set(_ tools: Set<AgentTool>, for id: UUID) {
        UserDefaults.standard.set(tools.map(\.rawValue).sorted(), forKey: "tools.\(id.uuidString)")
    }
}

/// "Access" switches in Create and Edit.
struct ToolAccessSection: View {
    @Binding var selection: Set<AgentTool>

    var body: some View {
        Section {
            ForEach(AgentTool.available) { tool in
                Toggle(isOn: Binding(get: { selection.contains(tool) },
                                     set: { on in if on { selection.insert(tool) } else { selection.remove(tool) } })) {
                    Label {
                        Text(tool.title)
                    } icon: {
                        Image(systemName: tool.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(tool.tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
                .tint(.green)
            }
        } header: { Text("Access") } footer: {
            Text("It can use these on your iPhone when you ask, like “what's on tomorrow?” or “remind me to call Mum at 6”. iOS asks you the first time. Only what's needed for the answer goes to the model.")
        }
    }
}

/// Runs the agent's tool calls on the phone and returns JSON results for the model.
@MainActor
final class PhoneTools {
    nonisolated static let healthAvailable = Bundle.main.object(forInfoDictionaryKey: "AgentsphereHealthKit") as? Bool ?? false

    struct Call: Equatable {
        let id: String
        let name: String
        let arguments: String
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private let store = EKEventStore()
    private lazy var health = HKHealthStore()
    private let location: () -> CLLocation?

    init(location: @escaping () -> CLLocation?) {
        self.location = location
    }

    func run(_ call: Call, allowed: Set<AgentTool>) async -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]) ?? [:]
        guard let tool = AgentTool.owning(call.name) else { return Self.json(["error": "Unknown tool \(call.name)"]) }
        guard allowed.contains(tool) else { return Self.json(["error": "The user hasn't given this agent access to \(tool.title)."]) }
        do {
            let result: Any
            switch call.name {
            case "calendar_events": result = try await calendarEvents(args)
            case "calendar_add_event": result = try await addEvent(args)
            case "reminders_list": result = try await listReminders(args)
            case "reminders_add": result = try await addReminder(args)
            case "reminders_complete": result = try await completeReminder(args)
            case "health_summary": result = try await healthSummary(args)
            case "places_search": result = try await searchPlaces(args)
            case "directions": result = try await directions(args)
            case "weather": result = try await weather(args)
            case "set_alarm": result = try await setAlarm(args)
            case "set_timer": result = try await setTimer(args)
            default: throw Failure("Unknown tool \(call.name)")
            }
            return Self.json(result)
        } catch {
            print("Agentsphere: tool \(call.name) failed: \(error.localizedDescription)")
            return Self.json(["error": error.localizedDescription])
        }
    }

    // MARK: Calendar

    private func calendarAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return
        case .notDetermined:
            if try await store.requestFullAccessToEvents() { return }
        default: break
        }
        throw Failure("No access to the calendar. The user can allow it in Settings › Privacy & Security › Calendars.")
    }

    private func calendarEvents(_ args: [String: Any]) async throws -> Any {
        try await calendarAccess()
        let start = Self.date(args["start"]) ?? Calendar.current.startOfDay(for: Date())
        let end = Self.date(args["end"]) ?? start.addingTimeInterval(86_400)
        let found = store.events(matching: store.predicateForEvents(withStart: start, end: max(end, start), calendars: nil))
            .sorted { $0.startDate < $1.startDate }
        return [
            "from": Self.local(start), "to": Self.local(end), "count": found.count,
            "events": found.prefix(30).map { e -> [String: Any] in
                var d: [String: Any] = ["title": e.title ?? "Untitled", "calendar": e.calendar.title]
                if e.isAllDay { d["all_day"] = true; d["date"] = Self.day(e.startDate) } else {
                    d["start"] = Self.local(e.startDate)
                    d["end"] = Self.local(e.endDate)
                }
                if let l = e.location, !l.isEmpty { d["location"] = l }
                return d
            },
        ]
    }

    private func addEvent(_ args: [String: Any]) async throws -> Any {
        try await calendarAccess()
        guard let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { throw Failure("The event needs a title.") }
        guard let start = Self.date(args["start"]) else { throw Failure("The event needs a start time.") }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = Self.date(args["end"]).flatMap { $0 > start ? $0 : nil } ?? start.addingTimeInterval(3600)
        event.location = args["location"] as? String
        event.notes = args["notes"] as? String
        guard let calendar = store.defaultCalendarForNewEvents else { throw Failure("There's no calendar to add events to.") }
        event.calendar = calendar
        try store.save(event, span: .thisEvent)
        return ["added": true, "title": title, "start": Self.local(event.startDate), "end": Self.local(event.endDate), "calendar": calendar.title]
    }

    // MARK: Reminders

    private func remindersAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return
        case .notDetermined:
            if try await store.requestFullAccessToReminders() { return }
        default: break
        }
        throw Failure("No access to Reminders. The user can allow it in Settings › Privacy & Security › Reminders.")
    }

    private func reminders(_ predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { cont.resume(returning: $0 ?? []) }
        }
    }

    private func describe(_ r: EKReminder) -> [String: Any] {
        var d: [String: Any] = ["title": r.title ?? "Untitled", "list": r.calendar.title]
        if let due = r.dueDateComponents, let date = Calendar.current.date(from: due) {
            d["due"] = due.hour == nil ? Self.day(date) : Self.local(date)
            if !r.isCompleted, date < Date() { d["overdue"] = true }
        }
        if r.isCompleted { d["done"] = true }
        if r.priority > 0, r.priority <= 4 { d["high_priority"] = true }
        return d
    }

    private func listReminders(_ args: [String: Any]) async throws -> Any {
        try await remindersAccess()
        let open = await reminders(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil))
        // Due ones first, soonest first; undated after.
        let sorted = open.sorted {
            let a = $0.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? .distantFuture
            let b = $1.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? .distantFuture
            return a < b
        }
        var result: [String: Any] = ["open_count": open.count, "open": sorted.prefix(40).map(describe)]
        if args["include_completed"] as? Bool == true {
            let weekAgo = Date().addingTimeInterval(-7 * 86_400)
            let done = await reminders(store.predicateForCompletedReminders(withCompletionDateStarting: weekAgo, ending: Date(), calendars: nil))
            result["completed_this_week"] = done.prefix(20).map(describe)
        }
        return result
    }

    private func addReminder(_ args: [String: Any]) async throws -> Any {
        try await remindersAccess()
        guard let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { throw Failure("The reminder needs a title.") }
        let r = EKReminder(eventStore: store)
        r.title = title
        r.notes = args["notes"] as? String
        guard let list = store.defaultCalendarForNewReminders() else { throw Failure("There's no Reminders list to add to.") }
        r.calendar = list
        if let due = Self.date(args["due"]) {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            r.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(r, commit: true)
        return ["added": true, "reminder": describe(r)]
    }

    private func completeReminder(_ args: [String: Any]) async throws -> Any {
        try await remindersAccess()
        let want = ((args["title"] as? String) ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        guard !want.isEmpty else { throw Failure("Which reminder?") }
        let open = await reminders(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil))
        let title = { (r: EKReminder) in (r.title ?? "").lowercased() }
        guard let match = open.first(where: { title($0) == want })
            ?? open.first(where: { title($0).contains(want) || (want.contains(title($0)) && !title($0).isEmpty) }) else {
            return ["done": false, "error": "No open reminder matches “\(want)”.", "open": open.prefix(15).map { $0.title ?? "" }]
        }
        match.isCompleted = true
        try store.save(match, commit: true)
        return ["done": true, "reminder": match.title ?? want]
    }

    // MARK: Health

    private func healthSummary(_ args: [String: Any]) async throws -> Any {
        guard Self.healthAvailable, HKHealthStore.isHealthDataAvailable() else {
            throw Failure("Apple Health isn't set up for Agentsphere yet.")
        }
        let metrics = (args["metrics"] as? [String]) ?? ["steps"]
        let days = min(30, max(1, (args["days"] as? Int) ?? Int((args["days"] as? Double) ?? 1)))
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: now))!

        var read: Set<HKObjectType> = []
        for m in metrics {
            switch m {
            case "steps": read.insert(HKQuantityType(.stepCount))
            case "distance": read.insert(HKQuantityType(.distanceWalkingRunning))
            case "active_energy": read.insert(HKQuantityType(.activeEnergyBurned))
            case "resting_heart_rate": read.insert(HKQuantityType(.restingHeartRate))
            case "heart_rate": read.insert(HKQuantityType(.heartRate))
            case "sleep": read.insert(HKCategoryType(.sleepAnalysis))
            case "workouts": read.insert(HKObjectType.workoutType())
            default: break
            }
        }
        try await health.requestAuthorization(toShare: [], read: read)

        var out: [String: Any] = ["from": Self.day(start), "to": Self.day(now),
                                  "note": "Health doesn't say whether reading was allowed: no data can also mean no access."]
        for m in metrics {
            switch m {
            case "steps": out[m] = try await daily(.stepCount, .count(), .cumulativeSum, from: start, round: 0)
            case "distance": out["distance_km"] = try await daily(.distanceWalkingRunning, .meterUnit(with: .kilo), .cumulativeSum, from: start, round: 1)
            case "active_energy": out["active_energy_kcal"] = try await daily(.activeEnergyBurned, .kilocalorie(), .cumulativeSum, from: start, round: 0)
            case "resting_heart_rate": out["resting_heart_rate_bpm"] = try await daily(.restingHeartRate, Self.bpm, .discreteAverage, from: start, round: 0)
            case "heart_rate": out["heart_rate_bpm"] = try await heartRate(from: start)
            case "sleep": out["sleep"] = try await sleep(days: days)
            case "workouts": out["workouts"] = try await workouts(from: start)
            default: break
            }
        }
        return out
    }

    private static let bpm = HKUnit.count().unitDivided(by: .minute())

    /// One value per day: sums for counts, averages for rates.
    private func daily(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ option: HKStatisticsOptions, from start: Date, round places: Int) async throws -> [[String: Any]] {
        let type = HKQuantityType(id)
        let query = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: HKQuery.predicateForSamples(withStart: start, end: Date())),
            options: option, anchorDate: start, intervalComponents: DateComponents(day: 1))
        let collection = try await query.result(for: health)
        var rows: [[String: Any]] = []
        collection.enumerateStatistics(from: start, to: Date()) { stats, _ in
            let q = option == .cumulativeSum ? stats.sumQuantity() : stats.averageQuantity()
            guard let v = q?.doubleValue(for: unit) else { return }
            let p = pow(10.0, Double(places))
            rows.append(["day": Self.day(stats.startDate), "value": (v * p).rounded() / p])
        }
        return rows
    }

    private func heartRate(from start: Date) async throws -> [String: Any] {
        let query = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(.heartRate), predicate: HKQuery.predicateForSamples(withStart: start, end: Date())),
            options: [.discreteAverage, .discreteMin, .discreteMax, .mostRecent])
        guard let s = try await query.result(for: health) else { return [:] }
        var d: [String: Any] = [:]
        if let v = s.averageQuantity()?.doubleValue(for: Self.bpm) { d["average"] = Int(v.rounded()) }
        if let v = s.minimumQuantity()?.doubleValue(for: Self.bpm) { d["min"] = Int(v.rounded()) }
        if let v = s.maximumQuantity()?.doubleValue(for: Self.bpm) { d["max"] = Int(v.rounded()) }
        if let v = s.mostRecentQuantity()?.doubleValue(for: Self.bpm) { d["latest"] = Int(v.rounded()) }
        return d
    }

    /// Hours asleep per night, by the morning it ended.
    private func sleep(days: Int) async throws -> [[String: Any]] {
        let from = Calendar.current.date(byAdding: .hour, value: -12, to: Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: Date()))!)!
        let query = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: HKQuery.predicateForSamples(withStart: from, end: Date()))],
            sortDescriptors: [SortDescriptor(\.endDate)])
        let samples = try await query.result(for: health)
        let asleep: Set<Int> = [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                                HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue]
        var byNight: [String: (asleep: Double, deep: Double, rem: Double, bed: Date?, up: Date?)] = [:]
        for s in samples where asleep.contains(s.value) {
            let key = Self.day(s.endDate)
            var n = byNight[key] ?? (0, 0, 0, nil, nil)
            let h = s.endDate.timeIntervalSince(s.startDate) / 3600
            n.asleep += h
            if s.value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue { n.deep += h }
            if s.value == HKCategoryValueSleepAnalysis.asleepREM.rawValue { n.rem += h }
            n.bed = min(n.bed ?? s.startDate, s.startDate)
            n.up = max(n.up ?? s.endDate, s.endDate)
            byNight[key] = n
        }
        return byNight.keys.sorted().map { k in
            let n = byNight[k]!
            var d: [String: Any] = ["night_ending": k, "hours_asleep": (n.asleep * 10).rounded() / 10]
            if n.deep > 0 { d["deep_hours"] = (n.deep * 10).rounded() / 10 }
            if n.rem > 0 { d["rem_hours"] = (n.rem * 10).rounded() / 10 }
            if let b = n.bed { d["fell_asleep"] = Self.clock(b) }
            if let u = n.up { d["woke"] = Self.clock(u) }
            return d
        }
    }

    private func workouts(from start: Date) async throws -> [[String: Any]] {
        let query = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForSamples(withStart: start, end: Date()))],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: 15)
        return try await query.result(for: health).map { w in
            var d: [String: Any] = ["type": Self.name(w.workoutActivityType), "start": Self.local(w.startDate),
                                    "minutes": Int((w.duration / 60).rounded())]
            if let kcal = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()) {
                d["active_kcal"] = Int(kcal.rounded())
            }
            if let km = w.totalDistance?.doubleValue(for: .meterUnit(with: .kilo)), km > 0 { d["km"] = (km * 10).rounded() / 10 }
            return d
        }
    }

    private static func name(_ t: HKWorkoutActivityType) -> String {
        switch t {
        case .running: "run"
        case .walking: "walk"
        case .cycling: "cycle"
        case .swimming: "swim"
        case .hiking: "hike"
        case .yoga: "yoga"
        case .functionalStrengthTraining, .traditionalStrengthTraining: "strength training"
        case .highIntensityIntervalTraining: "HIIT"
        case .dance, .cardioDance, .socialDance: "dance"
        case .elliptical: "elliptical"
        case .rowing: "rowing"
        case .badminton: "badminton"
        case .cricket: "cricket"
        case .soccer: "football"
        case .tennis: "tennis"
        case .mindAndBody: "mind and body"
        case .coreTraining: "core training"
        case .pilates: "pilates"
        default: "workout"
        }
    }

    // MARK: Maps

    private func here() throws -> CLLocation {
        guard let l = location() else { throw Failure("The user's location isn't available right now.") }
        return l
    }

    private func search(_ query: String, near: CLLocation?) async throws -> [MKMapItem] {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        if let near { req.region = MKCoordinateRegion(center: near.coordinate, latitudinalMeters: 6000, longitudinalMeters: 6000) }
        return try await MKLocalSearch(request: req).start().mapItems
    }

    private func searchPlaces(_ args: [String: Any]) async throws -> Any {
        guard let query = args["query"] as? String, !query.isEmpty else { throw Failure("Search for what?") }
        let me = location()
        let items = try await search(query, near: me)
        let places = items.prefix(6).map { item -> [String: Any] in
            var d: [String: Any] = ["name": item.name ?? query]
            if let me { d["distance_m"] = Int(item.location.distance(from: me).rounded()) }
            if let a = item.address?.shortAddress ?? item.address?.fullAddress { d["address"] = a }
            if let c = item.pointOfInterestCategory { d["category"] = c.rawValue.replacingOccurrences(of: "MKPOICategory", with: "") }
            return d
        }
        .sorted { ($0["distance_m"] as? Int ?? .max) < ($1["distance_m"] as? Int ?? .max) }
        return ["query": query, "places": places]
    }

    private func directions(_ args: [String: Any]) async throws -> Any {
        guard let dest = args["destination"] as? String, !dest.isEmpty else { throw Failure("Directions to where?") }
        let me = try here()
        guard let target = try await search(dest, near: me).first else { throw Failure("Couldn't find “\(dest)”.") }
        let mode = args["mode"] as? String ?? "driving"
        let req = MKDirections.Request()
        req.source = MKMapItem(location: me, address: nil)
        req.destination = target
        req.transportType = mode == "walking" ? .walking : mode == "transit" ? .transit : .automobile
        let eta = try await MKDirections(request: req).calculateETA()
        var d: [String: Any] = ["destination": target.name ?? dest, "mode": mode,
                                "minutes": Int((eta.expectedTravelTime / 60).rounded()),
                                "km": (eta.distance / 100).rounded() / 10,
                                "arrive_by": Self.clock(eta.expectedArrivalDate)]
        if let a = target.address?.shortAddress { d["address"] = a }
        return d
    }

    // MARK: Weather (Open-Meteo: free, no key)

    private func weather(_ args: [String: Any]) async throws -> Any {
        let me = try here()
        let days = min(7, max(1, (args["days"] as? Int) ?? 2))
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(format: "%.3f", me.coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.3f", me.coordinate.longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,precipitation,wind_speed_10m,relative_humidity_2m"),
            .init(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset,uv_index_max"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: String(days)),
        ]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure("No weather right now.") }
        var out: [String: Any] = ["units": "°C, km/h, %"]
        if let cur = o["current"] as? [String: Any] {
            out["now"] = [
                "temp": cur["temperature_2m"] ?? NSNull(), "feels_like": cur["apparent_temperature"] ?? NSNull(),
                "conditions": Self.conditions(cur["weather_code"]), "wind": cur["wind_speed_10m"] ?? NSNull(),
                "humidity": cur["relative_humidity_2m"] ?? NSNull(),
            ]
        }
        // The next 12 hours, every 3.
        if let h = o["hourly"] as? [String: Any], let times = h["time"] as? [String],
           let temps = h["temperature_2m"] as? [Double], let rain = h["precipitation_probability"] as? [Any], let codes = h["weather_code"] as? [Any] {
            let nowKey = Self.hourFormat.string(from: Date())
            if let i = times.firstIndex(where: { $0.prefix(13) >= nowKey }) {
                out["next_hours"] = stride(from: i, to: min(times.count, i + 13), by: 3).map { j -> [String: Any] in
                    ["time": String(times[j].suffix(5)), "temp": temps[j], "rain_chance": rain[j], "conditions": Self.conditions(codes[j])]
                }
            }
        }
        if let d = o["daily"] as? [String: Any], let dates = d["time"] as? [String] {
            let col = { (k: String) in d[k] as? [Any] ?? [] }
            out["days"] = dates.indices.map { i -> [String: Any] in
                var row: [String: Any] = ["date": dates[i]]
                for (k, name) in [("temperature_2m_max", "high"), ("temperature_2m_min", "low"), ("precipitation_probability_max", "rain_chance"), ("uv_index_max", "uv")] {
                    if i < col(k).count { row[name] = col(k)[i] }
                }
                if i < col("weather_code").count { row["conditions"] = Self.conditions(col("weather_code")[i]) }
                if i < col("sunrise").count, let s = col("sunrise")[i] as? String { row["sunrise"] = String(s.suffix(5)) }
                if i < col("sunset").count, let s = col("sunset")[i] as? String { row["sunset"] = String(s.suffix(5)) }
                return row
            }
        }
        return out
    }

    private static func conditions(_ code: Any?) -> String {
        switch (code as? Int) ?? Int((code as? Double) ?? -1) {
        case 0: "clear"
        case 1: "mainly clear"
        case 2: "partly cloudy"
        case 3: "overcast"
        case 45, 48: "fog"
        case 51, 53, 55, 56, 57: "drizzle"
        case 61, 63: "rain"
        case 65: "heavy rain"
        case 66, 67: "freezing rain"
        case 71, 73, 75, 77: "snow"
        case 80, 81: "rain showers"
        case 82: "violent rain showers"
        case 85, 86: "snow showers"
        case 95: "thunderstorm"
        case 96, 99: "thunderstorm with hail"
        default: "unknown"
        }
    }

    // MARK: Alarms and timers (AlarmKit)

    private func alarmAccess() async throws {
        let m = AlarmManager.shared
        switch m.authorizationState {
        case .authorized: return
        case .notDetermined:
            if try await m.requestAuthorization() == .authorized { return }
        default: break
        }
        throw Failure("No permission to set alarms. The user can allow it in Settings › Agentsphere.")
    }

    private func ring(at date: Date, title: String) async throws {
        try await alarmAccess()
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title))
        } else {
            alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title),
                                            stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.fill"))
        }
        let attributes = AlarmAttributes<AgentAlarm>(presentation: AlarmPresentation(alert: alert), tintColor: .orange)
        _ = try await AlarmManager.shared.schedule(id: UUID(), configuration: .alarm(schedule: .fixed(date), attributes: attributes))
    }

    private func setAlarm(_ args: [String: Any]) async throws -> Any {
        guard let t = args["time"] as? String else { throw Failure("What time?") }
        let parts = t.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { throw Failure("“\(t)” isn't a time like 07:30.") }
        let cal = Calendar.current
        var date: Date
        if let d = args["date"] as? String, let day = Self.date(d) {
            date = cal.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)!
        } else {
            date = cal.nextDate(after: Date(), matching: DateComponents(hour: parts[0], minute: parts[1]), matchingPolicy: .nextTime)!
        }
        guard date > Date() else { throw Failure("That time has already passed.") }
        let label = (args["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Alarm"
        try await ring(at: date, title: label)
        return ["set": true, "rings_at": Self.local(date), "label": label]
    }

    private func setTimer(_ args: [String: Any]) async throws -> Any {
        let minutes = (args["minutes"] as? Double) ?? Double((args["minutes"] as? Int) ?? 0)
        guard minutes > 0, minutes <= 24 * 60 else { throw Failure("For how long?") }
        let date = Date().addingTimeInterval(minutes * 60)
        let label = (args["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Timer"
        try await ring(at: date, title: label)
        return ["set": true, "minutes": minutes, "rings_at": Self.local(date), "label": label]
    }

    // MARK: Formatting

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
    private static let localFormat = formatter("EEE yyyy-MM-dd'T'HH:mm")
    private static let dayFormat = formatter("EEE yyyy-MM-dd")
    private static let clockFormat = formatter("HH:mm")
    private static let hourFormat = formatter("yyyy-MM-dd'T'HH")
    private static let parsers = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"].map(formatter)

    /// Local wall-clock times, as the model was told to write them (an offset is honoured too).
    static func date(_ value: Any?) -> Date? {
        guard var s = (value as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        // Times are given to the model as "Sat 2026-11-07T09:30"; it may hand them back that way.
        if let space = s.firstIndex(of: " "), s[..<space].allSatisfy(\.isLetter) { s = String(s[s.index(after: space)...]) }
        if let d = try? Date(s, strategy: .iso8601) { return d }
        let plain = s.count > 19 ? String(s.prefix(19)) : s
        for p in parsers { if let d = p.date(from: plain) { return d } }
        return nil
    }

    static func local(_ d: Date) -> String { localFormat.string(from: d) }
    static func day(_ d: Date) -> String { dayFormat.string(from: d) }
    static func clock(_ d: Date) -> String { clockFormat.string(from: d) }

    /// Phone time for the prompt, like "Fri 2026-11-06T20:45".
    static var now: String { local(Date()) }

    static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

struct AgentAlarm: AlarmMetadata {}

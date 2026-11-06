// Tools a personal agent can use on its owner's iPhone. The model asks for one; this function
// passes the request to the app (`data: {"tool_calls": [...]}`), the app runs it on the phone
// (EventKit, HealthKit, MapKit, AlarmKit, Open-Meteo) and sends the result back as a `tool`
// message in the next request. The server never sees the data beyond those results.

type Tool = { type: "function"; function: { name: string; description: string; parameters: Record<string, unknown> } };

const fn = (name: string, description: string, properties: Record<string, unknown>, required: string[] = []): Tool => ({
  type: "function",
  function: { name, description, parameters: { type: "object", properties, required } },
});

const time = (what: string) => ({ type: "string", description: `${what}, local ISO 8601 date-time like 2026-11-07T09:30` });

/** Grouped the way the app's per-agent Access switches are. */
export const TOOL_GROUPS: Record<string, Tool[]> = {
  calendar: [
    fn("calendar_events", "List the user's calendar events between two local times.", {
      start: time("Start"),
      end: time("End"),
    }, ["start", "end"]),
    fn("calendar_add_event", "Add an event to the user's default calendar.", {
      title: { type: "string" },
      start: time("Start"),
      end: time("End (default: one hour after start)"),
      location: { type: "string" },
      notes: { type: "string" },
    }, ["title", "start"]),
  ],
  reminders: [
    fn("reminders_list", "List the user's open reminders (their to-do list), with due dates.", {
      include_completed: { type: "boolean", description: "Also list ones completed in the last week" },
    }),
    fn("reminders_add", "Add a reminder (to-do) for the user.", {
      title: { type: "string" },
      due: time("When it's due (optional)"),
      notes: { type: "string" },
    }, ["title"]),
    fn("reminders_complete", "Mark one of the user's open reminders as done, by its title.", {
      title: { type: "string", description: "The reminder's title, or close to it" },
    }, ["title"]),
  ],
  health: [
    fn("health_summary", "Read the user's Apple Health data: daily totals or averages over recent days.", {
      metrics: {
        type: "array",
        items: { type: "string", enum: ["steps", "distance", "active_energy", "sleep", "resting_heart_rate", "heart_rate", "workouts"] },
      },
      days: { type: "integer", description: "How many days back, including today (1 = today only). Max 30." },
    }, ["metrics"]),
  ],
  maps: [
    fn("places_search", "Search for places near the user (shops, cafés, pharmacies, addresses…). Returns names, distances and addresses.", {
      query: { type: "string" },
    }, ["query"]),
    fn("directions", "Travel time and distance from the user's location to a place.", {
      destination: { type: "string", description: "A place name or address" },
      mode: { type: "string", enum: ["driving", "walking", "transit"] },
    }, ["destination"]),
  ],
  weather: [
    fn("weather", "The weather where the user is: now, the next hours, and the coming days.", {
      days: { type: "integer", description: "Days of forecast, 1 to 7 (default 2)" },
    }),
  ],
  timers: [
    fn("set_alarm", "Set an alarm on the user's iPhone. It rings like a Clock alarm.", {
      time: { type: "string", description: "24-hour local time HH:MM" },
      date: { type: "string", description: "YYYY-MM-DD (default: the next time that clock time comes round)" },
      label: { type: "string" },
    }, ["time"]),
    fn("set_timer", "Start a countdown timer on the user's iPhone.", {
      minutes: { type: "number" },
      label: { type: "string" },
    }, ["minutes"]),
  ],
};

export function toolsFor(groups: unknown): Tool[] {
  if (!Array.isArray(groups)) return [];
  return [...new Set(groups.filter((g): g is string => typeof g === "string"))].flatMap((g) => TOOL_GROUPS[g] ?? []);
}

export const TOOL_PROMPT =
  "You can use tools on the user's iPhone: their calendar, reminders, Apple Health, maps, weather, alarms and timers " +
  "(only the ones offered). Use them whenever a question depends on that information instead of guessing. " +
  "When the user clearly asks for an action, do it straight away; ask one short question first only if a needed " +
  "detail, like a time, is missing. Before a tool call, say at most a two- or three-word phrase such as \"Let me check.\" " +
  "After the results, answer in one or two spoken sentences: round numbers, natural times like \"half past three\", " +
  "no lists. If a tool fails or isn't allowed, say plainly what you couldn't do, in one sentence, and offer what you can. " +
  "Earlier replies may end with [Done on the phone: …]: that's a record of tools you already used then. Don't repeat " +
  "those actions unless asked again, and never write that bracket yourself.";

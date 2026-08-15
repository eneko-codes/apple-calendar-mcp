import Foundation
import MCP

/// The catalogue is the authorisation surface: a tool that is not listed here cannot
/// be called, and the name it is listed under is the label on the permission switch in
/// Claude Desktop. Reads carry no verb prefix; writes always start with
/// create_/update_/delete_, so the destructive ones sort together.
public enum ToolCatalog {

    public static let statusName = "calendar_status"
    public static let searchName = "calendar_search"
    public static let listName = "calendars_list"
    public static let getName = "calendar_get"
    public static let createName = "create_event"
    public static let updateName = "update_event"
    public static let deleteName = "delete_event"

    public static func all() -> [Tool] {
        [status, list, search, get, create, update, delete]
    }

    // MARK: Schema helpers

    private static func object(properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        schema["additionalProperties"] = .bool(false)
        return .object(schema)
    }

    private static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    /// A field an update may also empty.
    ///
    /// `type` is the single string `"string"`, never `["string", "null"]`. Claude
    /// Desktop's schema sanitiser drops a property outright when its `type` is a union
    /// and hands the model a bare `{}` in its place. Text fields survive that by luck —
    /// an unschema'd string is still sent as a string — but an array alongside them is
    /// serialised to a string and rejected on arrival. So the clearing affordance is the
    /// empty string, which `stringEdit` already reads as `.cleared`. An explicit `null`
    /// is still honoured for any client that sends one; it is no longer advertised.
    private static func clearableString(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func integer(_ description: String, minimum: Int, maximum: Int, default def: Int)
        -> Value
    {
        .object([
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(minimum), "maximum": .int(maximum), "default": .int(def),
        ])
    }

    private static let dateHelp = """
        Accepts 2026-08-12 (whole day), 2026-08-12T09:00 (local time), or \
        2026-08-12T09:00:00+02:00 (explicit offset).
        """

    private static let spanProperty: Value = .object([
        "type": .string("string"),
        "enum": .array([.string("this"), .string("future")]),
        "default": .string("this"),
        "description": .string(
            """
            Only meaningful for a repeating series. "this" affects the single occurrence \
            you addressed; "future" affects it and every later one. Defaults to "this" so \
            a series is never rewritten by accident.
            """),
    ])

    private static let alarmsProperty: Value = .object([
        "type": .string("array"),
        "items": .object(["type": .string("string")]),
        "description": .string(
            """
            Reminders relative to the start: "-15m", "-1h", "-1d", or "0" for the moment \
            it begins. Negative means before.
            """),
    ])

    // MARK: Reads

    static let status = Tool(
        name: statusName,
        title: "Calendar permission status",
        description: """
            Reports whether this server has permission to reach Calendar, and says exactly \
            what to enable and where if it does not. Reads no events.

            Use it when another calendar tool fails on permissions, or when setting the \
            server up. Do not use it to look for events.
            """,
        inputSchema: object(properties: [:]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let list = Tool(
        name: listName,
        title: "List calendars",
        description: """
            Lists every calendar with its account, whether it accepts writes, and which is \
            the default for new events.

            Call this before create_event if you are not certain a calendar exists under \
            that exact name — subscribed and holiday calendars are read-only and will \
            refuse writes.
            """,
        inputSchema: object(properties: [:]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let search = Tool(
        name: searchName,
        title: "Search calendar events",
        description: """
            Finds events in a date range, optionally filtered by text and by calendar. \
            Returns one line per event with its id, and echoes the range and time zone it \
            actually used.

            'from' and 'to' are required and the range cannot exceed \(Configuration.maximumRangeDays) \
            days: an unbounded calendar query is slow and rarely what was meant. Always \
            search before calendar_get, update_event or delete_event — ids come from here.
            """,
        inputSchema: object(
            properties: [
                "from": string("Start of the range (inclusive). \(dateHelp)"),
                "to": string("End of the range (exclusive). \(dateHelp)"),
                "query": string(
                    "Optional text to match against title, location and notes."),
                "calendars": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string(
                        "Optional calendar names to search. Omit to search all of them."),
                ]),
                "limit": integer(
                    "Maximum number of events to return.",
                    minimum: Configuration.searchLimitRange.lowerBound,
                    maximum: Configuration.searchLimitRange.upperBound,
                    default: Configuration.searchLimit),
                "offset": integer(
                    "Skip this many matches; use it to page.",
                    minimum: Configuration.offsetRange.lowerBound,
                    maximum: Configuration.offsetRange.upperBound, default: 0),
            ],
            required: ["from", "to"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let get = Tool(
        name: getName,
        title: "Full event record",
        description: """
            Returns everything stored for one event: times, calendar, location, notes, \
            alarms, recurrence and attendees. Also reports whether the event can still be \
            edited.

            Needs an id from calendar_search. For a repeating series the id encodes which \
            occurrence you mean, so it cannot be shortened or reconstructed by hand.
            """,
        inputSchema: object(
            properties: ["id": string("Identifier returned by calendar_search.")],
            required: ["id"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    // MARK: Writes

    static let create = Tool(
        name: createName,
        title: "Create an event",
        description: """
            Adds an event to a calendar. If both 'start' and 'end' are plain days \
            (2026-08-12) the event is all-day; otherwise it is timed.

            It CANNOT invite anyone: EventKit does not allow adding attendees, so guests \
            must be invited from Calendar.app. It also cannot create a repeating event — \
            only single ones. Creating an event in the past is allowed but is flagged in \
            the response.
            """,
        inputSchema: object(
            properties: [
                "calendar": string("Name of the calendar, exactly as calendars_list shows it."),
                "title": string("Event title."),
                "start": string("When it begins. \(dateHelp)"),
                "end": string("When it ends. \(dateHelp)"),
                "location": string("Optional location."),
                "notes": string("Optional notes."),
                "url": string("Optional URL."),
                "alarms": alarmsProperty,
            ],
            required: ["calendar", "title", "start", "end"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false
        )
    )

    static let update = Tool(
        name: updateName,
        title: "Modify an event",
        description: """
            Changes fields on an existing event. Omitting a field leaves it as it is; \
            pass "" to empty location, notes or url, and [] to remove every alarm.

            REFUSES any event that has already ended — finished events are the record of \
            what happened. An event currently in progress can still be edited. For a \
            repeating series, 'span' decides whether the change hits one occurrence or all \
            later ones.
            """,
        inputSchema: object(
            properties: [
                "id": string("Identifier returned by calendar_search."),
                "span": spanProperty,
                "title": string("New title."),
                "start": string("New start. \(dateHelp)"),
                "end": string("New end. \(dateHelp)"),
                "location": clearableString("New location. \"\" clears it."),
                "notes": clearableString("New notes. \"\" clears them."),
                "url": clearableString("New URL. \"\" clears it."),
                "alarms": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string(
                        "Replaces ALL alarms. [] removes them. Format: \"-15m\", \"-1h\", \"-1d\"."
                    ),
                ]),
            ],
            required: ["id"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let delete = Tool(
        name: deleteName,
        title: "Delete an event",
        description: """
            Permanently deletes an event. Requires confirm=true and returns the full record \
            it removed together with a create_event call that would restore it.

            REFUSES any event that has already ended. For a repeating series, 'span' \
            decides whether one occurrence or every later one is removed — check which you \
            mean before calling.
            """,
        inputSchema: object(
            properties: [
                "id": string("Identifier returned by calendar_search."),
                "span": spanProperty,
                "confirm": .object([
                    "type": .string("boolean"),
                    "description": .string("Must be true. Without it the call is refused."),
                ]),
            ],
            required: ["id", "confirm"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
    )
}

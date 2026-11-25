import Foundation

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

    private static func integer(_ description: String, range: ClosedRange<Int>, default def: Int)
        -> Value
    {
        .object([
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(range.lowerBound), "maximum": .int(range.upperBound),
            "default": .int(def),
        ])
    }

    private static func limit(_ things: String, range: ClosedRange<Int>, default def: Int) -> Value {
        integer("Maximum number of \(things) in one page.", range: range, default: def)
    }

    private static func offset(_ things: String) -> Value {
        integer(
            """
            Number of \(things) to skip. A result that does not hold every one says, in its \
            first lines, the offset to pass for the next page.
            """, range: Configuration.offsetRange, default: 0)
    }

    private static func stringList(_ description: String) -> Value {
        .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
            "description": .string(description),
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
            it begins. Negative means before. Each must be within \
            \(Configuration.alarmMinutesRange.upperBound / 1440) days of the start.
            """),
    ])

    // MARK: Reads

    static let status = Tool(
        name: statusName,
        title: "Calendar permission status",
        description: """
            Reports whether this server has permission to reach Calendar, and says exactly \
            what to enable and where if it does not. Also lists the sizes its results keep \
            to. Reads no events.

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
            Lists the calendars, \(Configuration.defaultCalendarLimit) to a page in name \
            order, each with its account, whether it accepts writes, and which is the \
            default for new events. When there are more than the page holds, the first \
            lines of the result give the offset of the next page: pass limit (up to \
            \(Configuration.calendarLimitRange.upperBound)) and offset.

            Call this before create_event if you are not certain a calendar exists under \
            that exact name — subscribed and holiday calendars are read-only and will \
            refuse writes.
            """,
        inputSchema: object(properties: [
            "limit": limit(
                "calendars", range: Configuration.calendarLimitRange,
                default: Configuration.defaultCalendarLimit),
            "offset": offset("calendars"),
        ]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let search = Tool(
        name: searchName,
        title: "Search calendar events",
        description: """
            Finds events, \(Configuration.defaultSearchLimit) to a page, oldest first, one \
            line each with day, time, title, calendar, location and id. With no argument \
            it lists what is on from today onwards. A title, calendar name or location longer \
            than \(Configuration.rowFieldWidth) characters is clipped in its row, and notes and \
            attendees are left out: calendar_get reads one event in full. When more match \
            than the page holds, the first lines of the result say so and give the offset \
            of the next page: pass limit (up to \(Configuration.searchLimitRange.upperBound)) \
            and offset.

            from_date and to_date bound the search, and both days are included. from_date \
            alone runs on with no end; to_date alone covers the \
            \(Configuration.longestScanDays) days up to it. One call looks at no more than \
            \(Configuration.longestScanDays) days, oldest first, and stops as soon as its \
            page is full: when it stops before the end of the range, the first lines say \
            how far it got and the from_date that continues from there. query filters by \
            text in title, location and notes; calendars by calendar name. The result \
            echoes the range and time zone it used.

            Always search before calendar_get, update_event or delete_event — ids come \
            from here.
            """,
        inputSchema: object(
            properties: [
                "from_date": string(
                    """
                    First day or moment of the range, included. Without it the search starts \
                    today, or, when to_date is given, \(Configuration.longestScanDays) days \
                    before to_date. \(dateHelp)
                    """),
                "to_date": string(
                    """
                    Last day or moment of the range, included: a plain day runs to the end \
                    of that day. Without it the search runs on from from_date. \(dateHelp)
                    """),
                "query": string(
                    "Optional text to match against title, location and notes."),
                "calendars": stringList(
                    "Optional calendar names to search. Omit to search all of them."),
                "limit": limit(
                    "events", range: Configuration.searchLimitRange,
                    default: Configuration.defaultSearchLimit),
                "offset": offset("events"),
            ]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let get = Tool(
        name: getName,
        title: "Full event record",
        description: """
            Returns one event's record: when it is, its calendar, whether it is past, in \
            progress or upcoming, its id, alarms, recurrence, location, url, its first \
            \(Configuration.defaultAttendeeLimit) attendees by name and its notes, up to \
            \(Configuration.defaultMaxCharacters) characters in all. The first lines of the \
            result say what it does not hold and how to get it: pass limit (up to \
            \(Configuration.attendeeLimitRange.upperBound)) and offset for more attendees, \
            and character_offset and max_characters (up to \
            \(Configuration.maxCharactersRange.upperBound)) to read a long record one window \
            at a time, keeping limit and offset the same from one window to the next.

            Needs an id from calendar_search. For a repeating series the id encodes which \
            occurrence you mean, so it cannot be shortened or reconstructed by hand.
            """,
        inputSchema: object(
            properties: [
                "id": string("Identifier returned by calendar_search."),
                "limit": limit(
                    "attendees", range: Configuration.attendeeLimitRange,
                    default: Configuration.defaultAttendeeLimit),
                "offset": offset("attendees"),
                "character_offset": integer(
                    """
                    Number of characters of the record to skip. A result that does not hold \
                    all of it says, in its first lines, the value to pass for the rest.
                    """, range: Configuration.offsetRange, default: 0),
                "max_characters": integer(
                    "The most characters of the record to return.",
                    range: Configuration.maxCharactersRange,
                    default: Configuration.defaultMaxCharacters),
            ],
            required: ["id"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    // MARK: Writes

    static let create = Tool(
        name: createName,
        title: "Create an event",
        description: """
            Adds an event to a calendar and answers with a short receipt: its title, when \
            it is and the id to use from then on. calendar_get returns the full record. If \
            both 'start' and 'end' are plain days (2026-08-12) the event is all-day; \
            otherwise it is timed.

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
            Changes fields on an existing event and answers with a short receipt: the \
            fields changed, when the event now is and its id, which changes when an \
            occurrence of a series is moved. calendar_get returns the full record. Omitting \
            a field leaves it as it is; pass "" to empty location, notes or url, and [] to \
            remove every alarm.

            Works on past, in-progress and upcoming events alike. For a repeating series, \
            'span' decides whether the change hits one occurrence or all later ones — \
            except 'calendar', which always moves the whole series: EventKit has no \
            concept of one occurrence living in a different calendar from the rest, so a \
            recurring event's calendar cannot be changed here at all.
            """,
        inputSchema: object(
            properties: [
                "id": string("Identifier returned by calendar_search."),
                "span": spanProperty,
                "title": string("New title."),
                "start": string("New start. \(dateHelp)"),
                "end": string("New end. \(dateHelp)"),
                "calendar": string(
                    "Move the event to this calendar, exactly as calendars_list shows it. "
                        + "Refused for a recurring event."),
                "location": clearableString("New location. \"\" clears it."),
                "notes": clearableString("New notes. \"\" clears them."),
                "url": clearableString("New URL. \"\" clears it."),
                "alarms": stringList(
                    "Replaces ALL alarms. [] removes them. Format: \"-15m\", \"-1h\", \"-1d\", "
                        + "each within \(Configuration.alarmMinutesRange.upperBound / 1440) days of the start."
                ),
            ],
            required: ["id"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let delete = Tool(
        name: deleteName,
        title: "Delete an event",
        description: """
            Permanently deletes an event. Requires confirm=true and returns what it \
            removed, once, as the arguments create_event needs to make a new event like \
            it, up to \(Configuration.deletedRecordCharacters) characters. Nothing can read \
            the event afterwards: read one with long notes through calendar_get first.

            Works on past, in-progress and upcoming events alike. For a repeating series, \
            'span' decides whether one occurrence or every later one is removed — check \
            which you mean before calling.
            """,
        inputSchema: object(
            properties: [
                "id": string("Identifier returned by calendar_search."),
                "span": spanProperty,
                "confirm": .object([
                    "type": .string("boolean"),
                    "default": .bool(false),
                    "description": .string("Must be true. Without it the call is refused."),
                ]),
            ],
            required: ["id", "confirm"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
    )
}

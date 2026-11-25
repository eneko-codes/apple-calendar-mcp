import Foundation

public enum CalendarMCPServer {

    public static let name = "apple-calendar-mcp"
    public static let version = "2.0.0"

    /// Returned from `initialize`. It carries what per-tool descriptions cannot state
    /// once: the id workflow, that results come in pages, and where policy actually lives.
    public static let instructions = """
        Access to the macOS Calendar app through EventKit.

        Workflow: calendar_search first, then use the id it returns. Occurrences of a \
        repeating series share one EventKit identifier, so an occurrence id also encodes \
        its start time — it cannot be shortened or reconstructed by hand. Identifiers can \
        change when an account resynchronises.

        RESULTS COME IN PAGES. calendar_search and calendars_list return one page of rows, \
        and calendar_get one window of an event's record with one page of its attendees. \
        When something exists that a result does not hold, its first lines say how much \
        there is and the exact arguments that return the rest: limit and offset for rows, \
        character_offset and max_characters for a long record. A limit, an offset or a \
        window size outside its range is moved to the nearest allowed value, and the first \
        lines say which one was used. A search row clips a long title, calendar name or \
        location and leaves out notes and attendees; calendar_get has them. An argument a \
        tool does not take is refused, not ignored.

        calendar_search takes from_date and to_date, both included; with neither it starts \
        today. One call looks at no more than \(Configuration.longestScanDays) days, oldest \
        first, and stops when its page is full. When it stops before the end of the range \
        it says how far it got and the from_date that continues from there.

        Dates accept three forms: 2026-08-12 (whole day), 2026-08-12T09:00 (local time), \
        or 2026-08-12T09:00:00+02:00 (explicit offset). An event whose start and end are \
        both plain days is all-day. A day or a time that does not exist, such as 30 \
        February or a time the clocks skip, is refused, never moved to a nearby one.

        EventKit cannot invite attendees and cannot create repeating events; both must be \
        done in Calendar.app.

        Write tools carry a verb prefix (create_, update_, delete_) and answer with a short \
        receipt, not the whole event. delete_event is permanent and requires confirm=true; \
        its receipt is the only copy of what it removed, so read an event with long notes \
        through calendar_get before deleting it.

        EVERY CALL IS BOUNDED. A call that has not finished after \
        \(Configuration.callTimeout.components.seconds) seconds is abandoned and answered \
        with an error saying so. A write abandoned that way may still go through: look the \
        event up before repeating it.

        This server exposes the calendar's full capability. What may be used at any moment \
        is decided by the permission switches in the client, not by this code.
        """

    /// The store is a parameter so the whole server can be driven by a double. Nothing
    /// in this function opens a calendar by itself.
    public static func run(store: any EventStore = SystemEventStore()) async {
        Diagnostics.started(version: version)
        await serveStandardStreams(handler: handler(tools: CalendarTools(store: store)))
    }

    public static func handler(tools: CalendarTools) -> MCPHandler {
        MCPHandler(
            name: name, version: version, instructions: instructions,
            catalog: ToolCatalog.all(), tools: tools)
    }
}

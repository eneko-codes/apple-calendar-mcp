import Foundation

public enum CalendarMCPServer {

    public static let name = "apple-calendar-mcp"
    public static let version = "1.2.1"

    /// Returned from `initialize`. It carries what per-tool descriptions cannot state
    /// once: the id workflow and where policy actually lives.
    public static let instructions = """
        Access to the macOS Calendar app through EventKit.

        Workflow: calendar_search first, then use the id it returns. Occurrences of a \
        repeating series share one EventKit identifier, so an occurrence id also encodes \
        its start time — it cannot be shortened or reconstructed by hand. Identifiers can \
        change when an account resynchronises.

        Dates accept three forms: 2026-08-12 (whole day), 2026-08-12T09:00 (local time), \
        or 2026-08-12T09:00:00+02:00 (explicit offset). An event whose start and end are \
        both plain days is all-day.

        EventKit cannot invite attendees and cannot create repeating events; both must be \
        done in Calendar.app.

        Write tools carry a verb prefix (create_, update_, delete_). delete_event is \
        permanent and requires confirm=true.

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

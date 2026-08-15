import Foundation
import MCP

public enum CalendarMCPServer {

    public static let name = "apple-calendar-mcp"
    public static let version = "1.0.0"

    /// Returned from `initialize`. It carries what per-tool descriptions cannot state
    /// once: the id workflow, the rule about history, and where policy actually lives.
    public static let instructions = """
        Access to the macOS Calendar app through EventKit.

        Workflow: calendar_search first, then use the id it returns. Occurrences of a \
        repeating series share one EventKit identifier, so an occurrence id also encodes \
        its start time — it cannot be shortened or reconstructed by hand. Identifiers can \
        change when an account resynchronises.

        Dates accept three forms: 2026-08-12 (whole day), 2026-08-12T09:00 (local time), \
        or 2026-08-12T09:00:00+02:00 (explicit offset). An event whose start and end are \
        both plain days is all-day.

        This server will not modify or delete an event that has already ended. A finished \
        event is the record of what happened. An event still in progress can be edited.

        EventKit cannot invite attendees and cannot create repeating events; both must be \
        done in Calendar.app.

        Write tools carry a verb prefix (create_, update_, delete_). delete_event is \
        permanent and requires confirm=true.

        This server exposes the calendar's full capability. What may be used at any moment \
        is decided by the permission switches in the client, not by this code.
        """

    /// The store is a parameter so the whole server can be driven by a double. Nothing
    /// in this function opens a calendar by itself.
    public static func run(store: any EventStore = SystemEventStore()) async throws {
        let tools = CalendarTools(store: store)
        let server = Server(
            name: name,
            version: version,
            instructions: instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in .init(tools: ToolCatalog.all()) }
        await server.withMethodHandler(CallTool.self) { await tools.handle($0) }

        // The default StdioTransport logger is a no-op handler. Leave it that way: a
        // logger writing to stdout would interleave with the JSON-RPC stream and break
        // every response after the first log line.
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}

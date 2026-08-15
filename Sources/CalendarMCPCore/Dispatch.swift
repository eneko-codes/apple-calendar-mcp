import Foundation
import MCP

/// Routes a `tools/call` to the store and renders the answer.
///
/// Never touches EventKit directly — everything goes through `EventStore`, which is
/// what lets the tests drive every branch below against an in-memory double with no
/// calendar and no consent dialog.
public struct CalendarTools: Sendable {
    private let store: any EventStore
    private let calendar: Calendar
    private let format: Format
    /// Injected so the "already ended" rule can be tested at a fixed instant instead of
    /// depending on when the suite happens to run.
    private let now: @Sendable () -> Date

    public init(
        store: any EventStore,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.calendar = calendar
        self.format = Format(calendar: calendar)
        self.now = now
    }

    public func handle(_ parameters: CallTool.Parameters) async -> CallTool.Result {
        do {
            let text = try await run(parameters)
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch let error as ToolError {
            return .init(
                content: [.text(text: error.message, annotations: nil, _meta: nil)], isError: true)
        } catch {
            return .init(
                content: [
                    .text(
                        text: ToolError.storeFailure(error.localizedDescription).message,
                        annotations: nil, _meta: nil)
                ], isError: true)
        }
    }

    private func run(_ parameters: CallTool.Parameters) async throws -> String {
        let arguments = Arguments(parameters.arguments, calendar: calendar)

        if parameters.name == ToolCatalog.statusName {
            return format.status(store.authorization(), binaryPath: Self.binaryPath)
        }

        try await requireAccess()

        switch parameters.name {
        case ToolCatalog.listName:
            return format.calendarList(try await store.calendars())

        case ToolCatalog.searchName:
            return try await search(arguments)

        case ToolCatalog.getName:
            let id = EventID.decode(try arguments.requiredString("id"))
            guard let event = try await store.fetch(id: id) else {
                throw ToolError.notFound(id: id.encoded)
            }
            return format.detail(event, now: now())

        case ToolCatalog.createName:
            return try await create(arguments)

        case ToolCatalog.updateName:
            return try await update(arguments)

        case ToolCatalog.deleteName:
            return try await delete(arguments)

        default:
            throw ToolError.badArgument(
                name: "name", reason: "'\(parameters.name)' is not a tool of this server")
        }
    }

    private func requireAccess() async throws {
        var authorization = store.authorization()
        if authorization == .notDetermined {
            authorization = await store.requestAccess()
        }
        guard authorization.isUsable else { throw ToolError.notAuthorized(authorization) }
    }

    // MARK: Tools

    private func search(_ arguments: Arguments) async throws -> String {
        let from = try arguments.requiredDate("from").date
        let to = try arguments.requiredDate("to").date
        guard to >= from else { throw ToolError.endBeforeStart }

        let days = calendar.dateComponents([.day], from: from, to: to).day ?? 0
        guard days <= Configuration.maximumRangeDays else {
            throw ToolError.rangeTooLong(days: days, maximum: Configuration.maximumRangeDays)
        }

        let titles = try arguments.stringArray("calendars")

        let limit = try arguments.int(
            "limit", default: Configuration.searchLimit, in: Configuration.searchLimitRange)
        let offset = try arguments.int("offset", default: 0, in: Configuration.offsetRange)

        let page = try await store.search(
            query: arguments.optionalString("query"), from: from, to: to,
            calendarTitles: titles, limit: limit, offset: offset)
        return format.searchResults(
            page, from: from, to: to, calendarTitles: titles, offset: offset)
    }

    private func create(_ arguments: Arguments) async throws -> String {
        let calendarTitle = try arguments.requiredString("calendar")
        // Resolved here rather than in the store so the error can list what is actually
        // available — and so that error is reachable from the tests.
        let available = try await store.calendars()
        guard let target = available.first(where: { $0.title == calendarTitle }) else {
            throw ToolError.calendarNotFound(
                title: calendarTitle,
                available: available.filter(\.isWritable).map(\.title))
        }
        guard target.isWritable else { throw ToolError.calendarReadOnly(title: calendarTitle) }

        let start = try arguments.requiredDate("start")
        let end = try arguments.requiredDate("end")
        guard end.date > start.date else { throw ToolError.endBeforeStart }

        var draft = EventDraft(
            calendarTitle: calendarTitle,
            title: try arguments.requiredString("title"),
            start: start.date,
            end: end.date,
            // All-day is inferred from the input rather than carried as a separate flag:
            // two sources of truth for the same fact drift apart.
            isAllDay: start.isDateOnly && end.isDateOnly)
        draft.location = arguments.optionalString("location")
        draft.notes = arguments.optionalString("notes")
        draft.url = arguments.optionalString("url")
        draft.alarmOffsetsMinutes = try arguments.alarms("alarms") ?? []

        return format.created(try await store.create(draft), now: now())
    }

    private func update(_ arguments: Arguments) async throws -> String {
        let id = EventID.decode(try arguments.requiredString("id"))
        let span = try arguments.span()
        let existing = try await requireEditable(id)

        var changes = EventChanges()
        changes.title = arguments.stringEdit("title")
        changes.start = try arguments.dateEdit("start")
        changes.end = try arguments.dateEdit("end")
        changes.location = arguments.stringEdit("location")
        changes.notes = arguments.stringEdit("notes")
        changes.url = arguments.stringEdit("url")
        changes.alarmOffsetsMinutes = try arguments.alarmEdit("alarms")

        guard !changes.isEmpty else { throw ToolError.nothingToUpdate }

        // Checked against the values that will actually apply, so moving only the start
        // past an unchanged end is caught.
        let resultingStart = if case .set(let value) = changes.start { value } else { existing.start }
        let resultingEnd = if case .set(let value) = changes.end { value } else { existing.end }
        guard resultingEnd > resultingStart else { throw ToolError.endBeforeStart }

        let updated = try await store.update(id: id, changes: changes, span: span)
        return format.updated(updated, fields: changes.changedFields, span: span, now: now())
    }

    private func delete(_ arguments: Arguments) async throws -> String {
        let id = EventID.decode(try arguments.requiredString("id"))
        let span = try arguments.span()
        _ = try await requireEditable(id)

        guard arguments.bool("confirm") else {
            throw ToolError.confirmationRequired(action: "Deleting an event")
        }
        return format.deleted(try await store.delete(id: id, span: span), span: span)
    }

    /// Loads the event and enforces the one rule this server will not bend: a finished
    /// event is the record of what happened, and nothing here rewrites it.
    private func requireEditable(_ id: EventID) async throws -> EventDetail {
        guard let event = try await store.fetch(id: id) else {
            throw ToolError.notFound(id: id.encoded)
        }
        let instant = now()
        guard !event.hasEnded(asOf: instant) else {
            throw ToolError.eventHasEnded(
                title: "\(event.title) · \(DateParsing.dayWithYear(event.start, calendar: calendar))",
                ended: format.elapsed(since: event.end, now: instant))
        }
        guard event.calendarIsWritable else {
            throw ToolError.calendarReadOnly(title: event.calendarTitle)
        }
        return event
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "(unknown)"
    }
}

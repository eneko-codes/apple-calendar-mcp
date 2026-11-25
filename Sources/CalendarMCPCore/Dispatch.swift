import Foundation
import Synchronization

/// Routes a `tools/call` to the store and renders the answer.
///
/// Never touches EventKit directly — everything goes through `EventStore`, which is
/// what lets the tests drive every branch below against an in-memory double with no
/// calendar and no consent dialog.
public struct CalendarTools: ToolHandler {
    private let store: any EventStore
    private let calendar: Calendar
    private let format: Format
    /// Injected so time-dependent output (elapsed-since text, the past/in-progress/
    /// upcoming state shown in `detail`, the day a search with no dates starts from) can be
    /// tested at a fixed instant instead of depending on when the suite happens to run.
    private let now: @Sendable () -> Date
    private let timeout: Duration
    private let scanBudget: Duration

    public init(
        store: any EventStore,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        timeout: Duration = Configuration.callTimeout,
        scanBudget: Duration = Configuration.scanBudget
    ) {
        self.store = store
        self.calendar = calendar
        self.format = Format(calendar: calendar)
        self.now = now
        self.timeout = timeout
        self.scanBudget = scanBudget
    }

    public func handle(_ parameters: ToolCall) async -> ToolOutput {
        let started = ContinuousClock.now
        let outcome = await Deadline.run(within: timeout) {
            do {
                return Result<String, any Error>.success(try await run(parameters))
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .success(let text)?:
            return ToolOutput(text: text, isError: false)
        case .failure(let error)?:
            return failure(error, tool: parameters.name, since: started)
        case nil:
            return failure(
                ToolError.timedOut(seconds: Int(timeout.components.seconds)),
                tool: parameters.name, since: started)
        }
    }

    private func failure(
        _ error: any Error, tool: String, since started: ContinuousClock.Instant
    ) -> ToolOutput {
        Diagnostics.toolFailed(tool, error: error, since: started)
        let message =
            (error as? ToolError)?.message
            ?? ToolError.storeFailure(error.localizedDescription).message
        return ToolOutput(text: message, isError: true)
    }

    private func run(_ parameters: ToolCall) async throws -> String {
        let arguments = Arguments(parameters.arguments, calendar: calendar)

        // Checked before access is asked for, so a mistyped name never raises the consent
        // dialog.
        guard let tool = ToolCatalog.all().first(where: { $0.name == parameters.name }) else {
            throw ToolError.unknownTool(parameters.name)
        }
        // An argument the tool does not take is refused, not ignored: a search sent with
        // the `from` and `to` of an earlier version would otherwise run from today, as if
        // no date had been given, and look like an answer.
        let taken = (tool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]).keys.sorted()
        if let stray = (parameters.arguments ?? [:]).keys.sorted().first(where: { !taken.contains($0) }) {
            throw ToolError.unknownArgument(name: stray, tool: tool.name, taken: taken)
        }
        if parameters.name == ToolCatalog.statusName {
            return format.status(store.authorization(), binaryPath: Self.binaryPath)
        }

        try await requireAccess()

        switch parameters.name {
        case ToolCatalog.listName: return try await list(arguments)
        case ToolCatalog.searchName: return try await search(arguments)
        case ToolCatalog.getName: return try await get(arguments)
        case ToolCatalog.createName: return try await create(arguments)
        case ToolCatalog.updateName: return try await update(arguments)
        case ToolCatalog.deleteName: return try await delete(arguments)
        default: throw ToolError.unknownTool(parameters.name)
        }
    }

    private func requireAccess() async throws {
        var authorization = store.authorization()
        if authorization == .notDetermined {
            authorization = await store.requestAccess()
        }
        guard authorization.isUsable else { throw ToolError.notAuthorized(authorization) }
    }

    // MARK: Calendars

    private func list(_ arguments: Arguments) async throws -> String {
        let page = try arguments.page(
            defaultLimit: Configuration.defaultCalendarLimit, limits: Configuration.calendarLimitRange)
        let calendars = try await store.calendars().sorted(by: Self.precedes)
        return ToolStandard.page(
            of: calendars, limit: page.limit, offset: page.offset, things: "calendars",
            notices: arguments.notices
        ) {
            format.calendarList($0, matching: calendars.count)
        }
    }

    /// By name whatever its case, then by every other field shown, so that two calendars
    /// tie only when their rows read the same and a page boundary falls in the same place
    /// on the next call.
    static func precedes(_ lhs: CalendarInfo, _ rhs: CalendarInfo) -> Bool {
        let order = lhs.title.caseInsensitiveCompare(rhs.title)
        if order != .orderedSame { return order == .orderedAscending }
        return (lhs.title, lhs.sourceName, lhs.isWritable ? 0 : 1, lhs.isDefaultForNewEvents ? 0 : 1)
            < (rhs.title, rhs.sourceName, rhs.isWritable ? 0 : 1, rhs.isDefaultForNewEvents ? 0 : 1)
    }

    // MARK: Search

    /// The stretch of time a search covers. `upper` is the first instant past it, because
    /// `to_date` is included: a plain day runs to the end of that day.
    struct SearchRange {
        var lower: Date
        /// `nil` when the search has no end: `from_date` alone, or no date at all.
        var upper: Date?
        /// Both as echoed in the result's header.
        var lowerText: String
        var upperText: String
        /// `to_date` alone: the range starts as far back as one call looks, so earlier
        /// events exist that were never looked at.
        var startsAtTheReach = false
    }

    private func searchRange(from: ParsedDate?, to: ParsedDate?) throws -> SearchRange {
        func text(_ date: ParsedDate) -> String {
            DateParsing.roundTrip(date.date, isAllDay: date.isDateOnly, calendar: calendar)
        }
        let upper = to.map { to in
            to.isDateOnly
                ? calendar.date(byAdding: .day, value: 1, to: to.date) ?? to.date
                // One second past a moment includes an event that starts exactly on it.
                : to.date.addingTimeInterval(1)
        }
        switch (from, upper) {
        case (let from?, let upper?):
            guard upper > from.date else { throw ToolError.rangeEndsBeforeItStarts }
            return SearchRange(
                lower: from.date, upper: upper, lowerText: text(from), upperText: to.map(text) ?? "")
        case (let from?, nil):
            return SearchRange(lower: from.date, upper: nil, lowerText: text(from), upperText: "onwards")
        case (nil, let upper?):
            // The range starts on a whole day, the first one that lies inside one call's
            // reach, so that the `to_date` the result names for looking further back ends
            // exactly where this range begins, whatever time of day `to_date` carried.
            let furthest =
                calendar.date(byAdding: .day, value: -Configuration.longestScanDays, to: upper) ?? upper
            let dayStart = calendar.startOfDay(for: furthest)
            let lower =
                dayStart == furthest
                ? furthest : calendar.date(byAdding: .day, value: 1, to: dayStart) ?? furthest
            return SearchRange(
                lower: lower, upper: upper,
                lowerText: DateParsing.roundTrip(lower, isAllDay: true, calendar: calendar),
                upperText: to.map(text) ?? "", startsAtTheReach: true)
        case (nil, nil):
            let today = calendar.startOfDay(for: now())
            return SearchRange(
                lower: today, upper: nil,
                lowerText: DateParsing.roundTrip(today, isAllDay: true, calendar: calendar),
                upperText: "onwards")
        }
    }

    /// Why a scan ended, which decides what the result may say about the total.
    enum ScanEnd: Equatable {
        /// The whole range was looked at: the matches are all there are.
        case rangeCovered
        /// Enough matches for the page and one more: more exist, how many is not known.
        case pageFilled
        /// `Configuration.longestScanDays` were looked at and the range goes on.
        case reachExhausted
        /// `scanBudget` ran out between two pieces of the range.
        case outOfTime
    }

    struct Scan {
        var found: [EventSummary] = []
        var examined = 0
        /// The first instant not looked at.
        var reached: Date
        var end = ScanEnd.rangeCovered
    }

    /// A total order, so that no two events tie and a page boundary falls in the same
    /// place on the next call. EventKit promises no order of its own.
    static func precedes(_ lhs: EventSummary, _ rhs: EventSummary) -> Bool {
        (lhs.start, lhs.end, lhs.title, lhs.calendarTitle, lhs.id.encoded)
            < (rhs.start, rhs.end, rhs.title, rhs.calendarTitle, rhs.id.encoded)
    }

    /// Walks the range one query at a time, oldest first, until it holds `needed` matches,
    /// the range ends, one call's reach is used up or the time budget runs out.
    ///
    /// Each query returns every event that overlaps its span, so an event that runs across
    /// a boundary comes back twice. It is kept only by the piece it starts in (or by the
    /// first piece, when it began before the range), which also keeps the pieces in order:
    /// joined end to end they are sorted by start.
    private func scan(
        _ range: SearchRange, query: String?, calendarTitles: [String], needed: Int
    ) async throws -> Scan {
        let reach =
            calendar.date(byAdding: .day, value: Configuration.longestScanDays, to: range.lower)
            ?? range.lower
        let stop = range.upper.map { min($0, reach) } ?? reach
        let outOfTime = ContinuousClock.now + scanBudget

        var scan = Scan(reached: range.lower)
        while scan.reached < stop {
            // Never before the first piece: a call that returned nothing could not be
            // narrowed into one that returns something.
            if scan.reached > range.lower, ContinuousClock.now >= outOfTime {
                scan.end = .outOfTime
                return scan
            }
            let pieceStart = scan.reached
            let pieceEnd = min(
                calendar.date(byAdding: .day, value: Configuration.scanChunkDays, to: pieceStart) ?? stop,
                stop)
            let piece = try await store.search(
                query: query, from: pieceStart, to: pieceEnd, calendarTitles: calendarTitles)
            scan.examined += piece.examined
            scan.found += piece.matches.filter { event in
                guard event.start < pieceEnd else { return false }
                return pieceStart == range.lower
                    ? (event.start >= pieceStart || event.end > pieceStart) : event.start >= pieceStart
            }.sorted(by: Self.precedes)
            scan.reached = pieceEnd
            if scan.found.count >= needed { break }
        }
        if let upper = range.upper, scan.reached >= upper {
            scan.end = .rangeCovered
        } else {
            scan.end = scan.found.count >= needed ? .pageFilled : .reachExhausted
        }
        return scan
    }

    private func search(_ arguments: Arguments) async throws -> String {
        let range = try searchRange(
            from: try arguments.optionalDate("from_date"), to: try arguments.optionalDate("to_date"))
        let query = try arguments.optionalString("query")
        let titles = try arguments.stringArray("calendars")
        let page = try arguments.page(
            defaultLimit: Configuration.defaultSearchLimit, limits: Configuration.searchLimitRange)

        // One more than the page holds, so that a full page can say whether more exist.
        let scan = try await scan(
            range, query: query, calendarTitles: titles, needed: page.offset + page.limit + 1)
        let found = scan.found.count
        // The exact place the scan got to: a plain day when it stopped on one, else the
        // minute, so that the call that continues leaves no gap.
        let reachedDay = DateParsing.roundTrip(
            scan.reached, isAllDay: calendar.startOfDay(for: scan.reached) == scan.reached,
            calendar: calendar)

        // What stopped the scan short of the range, if anything did.
        var stopped: [String] = []
        switch scan.end {
        case .rangeCovered, .pageFilled:
            break
        case .reachExhausted:
            stopped.append(
                Notice.scanStopped(
                    after: scan.examined, things: "events",
                    narrowBy: "from_date=\(reachedDay) for the events from then on"))
        case .outOfTime:
            stopped.append(
                Notice.partial(
                    after: scan.examined, things: "events",
                    narrowBy: "from_date=\(reachedDay) for the events from then on"))
        }
        if range.startsAtTheReach {
            let dayBefore = calendar.date(byAdding: .day, value: -1, to: range.lower) ?? range.lower
            stopped.append(
                Notice.scanStopped(
                    after: scan.examined, things: "events",
                    narrowBy: "to_date=\(DateParsing.roundTrip(dayBefore, isAllDay: true, calendar: calendar))"
                        + " for the events before \(range.lowerText)"))
        }

        let summary: String
        switch scan.end {
        case .rangeCovered: summary = Format.plural(found, "event")
        case .pageFilled: summary = "at least \(Format.plural(found, "event"))"
        case .reachExhausted, .outOfTime: summary = "\(Format.plural(found, "event")) so far"
        }
        let whenEmpty = Format.nothing(
            scan.end == .rangeCovered
                ? "No events in this range." : "No events in the part of the range that was looked at.",
            matching: found)

        return ToolStandard.fitting(page.limit) { size in
            let rows = Array(scan.found.dropFirst(page.offset).prefix(size))
            let position: String?
            switch scan.end {
            case .rangeCovered:
                position = Notice.page(offset: page.offset, count: rows.count, total: found, things: "events")
            case .pageFilled:
                position = Notice.page(offset: page.offset, count: rows.count, total: nil, things: "events")
            case .reachExhausted, .outOfTime:
                position = Notice.page(
                    offset: page.offset, count: rows.count, total: found,
                    things: "events found before the scan stopped")
            }
            let rendered = format.searchResults(
                rows, summary: summary, range: "\(range.lowerText) → \(range.upperText)",
                calendarTitles: titles, rangeStart: range.lower, whenEmpty: whenEmpty)
            return ToolStandard.withNotices(
                arguments.notices + [position].compactMap { $0 } + stopped
                    + Format.clipNotices(rendered.clippedFields),
                rendered.text)
        }
    }

    // MARK: One event

    private func get(_ arguments: Arguments) async throws -> String {
        let id = EventID.decode(try arguments.requiredString("id"))
        let attendeePage = try arguments.page(
            defaultLimit: Configuration.defaultAttendeeLimit, limits: Configuration.attendeeLimitRange)
        let window = try arguments.window()
        guard let event = try await store.fetch(id: id) else {
            throw ToolError.notFound(id: id.encoded)
        }

        // By name, because EventKit documents no order a second page could rely on.
        let attendees = event.attendees.sorted { ($0.name, $0.status) < ($1.name, $1.status) }
        let listed = Array(attendees.dropFirst(attendeePage.offset).prefix(attendeePage.limit))
        let record = format.detail(event, attendees: listed, now: now())

        var notices = arguments.notices
        if let position = Notice.page(
            offset: attendeePage.offset, count: listed.count, total: attendees.count,
            things: "attendees")
        {
            notices.append(position)
        }
        return ToolStandard.fitting(window.maxCharacters) { size in
            let part = ToolStandard.window(
                of: record, characterOffset: window.characterOffset, maxCharacters: size,
                label: "Event")
            return ToolStandard.withNotices(notices + [part.notice].compactMap { $0 }, part.text)
        }
    }

    // MARK: Writes

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
        draft.location = try arguments.optionalString("location")
        draft.notes = try arguments.optionalString("notes")
        draft.url = try arguments.optionalString("url")
        draft.alarmOffsetsMinutes = try arguments.alarms("alarms") ?? []

        return format.created(try await store.create(draft), now: now())
    }

    private func update(_ arguments: Arguments) async throws -> String {
        let id = EventID.decode(try arguments.requiredString("id"))
        let span = try arguments.span()

        var changes = EventChanges()
        changes.title = try arguments.stringEdit("title")
        // An event keeps a title: there is nothing to empty it to, and saying it changed
        // when the store left it alone would be a false receipt.
        if changes.title == .cleared {
            throw ToolError.badArgument(name: "title", reason: "it is empty; an event needs a title")
        }
        changes.start = try arguments.dateEdit("start")
        changes.end = try arguments.dateEdit("end")
        changes.calendarTitle = try arguments.optionalString("calendar")
        changes.location = try arguments.stringEdit("location")
        changes.notes = try arguments.stringEdit("notes")
        changes.url = try arguments.stringEdit("url")
        changes.alarmOffsetsMinutes = try arguments.alarmEdit("alarms")

        let existing = try await requireEditable(id)
        guard !changes.isEmpty else { throw ToolError.nothingToUpdate }

        // Checked against the values that will actually apply, so moving only the start
        // past an unchanged end is caught.
        let resultingStart = if case .set(let value) = changes.start { value } else { existing.start }
        let resultingEnd = if case .set(let value) = changes.end { value } else { existing.end }
        guard resultingEnd > resultingStart else { throw ToolError.endBeforeStart }

        let updated = try await store.update(id: id, changes: changes, span: span)
        return format.updated(updated, fields: changes.changedFields, span: span)
    }

    private func delete(_ arguments: Arguments) async throws -> String {
        let id = EventID.decode(try arguments.requiredString("id"))
        let span = try arguments.span()
        let confirmed = try arguments.bool("confirm")
        _ = try await requireEditable(id)

        guard confirmed else {
            throw ToolError.confirmationRequired(action: "Deleting an event")
        }
        let removed = try await store.delete(id: id, span: span)
        return ToolStandard.fitting(Configuration.deletedRecordCharacters) {
            format.deleted(removed, span: span, maxCharacters: $0)
        }
    }

    /// Loads the event and checks the one thing that still gates a write: the calendar
    /// it lives in has to accept writes at all.
    private func requireEditable(_ id: EventID) async throws -> EventDetail {
        guard let event = try await store.fetch(id: id) else {
            throw ToolError.notFound(id: id.encoded)
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

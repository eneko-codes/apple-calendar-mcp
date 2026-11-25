import Foundation

/// Plain-text rendering of every tool result. Pure: it is handed finished values and reads
/// nothing from the calendar.
public struct Format: Sendable {
    let calendar: Calendar

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    // MARK: Helpers

    static func pad(_ text: String, to width: Int) -> String {
        let shortfall = width - text.count
        return shortfall > 0 ? text + String(repeating: " ", count: shortfall) : text
    }

    /// The widest a padded column gets. One calendar with a very long name must not make
    /// every other row of the page that wide.
    static let widestColumn = 40

    static func block(_ rows: [(String, String?)]) -> String {
        let present = rows.compactMap { label, value -> (String, String)? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (label, value)
        }
        guard let width = present.map(\.0.count).max() else { return "" }
        let indent = String(repeating: " ", count: width + 3)
        return present.map { label, value in
            let wrapped = value.split(separator: "\n", omittingEmptySubsequences: false)
                .joined(separator: "\n" + indent)
            return "  \(pad(label, to: width)) \(wrapped)"
        }.joined(separator: "\n")
    }

    static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// `09:00–10:30`, or `all day` when the event has no meaningful clock time.
    func span(start: Date, end: Date, isAllDay: Bool) -> String {
        guard !isAllDay else { return "all day" }
        return DateParsing.time(start, calendar: calendar) + "–"
            + DateParsing.time(end, calendar: calendar)
    }

    /// `Wed 12 Aug 2026, 16:00–16:30 · Europe/Madrid`, or the day and `all day`.
    func when(_ event: EventDetail) -> String {
        guard !event.isAllDay else {
            return "\(DateParsing.dayWithYear(event.start, calendar: calendar)) · all day"
        }
        return "\(DateParsing.dayWithYear(event.start, calendar: calendar)), "
            + span(start: event.start, end: event.end, isAllDay: false)
            + " · \(event.timeZoneIdentifier ?? calendar.timeZone.identifier)"
    }

    /// Sorted nearest-to-the-event first, and expressed in the largest unit that still
    /// reads exactly. Observed live: a yearly event carried alarms of 327 and 159 hours,
    /// which are correct but unreadable — those are 13 days 15 hours and 6 days 15 hours.
    static func alarms(_ offsets: [Int]) -> String? {
        guard !offsets.isEmpty else { return nil }
        return offsets.sorted { abs($0) < abs($1) }.map { minutes -> String in
            let magnitude = abs(minutes)
            guard magnitude != 0 else { return "at start" }

            let days = magnitude / 1440
            let hours = (magnitude % 1440) / 60
            let mins = magnitude % 60
            var parts: [String] = []
            if days > 0 { parts.append("\(days)d") }
            if hours > 0 { parts.append("\(hours)h") }
            if mins > 0 || parts.isEmpty { parts.append("\(mins)m") }
            return parts.joined(separator: " ") + (minutes < 0 ? " before" : " after")
        }.joined(separator: ", ")
    }

    /// Collapses a multi-line value onto one line.
    ///
    /// A postal location can contain newlines, which would otherwise break the
    /// one-line-per-result contract that makes a search result scannable.
    static func oneLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// `text` on one line of at most `Configuration.rowFieldWidth` characters. When that
    /// shortens it, `field` joins `clipped`, so the result can say which fields it cut.
    static func brief(_ text: String, _ field: String, _ clipped: inout [String]) -> String {
        let line = oneLine(text)
        guard line.count > Configuration.rowFieldWidth else { return line }
        if !clipped.contains(field) { clipped.append(field) }
        return String(line.prefix(Configuration.rowFieldWidth)) + "…"
    }

    /// The sentence for each field `brief` shortened, naming the tool that has the rest.
    static func clipNotices(_ fields: [String]) -> [String] {
        fields.map {
            Notice.clipped(field: $0, width: Configuration.rowFieldWidth, tool: ToolCatalog.getName)
        }
    }

    /// What an empty page says: nothing matched, or the offset skipped everything.
    static func nothing(_ none: String, matching: Int) -> String {
        matching == 0 ? none : "(nothing at this offset)"
    }

    /// Rough, deliberately. "ended 6 days ago" is what the reader needs; the exact
    /// timestamp is on the line above it.
    func elapsed(since date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<0: return "in the future"
        case 0..<3600: return "\(max(seconds / 60, 1)) min ago"
        case 3600..<86400: return "\(seconds / 3600) h ago"
        default: return "\(seconds / 86400) days ago"
        }
    }

    // MARK: Calendars

    /// `calendars` is the page to show; `matching` counts every calendar there is.
    public func calendarList(_ calendars: [CalendarInfo], matching: Int) -> String {
        let header =
            "\(Self.plural(matching, "calendar")), ordered by name, then account"
            + " · time zone \(self.calendar.timeZone.identifier)"
        guard !calendars.isEmpty else {
            return header + "\n" + Self.nothing("No calendars found.", matching: matching)
        }
        let rows = calendars.map { (title: Self.oneLine($0.title), source: Self.oneLine($0.sourceName), entry: $0) }
        let titleWidth = min(rows.map(\.title.count).max() ?? 0, Self.widestColumn)
        let sourceWidth = min(rows.map(\.source.count).max() ?? 0, Self.widestColumn)

        var lines = [header]
        for row in rows {
            var line = Self.pad(row.title, to: titleWidth)
            line += "  " + Self.pad(row.source, to: sourceWidth)
            line += "  " + (row.entry.isWritable ? "writable " : "read-only")
            if row.entry.isDefaultForNewEvents { line += "  (default)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Search

    /// `events` is the page to show. `summary` says how many matched and `range` what was
    /// searched, both worded by the caller, which knows whether the scan finished.
    /// `rangeStart` marks an event that began before it as ongoing.
    public func searchResults(
        _ events: [EventSummary], summary: String, range: String, calendarTitles: [String],
        rangeStart: Date, whenEmpty: String
    ) -> (text: String, clippedFields: [String]) {
        let scope = calendarTitles.isEmpty ? "all" : ToolError.few(calendarTitles)
        // The range and zone are echoed so a model can catch its own off-by-one-day
        // before the reader has to.
        let header =
            "\(summary) · \(range) · \(calendar.timeZone.identifier) · calendars: \(scope)"
            + " · ordered by start"

        guard !events.isEmpty else { return (header + "\n" + whenEmpty, []) }

        let spanWidth =
            events.map { span(start: $0.start, end: $0.end, isAllDay: $0.isAllDay).count }
            .max() ?? 0

        var clipped: [String] = []
        var lines = [header]
        for event in events {
            // The year is on every row: a search can run across several.
            var line = DateParsing.dayWithYear(event.start, calendar: calendar)
            line += "  "
                + Self.pad(
                    span(start: event.start, end: event.end, isAllDay: event.isAllDay),
                    to: spanWidth)
            line += "  " + Self.brief(event.title, "Title", &clipped)
            line += "  [\(Self.brief(event.calendarTitle, "Calendar", &clipped))]"
            if let location = event.location, !location.isEmpty {
                line += "  " + Self.brief(location, "Location", &clipped)
            }
            if event.isRecurring { line += "  series" }
            // An event that began before the searched range shows a start date outside
            // it, which reads as a bug. Observed live on a season-long all-day event.
            if event.start < rangeStart { line += "  ongoing" }
            lines.append(line + "  id=\(event.id.encoded)")
        }
        return (lines.joined(separator: "\n"), clipped)
    }

    // MARK: One event

    /// The whole record of one event as text. `attendees` is the page of them to list, in
    /// the order the caller sorted them; `event.attendees` holds all of them. The caller windows this text, so nothing in it is shortened:
    /// what tends to be long comes last, and the facts that identify the event first.
    public func detail(
        _ event: EventDetail, attendees: [Attendee], now: Date
    ) -> String {
        let state: String
        if event.hasEnded(asOf: now) {
            state = "ended \(elapsed(since: event.end, now: now))"
        } else if event.start <= now {
            state = "in progress"
        } else {
            state = "upcoming"
        }

        var rows: [(String, String?)] = [
            ("when", when(event)),
            (
                "calendar",
                event.calendarTitle + (event.calendarIsWritable ? "" : " (read-only)")
            ),
            ("state", state),
            ("id", event.id.encoded),
            ("alarms", Self.alarms(event.alarmOffsetsMinutes)),
            ("repeats", event.isRecurring ? (event.recurrenceSummary ?? "yes") : nil),
            ("location", event.location),
            ("url", event.url),
        ]
        if !event.attendees.isEmpty {
            let listed = attendees.isEmpty
                ? ["(nothing at this offset)"] : attendees.map { "\(Self.oneLine($0.name)) (\($0.status))" }
            rows.append(
                (
                    "attendees",
                    (["\(event.attendees.count), ordered by name · read-only: EventKit cannot invite"]
                        + listed).joined(separator: "\n")
                ))
        }
        rows.append(("notes", event.notes))

        return Self.oneLine(event.title) + "\n" + Self.block(rows)
    }

    // MARK: Writes

    /// What a write answers with: the few lines that find the event again, never the whole
    /// record. An update can change the id of an occurrence, so the id is always the
    /// stored one.
    private func receipt(_ headline: (_ title: String, _ calendarTitle: String) -> String, _ event: EventDetail, warning: String? = nil)
        -> String
    {
        var clipped: [String] = []
        let title = Self.brief(event.title, "Title", &clipped)
        let calendarTitle = Self.brief(event.calendarTitle, "Calendar", &clipped)
        var text = headline(title, calendarTitle) + "\n"
        text += Self.block([("when", when(event)), ("id", event.id.encoded)])
        if let warning { text += "\n\n" + warning }
        text += "\n\n\(ToolCatalog.getName) returns the full record."
        return ToolStandard.withNotices(Self.clipNotices(clipped), text)
    }

    public func created(_ event: EventDetail, now: Date) -> String {
        receipt(
            { "Created event '\($0)' in \($1)." }, event,
            // Allowed on purpose — recording something after the fact is legitimate —
            // but never silently.
            warning: event.hasEnded(asOf: now) ? "⚠ This event is in the past." : nil)
    }

    public func updated(_ event: EventDetail, fields: [String], span: EventSpan) -> String {
        let scope = event.isRecurring
            ? (span == .this ? " (this occurrence only)" : " (this and later occurrences)") : ""
        // An update with nothing to change is refused before it reaches the store, so
        // `fields` is never empty here.
        return receipt(
            {
                "Updated event '\($0)' in \($1)\(scope). Fields changed: "
                    + fields.joined(separator: ", ") + "."
            }, event)
    }

    /// The alarms as `create_event` takes them.
    static func alarmArguments(_ offsets: [Int]) -> String? {
        guard !offsets.isEmpty else { return nil }
        return offsets.map { $0 == 0 ? "\"0\"" : "\"\($0)m\"" }.joined(separator: ", ")
    }

    /// The deleted event as the arguments `create_event` takes, each field once.
    static func deletedRecord(_ event: EventDetail, calendar: Calendar) -> String {
        block([
            ("calendar", event.calendarTitle),
            ("title", event.title),
            ("start", DateParsing.roundTrip(event.start, isAllDay: event.isAllDay, calendar: calendar)),
            ("end", DateParsing.roundTrip(event.end, isAllDay: event.isAllDay, calendar: calendar)),
            ("location", event.location),
            ("url", event.url),
            ("alarms", alarmArguments(event.alarmOffsetsMinutes)),
            ("notes", event.notes),
        ])
    }

    /// A delete has to leave behind enough to undo it by hand, and nothing can read the
    /// event afterwards. So the record is returned here, once, up to `maxCharacters`; a
    /// longer one is cut and the result says that the rest is gone.
    public func deleted(_ event: EventDetail, span: EventSpan, maxCharacters: Int) -> String {
        let scope = event.isRecurring
            ? (span == .this ? "this occurrence of " : "this and all later occurrences of ") : ""
        // Shortened without a notice: the record below carries both in full.
        var unused: [String] = []
        let title = Self.brief(event.title, "Title", &unused)
        let calendarTitle = Self.brief(event.calendarTitle, "Calendar", &unused)

        let record = Self.deletedRecord(event, calendar: calendar)
        let shown = ToolStandard.window(of: record, characterOffset: 0, maxCharacters: maxCharacters).text
        var notices: [String] = []
        if shown.count < record.count {
            notices.append(
                "The deleted event's record is \(record.count) characters long and only the first "
                    + "\(shown.count) are below. The rest cannot be read again: the event no longer exists.")
        }

        var text = "Deleted \(scope)'\(title)' from \(calendarTitle). Its id no longer exists: \(event.id.encoded)"
        text += "\n\nIt cannot be restored. \(ToolCatalog.createName) with these arguments makes a new event like it"
        if event.isRecurring {
            // Being explicit beats a recreate call that quietly produces a one-off.
            text += ", a single event and not the recurrence rule"
        }
        if !event.attendees.isEmpty {
            text += ", without its \(Self.plural(event.attendees.count, "attendee")), whom EventKit cannot invite"
        }
        text += ":\n\n" + shown
        return ToolStandard.withNotices(notices, text)
    }

    // MARK: Status

    public func status(_ authorization: CalendarAuthorization, binaryPath: String) -> String {
        let headline: String
        switch authorization {
        case .fullAccess: headline = "Calendar permission: GRANTED (full access)."
        case .writeOnly: headline = "Calendar permission: WRITE-ONLY, which is not enough."
        case .denied: headline = "Calendar permission: DENIED."
        case .restricted: headline = "Calendar permission: RESTRICTED by system policy."
        case .notDetermined: headline = "Calendar permission: not requested yet."
        }

        var text = headline + "\n\n"
        // Fixed limits, listed so they don't have to be found in the README or the
        // source. Every calendar is reachable; these are the sizes a result keeps to.
        text += Self.block([
            ("binary", binaryPath),
            ("time zone", calendar.timeZone.identifier),
            ("process", "pid \(ProcessInfo.processInfo.processIdentifier)"),
            (
                "search page",
                "\(Configuration.defaultSearchLimit) events by default, \(Configuration.searchLimitRange.upperBound) at most"
            ),
            ("search reach", "\(Configuration.longestScanDays) days in one call"),
            (
                "event record",
                "\(Configuration.defaultMaxCharacters) characters by default, \(Configuration.maxCharactersRange.upperBound) at most"
            ),
            ("call deadline", "\(Configuration.callTimeout.components.seconds) seconds"),
        ])
        if authorization != .fullAccess {
            text += "\n\n" + ToolError.authorizationMessage(authorization)
        }
        return text
    }
}

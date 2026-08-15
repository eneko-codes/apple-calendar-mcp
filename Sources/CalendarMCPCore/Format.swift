import Foundation

/// Plain-text rendering of every tool result.
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

    /// `09:00–10:30`, or `all day` when the event has no meaningful clock time.
    func span(start: Date, end: Date, isAllDay: Bool) -> String {
        guard !isAllDay else { return "all day" }
        return DateParsing.time(start, calendar: calendar) + "–"
            + DateParsing.time(end, calendar: calendar)
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

    // MARK: Tools

    public func calendarList(_ calendars: [CalendarInfo]) -> String {
        guard !calendars.isEmpty else { return "No calendars found." }
        let titleWidth = calendars.map(\.title.count).max() ?? 0
        let sourceWidth = calendars.map(\.sourceName.count).max() ?? 0

        var lines = [
            "\(calendars.count) calendar\(calendars.count == 1 ? "" : "s") · time zone \(self.calendar.timeZone.identifier)"
        ]
        for entry in calendars {
            var line = Self.pad(entry.title, to: titleWidth)
            line += "  " + Self.pad(entry.sourceName, to: sourceWidth)
            line += "  " + (entry.isWritable ? "writable " : "read-only")
            if entry.isDefaultForNewEvents { line += "  (default)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    public func searchResults(
        _ page: EventSearchPage, from: Date, to: Date, calendarTitles: [String], offset: Int
    ) -> String {
        let scope = calendarTitles.isEmpty ? "all" : calendarTitles.joined(separator: ", ")
        // The range and zone are echoed so a model can catch its own off-by-one-day
        // before the reader has to.
        let header =
            "\(page.total) event\(page.total == 1 ? "" : "s") · "
            + "\(DateParsing.roundTrip(from, isAllDay: true, calendar: calendar)) → "
            + "\(DateParsing.roundTrip(to, isAllDay: true, calendar: calendar)) · "
            + "\(calendar.timeZone.identifier) · calendars: \(scope)"

        guard !page.results.isEmpty else { return header + "\nNo events in this range." }

        let dayWidth = page.results.map { DateParsing.day($0.start, calendar: calendar).count }.max() ?? 0
        let spanWidth =
            page.results.map { span(start: $0.start, end: $0.end, isAllDay: $0.isAllDay).count }
            .max() ?? 0
        let titleWidth = page.results.map(\.title.count).max() ?? 0

        var lines = [header]
        for event in page.results {
            var line = Self.pad(DateParsing.day(event.start, calendar: calendar), to: dayWidth)
            line += "  "
                + Self.pad(
                    span(start: event.start, end: event.end, isAllDay: event.isAllDay),
                    to: spanWidth)
            line += "  " + Self.pad(event.title, to: titleWidth)
            line += "  [\(event.calendarTitle)]"
            if let location = event.location, !location.isEmpty {
                line += "  " + Self.oneLine(location)
            }
            if event.isRecurring { line += "  series" }
            // An event that began before the searched range shows a start date outside
            // it, which reads as a bug. Observed live on a season-long all-day event.
            if event.start < from { line += "  ongoing" }
            lines.append(line + "  id=\(event.id.encoded)")
        }

        let shown = offset + page.results.count
        if shown < page.total {
            lines.append("…\(page.total - shown) more · call again with offset=\(shown)")
        }
        return lines.joined(separator: "\n")
    }

    public func detail(_ event: EventDetail, now: Date) -> String {
        let when: String
        if event.isAllDay {
            when = "\(DateParsing.dayWithYear(event.start, calendar: calendar)) · all day"
        } else {
            when =
                "\(DateParsing.dayWithYear(event.start, calendar: calendar)), "
                + span(start: event.start, end: event.end, isAllDay: false)
                + " · \(event.timeZoneIdentifier ?? calendar.timeZone.identifier)"
        }

        // Stated up front so a caller knows whether a write will be accepted without
        // having to attempt one and read the refusal.
        let state: String
        if event.hasEnded(asOf: now) {
            state = "ended \(elapsed(since: event.end, now: now)) · NOT editable"
        } else if event.start <= now {
            state = "in progress · editable"
        } else {
            state = "upcoming · editable"
        }

        var rows: [(String, String?)] = [
            ("when", when),
            (
                "calendar",
                event.calendarTitle + (event.calendarIsWritable ? "" : " (read-only)")
            ),
            ("location", event.location),
            ("alarms", Self.alarms(event.alarmOffsetsMinutes)),
            ("repeats", event.isRecurring ? (event.recurrenceSummary ?? "yes") : nil),
        ]
        if !event.attendees.isEmpty {
            rows.append(
                (
                    "attendees",
                    event.attendees.map { "\($0.name) (\($0.status))" }.joined(separator: " · ")
                        + "   ← read-only: EventKit cannot invite"
                ))
        }
        rows.append(("url", event.url))
        rows.append(("notes", event.notes))
        rows.append(("id", event.id.encoded))
        rows.append(("state", state))

        return event.title + "\n" + Self.block(rows)
    }

    public func created(_ event: EventDetail, now: Date) -> String {
        var text = "Created event '\(event.title)'."
        if event.hasEnded(asOf: now) {
            // Allowed on purpose — recording something after the fact is legitimate —
            // but never silently.
            text += "\n\n⚠ This event is in the past."
        }
        return text + "\n\n" + detail(event, now: now)
    }

    public func updated(_ event: EventDetail, fields: [String], span: EventSpan, now: Date)
        -> String
    {
        let scope = event.isRecurring
            ? (span == .this ? " (this occurrence only)" : " (this and later occurrences)") : ""
        // An update with nothing to change is refused before it reaches the store, so
        // `fields` is never empty here.
        return "Updated event '\(event.title)'\(scope). Fields changed: "
            + fields.joined(separator: ", ") + ".\n\n" + detail(event, now: now)
    }

    /// A delete has to leave behind enough to undo it by hand.
    public func deleted(_ event: EventDetail, span: EventSpan) -> String {
        let scope = event.isRecurring
            ? (span == .this ? "this occurrence of " : "this and all later occurrences of ") : ""
        var text = "Deleted \(scope)'\(event.title)' from \(event.calendarTitle).\n\n"
        text += Self.block([
            ("title", event.title),
            (
                "when",
                "\(DateParsing.dayWithYear(event.start, calendar: calendar)) · "
                    + self.span(start: event.start, end: event.end, isAllDay: event.isAllDay)
            ),
            ("location", event.location),
            ("notes", event.notes),
            ("id", "\(event.id.encoded) (no longer exists)"),
        ])

        var arguments = [
            "calendar=\"\(event.calendarTitle)\"",
            "title=\"\(event.title)\"",
            "start=\"\(DateParsing.roundTrip(event.start, isAllDay: event.isAllDay, calendar: calendar))\"",
            "end=\"\(DateParsing.roundTrip(event.end, isAllDay: event.isAllDay, calendar: calendar))\"",
        ]
        if let location = event.location, !location.isEmpty {
            arguments.append("location=\"\(location)\"")
        }
        if let notes = event.notes, !notes.isEmpty {
            arguments.append("notes=\"\(notes.replacingOccurrences(of: "\n", with: "\\n"))\"")
        }
        text += "\n\nTo recreate it:\n  create_event(\(arguments.joined(separator: ", ")))"

        if event.isRecurring {
            // Being explicit beats a recreate call that quietly produces a one-off.
            text += "\n\nNote: this was part of a repeating series. The call above recreates a"
            text += "\nsingle event, not the recurrence rule."
        }
        return text
    }


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
        // source: every calendar is reachable, and only these two numbers are worth
        // stating plainly.
        text += Self.block([
            ("binary", binaryPath),
            ("time zone", calendar.timeZone.identifier),
            ("process", "pid \(ProcessInfo.processInfo.processIdentifier)"),
            ("max search range", "\(Configuration.maximumRangeDays) days"),
            ("default results", "\(Configuration.searchLimit)"),
        ])
        if authorization != .fullAccess {
            text += "\n\n" + ToolError.authorizationMessage(authorization)
        }
        return text
    }
}

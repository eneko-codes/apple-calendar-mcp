import Foundation

public enum CalendarAuthorization: Sendable, Equatable {
    case notDetermined
    case restricted
    case denied
    /// macOS 14+. Can create events but cannot read them back, so it is not enough for
    /// this server: every write here confirms itself by re-reading.
    case writeOnly
    case fullAccess

    public var isUsable: Bool { self == .fullAccess }
}

public enum ToolError: Error, Equatable {
    case notAuthorized(CalendarAuthorization)
    case missingArgument(String)
    case badArgument(name: String, reason: String)
    case unknownTool(String)
    case unknownArgument(name: String, tool: String, taken: [String])
    case badDate(argument: String, value: String)
    case nonexistentDate(argument: String, value: String)
    case alarmTooFar
    case rangeEndsBeforeItStarts
    case endBeforeStart
    case notFound(id: String)
    case calendarNotFound(title: String, available: [String])
    case calendarReadOnly(title: String)
    case cannotMoveRecurringEvent(title: String)
    case confirmationRequired(action: String)
    case nothingToUpdate
    case storeFailure(String)
    case timedOut(seconds: Int)

    /// A list short enough for an error or a header: the first few names, each clipped, and
    /// the number of the others.
    static func few(_ names: [String]) -> String {
        let shown = names.prefix(Configuration.fewNames).map(ToolStandard.echo)
        let others = names.count - shown.count
        return shown.joined(separator: ", ") + (others > 0 ? " and \(others) more" : "")
    }

    public var message: String {
        switch self {
        case .notAuthorized(let status):
            return Self.authorizationMessage(status)

        case .missingArgument(let name):
            return "Missing required argument '\(name)'."

        case .badArgument(let name, let reason):
            return "Argument '\(name)' is not valid: \(reason)"

        case .unknownTool(let name):
            return "'\(ToolStandard.echo(name))' is not a tool of this server."

        case .unknownArgument(let name, let tool, let taken):
            let list = taken.isEmpty ? "It takes no arguments." : "It takes: \(taken.joined(separator: ", "))."
            return "'\(ToolStandard.echo(name))' is not an argument of \(tool). \(list)"

        case .badDate(let argument, let value):
            return """
                Argument '\(argument)' is not a date this server accepts: '\(ToolStandard.echo(value))'

                Use one of:
                \(DateParsing.acceptedForms)

                Both start and end given as a plain day makes an all-day event.
                """

        case .nonexistentDate(let argument, let value):
            return """
                Argument '\(argument)' names a day or a time that does not exist: '\(ToolStandard.echo(value))'

                Check the day of the month, and that the time is not one the clocks skip when
                they go forward. Nothing was moved to a nearby date.
                """

        case .alarmTooFar:
            let days = Configuration.alarmMinutesRange.upperBound / 1440
            return """
                Argument 'alarms' is not valid: an alarm must be within \(days) days of the \
                start, as "-15m", "-1h", "-1d" or "0".
                """

        case .rangeEndsBeforeItStarts:
            return """
                'to_date' is before 'from_date'. Pass a range that starts before it ends, for \
                example from_date=2026-08-01 and to_date=2026-08-31; both days are included.
                """

        case .endBeforeStart:
            return "'end' is before 'start'. An event cannot finish before it begins."

        case .notFound(let id):
            return """
                No event exists with id '\(ToolStandard.echo(id))'.

                Event identifiers change when an account is resynchronised, and an
                occurrence id also encodes its start time. Find it again with
                calendar_search rather than reusing an earlier id.
                """

        case .calendarNotFound(let title, let available):
            let list = available.isEmpty ? "(none writable)" : Self.few(available)
            return """
                No calendar named '\(ToolStandard.echo(title))'.

                Writable calendars: \(list)

                Call calendars_list for every calendar, including read-only ones.
                """

        case .calendarReadOnly(let title):
            return """
                Calendar '\(ToolStandard.echo(title))' is read-only, so nothing can be written to it.

                Subscribed and holiday calendars are read-only by nature. Call
                calendars_list to see which ones accept writes.
                """

        case .cannotMoveRecurringEvent(let title):
            return """
                Cannot move '\(ToolStandard.echo(title))' to another calendar: it is part of a recurring series.

                EventKit has no concept of one occurrence living in a different calendar
                from the rest of the series, so a recurring event's calendar is not
                changed here at all — not this occurrence, not the whole series. Move it
                from Calendar.app.
                """

        case .confirmationRequired(let action):
            return """
                \(action) requires confirm=true.

                This is destructive. Call again with confirm=true only if you really mean
                to delete it.
                """

        case .nothingToUpdate:
            return """
                No field to change was given.

                Pass a field with a value to set it, "" to empty location, notes or url,
                or [] to remove every alarm. Omitting a field leaves it untouched.
                """

        case .storeFailure(let detail):
            // EventKit's own wording, which this server does not control the length of.
            let shown = detail.count > Configuration.storeFailureWidth
                ? String(detail.prefix(Configuration.storeFailureWidth)) + "…" : detail
            return "Calendar returned an error: \(shown)"

        case .timedOut(let seconds):
            return """
                The call did not finish within \(seconds) seconds and was abandoned.

                If macOS is showing a dialog asking for access to Calendar, answer it and \
                call again. A search can be narrowed with from_date and to_date. A write \
                that was abandoned may still go through: look the event up with \
                calendar_search before trying it again.
                """
        }
    }

    static func authorizationMessage(_ status: CalendarAuthorization) -> String {
        switch status {
        case .fullAccess:
            return "Calendar access granted (full)."

        case .notDetermined:
            return """
                No Calendar access: macOS has not asked yet.

                Restart Claude Desktop and call this tool again; the consent dialog should
                appear.

                If it does not, check that the binary still carries its embedded Info.plist:
                  otool -P .build/release/apple-calendar-mcp | grep NSCalendars
                """

        case .denied:
            return """
                No Calendar access: it is denied.

                Grant it in:
                  System Settings → Privacy & Security → Calendars → enable "apple-calendar-mcp"
                  (Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Calendarios)

                Then restart Claude Desktop: the permission is resolved when the process
                starts.
                """

        case .writeOnly:
            return """
                Only write-only Calendar access was granted, which is not enough.

                macOS 14 split the permission in two. Write-only can add events but cannot
                read them back, so this server could not confirm what it created.

                Grant full access in:
                  System Settings → Privacy & Security → Calendars → enable "apple-calendar-mcp"
                  (Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Calendarios)
                """

        case .restricted:
            return """
                No Calendar access: restricted by a system policy (parental controls or a
                device management profile).

                This cannot be granted from System Settings; the policy imposing it has to
                be lifted.
                """
        }
    }
}

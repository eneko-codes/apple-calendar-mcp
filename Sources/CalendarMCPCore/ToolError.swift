import Foundation

public enum CalendarAuthorization: Sendable, Equatable {
    case notDetermined
    case restricted
    case denied
    /// macOS 14+. Can create events but cannot read them back, so it is not enough for
    /// this server: every write here confirms itself by re-reading, and the
    /// "never edit a past event" rule needs to see the event first.
    case writeOnly
    case fullAccess

    public var isUsable: Bool { self == .fullAccess }
}

public enum ToolError: Error, Equatable {
    case notAuthorized(CalendarAuthorization)
    case missingArgument(String)
    case badArgument(name: String, reason: String)
    case badDate(argument: String, value: String)
    case rangeTooLong(days: Int, maximum: Int)
    case endBeforeStart
    case notFound(id: String)
    case calendarNotFound(title: String, available: [String])
    case calendarReadOnly(title: String)
    case eventHasEnded(title: String, ended: String)
    case confirmationRequired(action: String)
    case nothingToUpdate
    case storeFailure(String)

    public var message: String {
        switch self {
        case .notAuthorized(let status):
            return Self.authorizationMessage(status)

        case .missingArgument(let name):
            return "Missing required argument '\(name)'."

        case .badArgument(let name, let reason):
            return "Argument '\(name)' is not valid: \(reason)"

        case .badDate(let argument, let value):
            return """
                Argument '\(argument)' is not a date this server accepts: '\(value)'

                Use one of:
                \(DateParsing.acceptedForms)

                Both start and end given as a plain day makes an all-day event.
                """

        case .rangeTooLong(let days, let maximum):
            return """
                The requested range spans \(days) days; the maximum is \(maximum).

                EventKit degrades badly over long spans, and a mistyped range can sweep a
                decade. Narrow 'from' and 'to', and page with 'offset' if needed.
                """

        case .endBeforeStart:
            return "'end' is before 'start'. An event cannot finish before it begins."

        case .notFound(let id):
            return """
                No event exists with id '\(id)'.

                Event identifiers change when an account is resynchronised, and an
                occurrence id also encodes its start time. Find it again with
                calendar_search rather than reusing an earlier id.
                """

        case .calendarNotFound(let title, let available):
            let list = available.isEmpty ? "(none writable)" : available.joined(separator: ", ")
            return """
                No calendar named '\(title)'.

                Writable calendars: \(list)

                Call calendars_list for the full picture, including read-only ones.
                """

        case .calendarReadOnly(let title):
            return """
                Calendar '\(title)' is read-only, so nothing can be written to it.

                Subscribed and holiday calendars are read-only by nature. Call
                calendars_list to see which ones accept writes.
                """

        case .eventHasEnded(let title, let ended):
            return """
                Cannot modify an event that has already ended.

                  \(title) · ended \(ended)

                Finished events are the record of what happened, and this server does not
                edit them even with permission. If the change needs recording, create a
                new event.

                An event still in progress can be edited: the rule turns on the end time,
                not the start.
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
            return "Calendar returned an error: \(detail)"
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
                read them back, so this server could neither confirm what it created nor
                enforce its rule against editing past events.

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

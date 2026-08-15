import Foundation

/// Addresses one event, and — when it belongs to a repeating series — one occurrence
/// of it.
///
/// EventKit gives every occurrence of a series the **same** `eventIdentifier`, so an
/// identifier alone cannot say which Tuesday the caller meant. The occurrence start is
/// appended to close that gap.
///
/// The separator is `|` rather than `:` because a CalDAV `eventIdentifier` can itself
/// contain a colon, which would make the split ambiguous.
public struct EventID: Sendable, Equatable, Hashable {
    public static let separator: Character = "|"

    public let seriesIdentifier: String
    /// nil for a one-off event, or when the caller addressed the series as a whole.
    public let occurrenceStart: Date?

    public init(seriesIdentifier: String, occurrenceStart: Date? = nil) {
        self.seriesIdentifier = seriesIdentifier
        self.occurrenceStart = occurrenceStart
    }

    /// UTC with seconds, so an encoded id does not shift meaning when the machine's
    /// time zone changes between the search that produced it and the call that uses it.
    ///
    /// Computed, not stored: `ISO8601DateFormatter` is not Sendable, and Swift 6 rejects
    /// a static `let` of one as shared mutable global state.
    static var occurrenceFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    public var encoded: String {
        guard let occurrenceStart else { return seriesIdentifier }
        return seriesIdentifier + String(Self.separator)
            + Self.occurrenceFormatter.string(from: occurrenceStart)
    }

    public static func decode(_ raw: String) -> EventID {
        // rsplit: only the last separator is the boundary, because the series
        // identifier may legitimately contain one.
        guard let index = raw.lastIndex(of: separator) else {
            return EventID(seriesIdentifier: raw)
        }
        let tail = String(raw[raw.index(after: index)...])
        guard let start = occurrenceFormatter.date(from: tail) else {
            // Not a timestamp, so the separator was part of the identifier itself.
            return EventID(seriesIdentifier: raw)
        }
        return EventID(seriesIdentifier: String(raw[..<index]), occurrenceStart: start)
    }
}

/// Which part of a repeating series a write applies to. Mirrors `EKSpan`.
public enum EventSpan: String, Sendable, Equatable, CaseIterable {
    case this
    case future
}

public struct CalendarInfo: Sendable, Equatable {
    public let title: String
    public let sourceName: String
    public let isWritable: Bool
    public let isDefaultForNewEvents: Bool

    public init(
        title: String, sourceName: String, isWritable: Bool, isDefaultForNewEvents: Bool
    ) {
        self.title = title
        self.sourceName = sourceName
        self.isWritable = isWritable
        self.isDefaultForNewEvents = isDefaultForNewEvents
    }
}

public struct EventSummary: Sendable, Equatable {
    public let id: EventID
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let calendarTitle: String
    public let location: String?
    public let isRecurring: Bool

    public init(
        id: EventID, title: String, start: Date, end: Date, isAllDay: Bool,
        calendarTitle: String, location: String?, isRecurring: Bool
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarTitle = calendarTitle
        self.location = location
        self.isRecurring = isRecurring
    }
}

public struct Attendee: Sendable, Equatable {
    public let name: String
    public let status: String

    public init(name: String, status: String) {
        self.name = name
        self.status = status
    }
}

public struct EventDetail: Sendable, Equatable {
    public let id: EventID
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let calendarTitle: String
    public let calendarIsWritable: Bool
    public let location: String?
    public let notes: String?
    public let url: String?
    /// Minutes before the start, negative for "before". EventKit also allows absolute
    /// alarms; those are surfaced as their offset from the start.
    public let alarmOffsetsMinutes: [Int]
    public let isRecurring: Bool
    public let recurrenceSummary: String?
    /// Read-only. EventKit cannot add or modify participants, so this is reported and
    /// never written.
    public let attendees: [Attendee]
    public let timeZoneIdentifier: String?

    public init(
        id: EventID, title: String, start: Date, end: Date, isAllDay: Bool,
        calendarTitle: String, calendarIsWritable: Bool, location: String?, notes: String?,
        url: String?, alarmOffsetsMinutes: [Int], isRecurring: Bool,
        recurrenceSummary: String?, attendees: [Attendee], timeZoneIdentifier: String?
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarTitle = calendarTitle
        self.calendarIsWritable = calendarIsWritable
        self.location = location
        self.notes = notes
        self.url = url
        self.alarmOffsetsMinutes = alarmOffsetsMinutes
        self.isRecurring = isRecurring
        self.recurrenceSummary = recurrenceSummary
        self.attendees = attendees
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    /// The boundary the "history is not editable" rule turns on.
    ///
    /// It is the **end**, not the start: an event that is running right now has not
    /// happened yet in any useful sense, and extending a meeting that is overrunning is
    /// a real thing people need to do.
    public func hasEnded(asOf now: Date) -> Bool { end <= now }
}

/// See `FieldEdit` for why an omitted field and an explicit null must not collapse.
public enum FieldEdit<Value: Sendable & Equatable>: Sendable, Equatable {
    case unchanged
    case cleared
    case set(Value)
}

public struct EventDraft: Sendable, Equatable {
    public var calendarTitle: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    public var url: String?
    public var alarmOffsetsMinutes: [Int]

    public init(
        calendarTitle: String, title: String, start: Date, end: Date, isAllDay: Bool,
        location: String? = nil, notes: String? = nil, url: String? = nil,
        alarmOffsetsMinutes: [Int] = []
    ) {
        self.calendarTitle = calendarTitle
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.url = url
        self.alarmOffsetsMinutes = alarmOffsetsMinutes
    }
}

public struct EventChanges: Sendable, Equatable {
    public var title: FieldEdit<String> = .unchanged
    public var start: FieldEdit<Date> = .unchanged
    public var end: FieldEdit<Date> = .unchanged
    public var location: FieldEdit<String> = .unchanged
    public var notes: FieldEdit<String> = .unchanged
    public var url: FieldEdit<String> = .unchanged
    public var alarmOffsetsMinutes: FieldEdit<[Int]> = .unchanged

    public init() {}

    /// The argument names of the fields this edit actually touches, in output order.
    ///
    /// One place pairs a field with the name callers know it by; building that pairing at
    /// the call site meant writing the name twice per field, where a mismatch compiles
    /// cleanly and only shows up as a confirmation that under-reports what changed.
    public var changedFields: [String] {
        var names: [String] = []
        if title != .unchanged { names.append("title") }
        if start != .unchanged { names.append("start") }
        if end != .unchanged { names.append("end") }
        if location != .unchanged { names.append("location") }
        if notes != .unchanged { names.append("notes") }
        if url != .unchanged { names.append("url") }
        if alarmOffsetsMinutes != .unchanged { names.append("alarms") }
        return names
    }

    public var isEmpty: Bool { changedFields.isEmpty }
}

public struct EventSearchPage: Sendable, Equatable {
    public let results: [EventSummary]
    /// Total matches, not the number returned, so the formatter can say what it withheld.
    public let total: Int

    public init(results: [EventSummary], total: Int) {
        self.results = results
        self.total = total
    }
}

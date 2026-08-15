import Foundation

@testable import CalendarMCPCore

/// In-memory `EventStore` for the tests.
///
/// Every fixture here is invented. The test suite must never reach a real calendar:
/// see the hard rule in CLAUDE.md.
final class FakeEventStore: EventStore, @unchecked Sendable {
    var status: CalendarAuthorization
    var calendarList: [CalendarInfo]
    var events: [EventDetail]
    private(set) var deleted: [(id: EventID, span: EventSpan)] = []
    private(set) var updated: [(id: EventID, span: EventSpan)] = []
    private(set) var accessRequests = 0

    init(
        status: CalendarAuthorization = .fullAccess,
        calendars: [CalendarInfo] = Fixtures.calendars,
        events: [EventDetail] = Fixtures.events
    ) {
        self.status = status
        self.calendarList = calendars
        self.events = events
    }

    func authorization() -> CalendarAuthorization { status }

    @discardableResult
    func requestAccess() async -> CalendarAuthorization {
        accessRequests += 1
        if status == .notDetermined { status = .fullAccess }
        return status
    }

    func calendars() async throws -> [CalendarInfo] { calendarList }

    func search(
        query: String?, from: Date, to: Date, calendarTitles: [String], limit: Int, offset: Int
    ) async throws -> EventSearchPage {
        var matches = events.filter { $0.start >= from && $0.start < to }
        if !calendarTitles.isEmpty {
            matches = matches.filter { calendarTitles.contains($0.calendarTitle) }
        }
        if let needle = query, !needle.isEmpty {
            matches = matches.filter {
                $0.title.localizedCaseInsensitiveContains(needle)
                    || ($0.location ?? "").localizedCaseInsensitiveContains(needle)
            }
        }
        matches.sort { $0.start < $1.start }
        let page = matches.dropFirst(offset).prefix(limit).map {
            EventSummary(
                id: $0.id, title: $0.title, start: $0.start, end: $0.end, isAllDay: $0.isAllDay,
                calendarTitle: $0.calendarTitle, location: $0.location,
                isRecurring: $0.isRecurring)
        }
        return EventSearchPage(results: Array(page), total: matches.count)
    }

    func fetch(id: EventID) async throws -> EventDetail? {
        events.first { $0.id == id }
    }

    func create(_ draft: EventDraft) async throws -> EventDetail {
        let created = Fixtures.event(
            id: "created-\(events.count + 1)",
            title: draft.title, start: draft.start, end: draft.end,
            calendarTitle: draft.calendarTitle, isAllDay: draft.isAllDay,
            location: draft.location, notes: draft.notes,
            alarms: draft.alarmOffsetsMinutes)
        events.append(created)
        return created
    }

    func update(id: EventID, changes: EventChanges, span: EventSpan) async throws -> EventDetail {
        guard let index = events.firstIndex(where: { $0.id == id }) else {
            throw ToolError.notFound(id: id.encoded)
        }
        updated.append((id, span))
        let current = events[index]
        func applied<T>(_ edit: FieldEdit<T>, _ fallback: T?) -> T? {
            switch edit {
            case .unchanged: return fallback
            case .cleared: return nil
            case .set(let value): return value
            }
        }
        let next = Fixtures.event(
            id: current.id.seriesIdentifier,
            title: applied(changes.title, current.title) ?? current.title,
            start: applied(changes.start, current.start) ?? current.start,
            end: applied(changes.end, current.end) ?? current.end,
            calendarTitle: current.calendarTitle,
            isAllDay: current.isAllDay,
            location: applied(changes.location, current.location),
            notes: applied(changes.notes, current.notes),
            alarms: applied(changes.alarmOffsetsMinutes, current.alarmOffsetsMinutes) ?? [],
            isRecurring: current.isRecurring,
            occurrenceStart: current.id.occurrenceStart)
        events[index] = next
        return next
    }

    func delete(id: EventID, span: EventSpan) async throws -> EventDetail {
        guard let index = events.firstIndex(where: { $0.id == id }) else {
            throw ToolError.notFound(id: id.encoded)
        }
        deleted.append((id, span))
        return events.remove(at: index)
    }
}

enum Fixtures {
    /// Fixed so "has this ended?" is decided by the fixtures, not by when the suite runs.
    static let timeZone = TimeZone(identifier: "Europe/Madrid")!

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// 2026-08-09 12:00 Europe/Madrid.
    static let now = date(2026, 8, 9, 12, 0)

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0)
        -> Date
    {
        calendar.date(
            from: DateComponents(
                timeZone: timeZone, year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }

    static let calendars: [CalendarInfo] = [
        CalendarInfo(
            title: "Personal", sourceName: "iCloud",
            isWritable: true, isDefaultForNewEvents: true),
        CalendarInfo(
            title: "Work", sourceName: "iCloud", isWritable: true,
            isDefaultForNewEvents: false),
        CalendarInfo(
            title: "Holidays", sourceName: "Subscribed",
            isWritable: false, isDefaultForNewEvents: false),
    ]

    static func event(
        id: String,
        title: String,
        start: Date,
        end: Date,
        calendarTitle: String = "Work",
        calendarIsWritable: Bool = true,
        isAllDay: Bool = false,
        location: String? = nil,
        notes: String? = nil,
        alarms: [Int] = [],
        isRecurring: Bool = false,
        occurrenceStart: Date? = nil,
        attendees: [Attendee] = []
    ) -> EventDetail {
        EventDetail(
            id: EventID(seriesIdentifier: id, occurrenceStart: occurrenceStart),
            title: title, start: start, end: end, isAllDay: isAllDay,
            calendarTitle: calendarTitle, calendarIsWritable: calendarIsWritable,
            location: location, notes: notes, url: nil, alarmOffsetsMinutes: alarms,
            isRecurring: isRecurring,
            recurrenceSummary: isRecurring ? "every week" : nil,
            attendees: attendees, timeZoneIdentifier: timeZone.identifier)
    }

    /// One event in each state the "history is not editable" rule cares about.
    static let events: [EventDetail] = [
        event(
            id: "ev-past", title: "Quarterly review",
            start: date(2026, 8, 3, 9, 0), end: date(2026, 8, 3, 10, 30),
            location: "Room 2", notes: "Prepare Q2 figures.",
            attendees: [Attendee(name: "Aurora Fakeperson", status: "accepted")]),
        event(
            id: "ev-running", title: "Standup",
            start: date(2026, 8, 9, 11, 30), end: date(2026, 8, 9, 12, 30)),
        event(
            id: "ev-future", title: "Dentist",
            start: date(2026, 8, 12, 16, 0), end: date(2026, 8, 12, 16, 30),
            calendarTitle: "Personal", location: "Clinic", alarms: [-60]),
        event(
            id: "ev-series", title: "Weekly sync",
            start: date(2026, 8, 14, 10, 0), end: date(2026, 8, 14, 10, 30),
            isRecurring: true, occurrenceStart: date(2026, 8, 14, 10, 0)),
        event(
            id: "ev-holiday", title: "Public holiday",
            start: date(2026, 8, 15, 0, 0), end: date(2026, 8, 16, 0, 0),
            calendarTitle: "Holidays", calendarIsWritable: false, isAllDay: true),
    ]
}

import EventKit
import Foundation

/// `EventStore` backed by the real calendar database.
///
/// A fresh `EKEventStore` is built per operation. Apple does not document one as safe
/// to share across tasks, and this server answers a handful of human-paced calls a
/// minute — correctness is worth more than the setup it saves.
public struct SystemEventStore: EventStore {
    public init() {}

    // MARK: Authorisation

    public func authorization() -> CalendarAuthorization {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .fullAccess
        case .writeOnly: return .writeOnly
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        // `.authorized` is the pre-macOS-14 spelling of full access, kept as a
        // deprecated alias; it maps to the same thing.
        @unknown default: return .denied
        }
    }

    @discardableResult
    public func requestAccess() async -> CalendarAuthorization {
        let store = EKEventStore()
        _ = try? await store.requestFullAccessToEvents()
        return authorization()
    }

    // MARK: Calendars

    public func calendars() async throws -> [CalendarInfo] {
        let store = EKEventStore()
        let defaultIdentifier = store.defaultCalendarForNewEvents?.calendarIdentifier
        return store.calendars(for: .event)
            .map { calendar in
                CalendarInfo(
                    title: calendar.title,
                    sourceName: calendar.source?.title ?? "unknown",
                    isWritable: calendar.allowsContentModifications,
                    isDefaultForNewEvents: calendar.calendarIdentifier == defaultIdentifier)
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Returns nil for "every calendar", or the matching calendars.
    ///
    /// The empty array is deliberately not a possible return value. EventKit reads an
    /// empty `calendars:` argument as *every* calendar, so a scope that matched nothing
    /// would silently widen into no scope at all. Observed live: a filter naming one
    /// calendar that did not exist returned events from every calendar on the machine.
    /// A restriction that fails open is worse than one that errors.
    private func resolveCalendars(_ titles: [String], in store: EKEventStore) -> ResolvedScope {
        guard !titles.isEmpty else { return .everyCalendar }
        let wanted = Set(titles)
        let matched = store.calendars(for: .event).filter { wanted.contains($0.title) }
        return matched.isEmpty ? .nothingMatched : .calendars(matched)
    }

    enum ResolvedScope {
        case everyCalendar
        case calendars([EKCalendar])
        /// Names were given and none of them exist. Must produce no results, never all.
        case nothingMatched
    }

    // MARK: Reads

    public func search(
        query: String?, from: Date, to: Date, calendarTitles: [String], limit: Int, offset: Int
    ) async throws -> EventSearchPage {
        let store = EKEventStore()

        let calendars: [EKCalendar]?
        switch resolveCalendars(calendarTitles, in: store) {
        case .everyCalendar: calendars = nil
        case .calendars(let list): calendars = list
        // Fail closed: a filter that matched no calendar means no events, not all of them.
        case .nothingMatched: return EventSearchPage(results: [], total: 0)
        }

        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)

        var matches = store.events(matching: predicate)
        if let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines), !needle.isEmpty {
            matches = matches.filter { event in
                [event.title, event.location, event.notes]
                    .compactMap { $0 }
                    .contains { $0.localizedCaseInsensitiveContains(needle) }
            }
        }
        matches.sort { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }

        let page = matches.dropFirst(offset).prefix(limit).map(summary(from:))
        return EventSearchPage(results: Array(page), total: matches.count)
    }

    public func fetch(id: EventID) async throws -> EventDetail? {
        let store = EKEventStore()
        guard let event = locate(id, in: store) else { return nil }
        return detail(from: event)
    }

    /// Resolving an occurrence needs a window search, not a lookup.
    ///
    /// `event(withIdentifier:)` returns *an* event for the series — in practice the next
    /// or first occurrence — so it cannot answer "the one on 14 August". Searching a
    /// narrow window around the recorded start and matching on both identifier and start
    /// date is the only way to land on the intended occurrence.
    private func locate(_ id: EventID, in store: EKEventStore) -> EKEvent? {
        guard let occurrenceStart = id.occurrenceStart else {
            return store.event(withIdentifier: id.seriesIdentifier)
        }
        let predicate = store.predicateForEvents(
            withStart: occurrenceStart.addingTimeInterval(-1),
            end: occurrenceStart.addingTimeInterval(1),
            calendars: nil)
        return store.events(matching: predicate).first {
            $0.eventIdentifier == id.seriesIdentifier
                && abs(($0.startDate ?? .distantPast).timeIntervalSince(occurrenceStart)) < 1
        }
    }

    /// EventKit stores alarm offsets in seconds. Converting in one place keeps `create`
    /// and `update` from ever disagreeing about the unit.
    private static func alarms(_ offsetsInMinutes: [Int]) -> [EKAlarm] {
        offsetsInMinutes.map { EKAlarm(relativeOffset: TimeInterval($0 * 60)) }
    }

    // MARK: Writes

    public func create(_ draft: EventDraft) async throws -> EventDetail {
        let store = EKEventStore()
        guard
            let calendar = store.calendars(for: .event).first(where: {
                $0.title == draft.calendarTitle
            })
        else {
            throw ToolError.calendarNotFound(
                title: draft.calendarTitle,
                available: store.calendars(for: .event).filter(\.allowsContentModifications).map(
                    \.title))
        }

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end
        event.isAllDay = draft.isAllDay
        event.location = draft.location
        event.notes = draft.notes
        event.url = draft.url.flatMap(URL.init(string:))
        Self.alarms(draft.alarmOffsetsMinutes).forEach(event.addAlarm)

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw ToolError.storeFailure(error.localizedDescription)
        }
        return detail(from: event)
    }

    public func update(id: EventID, changes: EventChanges, span: EventSpan) async throws
        -> EventDetail
    {
        let store = EKEventStore()
        guard let event = locate(id, in: store) else { throw ToolError.notFound(id: id.encoded) }

        if case .set(let value) = changes.title { event.title = value }
        if case .set(let value) = changes.start { event.startDate = value }
        if case .set(let value) = changes.end { event.endDate = value }

        switch changes.location {
        case .unchanged: break
        case .cleared: event.location = nil
        case .set(let value): event.location = value
        }
        switch changes.notes {
        case .unchanged: break
        case .cleared: event.notes = nil
        case .set(let value): event.notes = value
        }
        switch changes.url {
        case .unchanged: break
        case .cleared: event.url = nil
        case .set(let value): event.url = URL(string: value)
        }
        switch changes.alarmOffsetsMinutes {
        case .unchanged: break
        case .cleared: event.alarms?.forEach(event.removeAlarm)
        case .set(let offsets):
            event.alarms?.forEach(event.removeAlarm)
            Self.alarms(offsets).forEach(event.addAlarm)
        }

        do {
            try store.save(event, span: span.ekSpan, commit: true)
        } catch {
            throw ToolError.storeFailure(error.localizedDescription)
        }
        return detail(from: event)
    }

    public func delete(id: EventID, span: EventSpan) async throws -> EventDetail {
        let store = EKEventStore()
        guard let event = locate(id, in: store) else { throw ToolError.notFound(id: id.encoded) }

        // Snapshot before removal: afterwards there is nothing left to describe, and a
        // delete that cannot say what it removed is not auditable.
        let snapshot = detail(from: event)
        do {
            try store.remove(event, span: span.ekSpan, commit: true)
        } catch {
            throw ToolError.storeFailure(error.localizedDescription)
        }
        return snapshot
    }

    // MARK: Conversion

    private func identifier(for event: EKEvent) -> EventID {
        let series = event.eventIdentifier ?? ""
        // Only a recurring event needs the occurrence suffix; adding it everywhere would
        // make one-off ids needlessly brittle to a clock change.
        guard event.hasRecurrenceRules, let start = event.startDate else {
            return EventID(seriesIdentifier: series)
        }
        return EventID(seriesIdentifier: series, occurrenceStart: start)
    }

    private func summary(from event: EKEvent) -> EventSummary {
        EventSummary(
            id: identifier(for: event),
            title: event.title ?? "(no title)",
            start: event.startDate ?? .distantPast,
            end: event.endDate ?? .distantPast,
            isAllDay: event.isAllDay,
            calendarTitle: event.calendar?.title ?? "unknown",
            location: event.location,
            isRecurring: event.hasRecurrenceRules)
    }

    /// EventKit alarms are either relative to the start or pinned to an instant. Both
    /// are reported as minutes from the start so the output has one vocabulary.
    private func alarmOffsets(_ event: EKEvent) -> [Int] {
        guard let alarms = event.alarms else { return [] }
        let start = event.startDate
        return alarms.compactMap { alarm -> Int? in
            if let absolute = alarm.absoluteDate, let start {
                return Int(absolute.timeIntervalSince(start) / 60)
            }
            return Int(alarm.relativeOffset / 60)
        }
    }

    private func recurrenceSummary(_ event: EKEvent) -> String? {
        guard let rule = event.recurrenceRules?.first else { return nil }
        let unit: String
        switch rule.frequency {
        case .daily: unit = "day"
        case .weekly: unit = "week"
        case .monthly: unit = "month"
        case .yearly: unit = "year"
        @unknown default: unit = "period"
        }
        var text = rule.interval <= 1 ? "every \(unit)" : "every \(rule.interval) \(unit)s"
        if let end = rule.recurrenceEnd {
            if let until = end.endDate {
                text += " until "
                    + DateParsing.roundTrip(until, isAllDay: true, calendar: .current)
            } else if end.occurrenceCount > 0 {
                text += ", \(end.occurrenceCount) times"
            }
        }
        return text
    }

    private func detail(from event: EKEvent) -> EventDetail {
        EventDetail(
            id: identifier(for: event),
            title: event.title ?? "(no title)",
            start: event.startDate ?? .distantPast,
            end: event.endDate ?? .distantPast,
            isAllDay: event.isAllDay,
            calendarTitle: event.calendar?.title ?? "unknown",
            calendarIsWritable: event.calendar?.allowsContentModifications ?? false,
            location: event.location,
            notes: event.notes,
            url: event.url?.absoluteString,
            alarmOffsetsMinutes: alarmOffsets(event),
            isRecurring: event.hasRecurrenceRules,
            recurrenceSummary: recurrenceSummary(event),
            attendees: (event.attendees ?? []).map {
                Attendee(name: $0.name ?? "(unnamed)", status: $0.participantStatus.label)
            },
            timeZoneIdentifier: event.timeZone?.identifier)
    }
}

extension EventSpan {
    var ekSpan: EKSpan { self == .this ? .thisEvent : .futureEvents }
}

extension EKParticipantStatus {
    var label: String {
        switch self {
        case .accepted: return "accepted"
        case .declined: return "declined"
        case .tentative: return "tentative"
        case .pending: return "no reply"
        case .delegated: return "delegated"
        case .completed: return "completed"
        case .inProcess: return "in process"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }
}

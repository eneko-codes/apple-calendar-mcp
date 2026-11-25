import Foundation

/// The seam between the tool layer and EventKit.
///
/// Everything above this protocol is exercised by the tests against an in-memory
/// double; everything below it can only be verified against a real calendar. Keeping
/// the boundary this thin is what makes the untested surface small enough to check by
/// hand — and it is what lets the suite run without ever opening the owner's calendar.
public protocol EventStore: Sendable {
    func authorization() -> CalendarAuthorization

    @discardableResult
    func requestAccess() async -> CalendarAuthorization

    func calendars() async throws -> [CalendarInfo]

    /// Every event that overlaps `from`–`to`, in no particular order. The caller keeps the
    /// span within `Configuration.scanChunkDays`, orders the events and pages them: EventKit
    /// has no cursor and no order of its own.
    func search(query: String?, from: Date, to: Date, calendarTitles: [String]) async throws
        -> EventScan

    func fetch(id: EventID) async throws -> EventDetail?
    func create(_ draft: EventDraft) async throws -> EventDetail
    func update(id: EventID, changes: EventChanges, span: EventSpan) async throws -> EventDetail

    /// Returns the event as it was immediately before removal, so the caller can
    /// describe precisely what disappeared.
    func delete(id: EventID, span: EventSpan) async throws -> EventDetail
}

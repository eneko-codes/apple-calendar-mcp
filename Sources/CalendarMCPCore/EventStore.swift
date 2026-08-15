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

    /// `offset` indexes into the matches for the range. EventKit has no cursor of its
    /// own, and the range already bounds the result set.
    func search(
        query: String?, from: Date, to: Date, calendarTitles: [String], limit: Int, offset: Int
    ) async throws -> EventSearchPage

    func fetch(id: EventID) async throws -> EventDetail?
    func create(_ draft: EventDraft) async throws -> EventDetail
    func update(id: EventID, changes: EventChanges, span: EventSpan) async throws -> EventDetail

    /// Returns the event as it was immediately before removal, so the caller can
    /// describe precisely what disappeared.
    func delete(id: EventID, span: EventSpan) async throws -> EventDetail
}

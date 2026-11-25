import Foundation

/// Every size this server enforces, in one place: the schemas, the tool descriptions, the
/// instructions and `calendar_status` quote these by interpolation, so what the model reads
/// cannot drift from what the code does.
///
/// None of it is a setting. The owner's plug-and-play rule removed every option from the
/// connector: only the per-tool allow/ask/prohibit switch in Claude Desktop controls this
/// server.
public enum Configuration {

    // Pages. Each maximum is a number of rows of ordinary width that fits
    // `ToolStandard.longestResult` with room to spare, and each default makes a call with
    // no optional argument about `ToolStandard.usualPage` or less. `BoundsTests` renders a
    // full page of the widest ordinary rows of every listing to hold both to that.

    /// A search row carries the event's id, which alone runs to some 95 characters, so a
    /// page holds fewer rows than the other listings.
    public static let searchLimitRange = 1...100
    public static let defaultSearchLimit = 40

    public static let calendarLimitRange = 1...200
    public static let defaultCalendarLimit = 50

    /// The attendees listed inside one `calendar_get` record.
    public static let attendeeLimitRange = 1...200
    public static let defaultAttendeeLimit = 50

    public static let offsetRange = 0...10_000_000

    /// The window `calendar_get` reads an event's record through. The maximum is half the
    /// longest result, so a window of ordinary text fits with its notices;
    /// `ToolStandard.fitting` shrinks one whose characters take more UTF-16 units than that.
    public static let maxCharactersRange = 1...(ToolStandard.longestResult / 2)
    public static let defaultMaxCharacters = ToolStandard.usualPage

    /// How much of a title or a location one search row shows. `calendar_get` has the rest.
    public static let rowFieldWidth = 80

    /// How far from an event's start an alarm may be set: 366 days either side, in minutes.
    /// An offset outside it is refused.
    public static let alarmMinutesRange = -527_040...527_040

    /// How many names an error or a header lists before it counts the others.
    public static let fewNames = 5

    // The search.

    /// The span of one EventKit query. `predicateForEvents(withStart:end:calendars:)`
    /// silently shortens a range longer than four years to its first four (`EKEventStore.h`),
    /// so a longer search is walked in pieces well inside that.
    public static let scanChunkDays = 366

    /// The longest span one `calendar_search` call looks at. Past it the result says where
    /// the scan stopped and the `from_date` that continues from there.
    public static let longestScanDays = 4 * scanChunkDays

    /// How long a search may keep starting new pieces of its range. After that it returns
    /// what it has, marked partial, well before `callTimeout` abandons the call.
    public static let scanBudget = Duration.seconds(15)

    /// How long any call may take before it is abandoned and answered with an error. It
    /// stays under the 60 seconds a client commonly waits, and so under
    /// `ToolStandard.timeLimit`, so the answer is this server's and not the client's
    /// generic "no result".
    public static let callTimeout = Duration.seconds(30)

    /// How much of a deleted event `delete_event` returns. Nothing can read the event
    /// afterwards, so this is as much as one result holds, less room for the lines around it.
    public static let deletedRecordCharacters = ToolStandard.longestResult - 2_000

    /// How much of EventKit's own wording a failed save or removal may repeat.
    public static let storeFailureWidth = 500
}

import Foundation
import MCP
import Testing

@testable import CalendarMCPCore

/// Drives the tool layer end to end against `FakeEventStore`. No test in this file
/// touches EventKit, so the suite runs with no permissions and no calendar — which is
/// the point.
@Suite("Tool dispatch")
struct CalendarToolsTests {

    private func call(
        _ name: String, _ arguments: [String: Value] = [:],
        store: FakeEventStore = FakeEventStore()
    ) async -> (text: String, isError: Bool) {
        let tools = CalendarTools(
            store: store, calendar: Fixtures.calendar, now: { Fixtures.now })
        let result = await tools.handle(.init(name: name, arguments: arguments))
        guard case .text(let text, _, _) = result.content.first else {
            return ("(no text content)", true)
        }
        return (text, result.isError ?? false)
    }

    // MARK: Catalogue

    /// One pass over the catalogue for everything that must hold for every tool: a
    /// unique name, a real title and description, annotations that match what the tool
    /// actually does, and a verb prefix exactly on the tools that write. Three
    /// previously separate tests collapsed into one — they all walked the same
    /// catalogue checking facets of the same read/write classification.
    @Test("Catalogue tools are well-formed and consistently classified")
    func catalogueIsWellFormedAndClassified() {
        let names = ToolCatalog.all().map(\.name)
        #expect(names.count == Set(names).count)

        let reads = ["calendar_status", "calendars_list", "calendar_search", "calendar_get"]
        for tool in ToolCatalog.all() {
            #expect(tool.description?.isEmpty == false, "\(tool.name) has no description")
            #expect(tool.title?.isEmpty == false, "\(tool.name) has no title")

            let isRead = reads.contains(tool.name)
            #expect(tool.annotations.readOnlyHint == isRead, "\(tool.name)")
            #expect(tool.annotations.destructiveHint == (tool.name == "delete_event"))

            let hasVerb = ["create_", "update_", "delete_"].contains { tool.name.hasPrefix($0) }
            #expect(isRead == !hasVerb, "\(tool.name)")
        }
    }

    /// Regression guard for a defect first seen in the sibling contacts server, where
    /// it made every list field of update_contact unusable.
    ///
    /// Claude Desktop's schema sanitiser drops a property whose `type` is a union such
    /// as `["array", "null"]`, replacing the whole subtree with `{}`. The model then
    /// serialises an array argument to a string and `Arguments` rejects it. Text fields
    /// hide the fault, because an untyped string still arrives as a string — which is
    /// why update_event looked healthy for as long as nobody touched `alarms`. Nothing
    /// downstream of the client can catch this, so it is caught here.
    @Test("No property declares its type as a union")
    func schemasDeclareScalarTypes() {
        func walk(_ value: Value, path: String) {
            guard let node = value.objectValue else { return }
            if let declared = node["type"] {
                #expect(
                    declared.stringValue != nil,
                    "\(path): type must be a single string, not a union")
            }
            for (key, child) in node["properties"]?.objectValue ?? [:] {
                walk(child, path: "\(path).\(key)")
            }
            if let items = node["items"] { walk(items, path: "\(path)[]") }
        }
        for tool in ToolCatalog.all() { walk(tool.inputSchema, path: tool.name) }
    }

    // MARK: Identifiers

    /// The composite id is the whole reason a single occurrence can be addressed.
    @Test("An occurrence id round-trips through encode and decode")
    func occurrenceIDRoundTrips() {
        let start = Fixtures.date(2026, 8, 14, 10, 0)
        let id = EventID(seriesIdentifier: "abc-123", occurrenceStart: start)
        let decoded = EventID.decode(id.encoded)
        #expect(decoded.seriesIdentifier == "abc-123")
        #expect(decoded.occurrenceStart.map { abs($0.timeIntervalSince(start)) < 1 } == true)
    }

    /// CalDAV identifiers can contain the separator, so decoding splits on the last one
    /// and only when the tail actually parses as a timestamp.
    @Test("An identifier containing the separator is not mangled")
    func separatorInIdentifierSurvives() {
        let plain = EventID.decode("weird|identifier|not-a-date")
        #expect(plain.seriesIdentifier == "weird|identifier|not-a-date")
        #expect(plain.occurrenceStart == nil)

        let start = Fixtures.date(2026, 8, 14, 10, 0)
        let composite = EventID(seriesIdentifier: "weird|id", occurrenceStart: start)
        #expect(EventID.decode(composite.encoded).seriesIdentifier == "weird|id")
    }

    // MARK: Dates

    @Test("The three accepted date forms parse, and nothing else does")
    func dateFormsParse() throws {
        let calendar = Fixtures.calendar
        let day = try DateParsing.parse("2026-08-12", argument: "from", calendar: calendar)
        #expect(day.isDateOnly)

        let local = try DateParsing.parse("2026-08-12T09:00", argument: "from", calendar: calendar)
        #expect(!local.isDateOnly)
        #expect(local.date == Fixtures.date(2026, 8, 12, 9, 0))

        let absolute = try DateParsing.parse(
            "2026-08-12T09:00:00+02:00", argument: "from", calendar: calendar)
        #expect(absolute.date == Fixtures.date(2026, 8, 12, 9, 0))

        // Each exercises a distinct rejection branch: wrong shape entirely, an
        // in-range-looking value that fails a numeric bound, and the right shape with
        // the wrong date/time separator.
        for bad in ["12/08/2026", "2026-13-01", "2026-08-12 09:00"] {
            #expect(throws: ToolError.self) {
                try DateParsing.parse(bad, argument: "from", calendar: calendar)
            }
        }
    }

    @Test("Alarm offsets parse into signed minutes")
    func alarmOffsetsParse() throws {
        #expect(try Arguments.alarmMinutes("-15m") == -15)
        #expect(try Arguments.alarmMinutes("-1h") == -60)
        #expect(try Arguments.alarmMinutes("-1d") == -1440)
        #expect(try Arguments.alarmMinutes("0") == 0)
        #expect(throws: ToolError.self) { try Arguments.alarmMinutes("soon") }
    }

    // MARK: Permissions

    @Test("A denied permission names the switch and where to find it")
    func deniedPermissionExplainsItself() async {
        let store = FakeEventStore(status: .denied)
        let result = await call("calendars_list", store: store)
        #expect(result.isError)
        #expect(result.text.contains("System Settings"))
        #expect(result.text.contains("apple-calendar-mcp"))
    }

    /// Write-only is the trap macOS 14 introduced: it looks granted but cannot read.
    @Test("Write-only access is refused with an explanation")
    func writeOnlyIsNotEnough() async {
        let store = FakeEventStore(status: .writeOnly)
        let result = await call("calendars_list", store: store)
        #expect(result.isError)
        #expect(result.text.contains("write-only") || result.text.contains("Write-only"))
        #expect(result.text.contains("full access"))
    }

    @Test("calendar_status reports without needing permission")
    func statusWorksWhileDenied() async {
        let result = await call("calendar_status", store: FakeEventStore(status: .denied))
        #expect(!result.isError)
        #expect(result.text.contains("DENIED"))
    }

    // MARK: Search

    @Test("Search echoes the range and time zone it used")
    func searchEchoesRange() async {
        let result = await call(
            "calendar_search", ["from": .string("2026-08-01"), "to": .string("2026-08-31")])
        #expect(!result.isError)
        #expect(result.text.contains("2026-08-01 → 2026-08-31"))
        #expect(result.text.contains("Europe/Madrid"))
    }

    @Test("A recurring hit is marked and carries an occurrence id")
    func recurringHitIsMarked() async {
        let result = await call(
            "calendar_search", ["from": .string("2026-08-13"), "to": .string("2026-08-15")])
        #expect(result.text.contains("series"))
        #expect(result.text.contains("id=ev-series|"))
    }

    @Test("A truncated page announces what it withheld")
    func truncationIsAnnounced() async {
        let result = await call(
            "calendar_search",
            ["from": .string("2026-08-01"), "to": .string("2026-08-31"), "limit": .int(2)])
        #expect(result.text.contains("more · call again with offset=2"))
    }

    @Test("A range longer than the cap is refused")
    func longRangeIsRefused() async {
        let result = await call(
            "calendar_search", ["from": .string("2020-01-01"), "to": .string("2030-01-01")])
        #expect(result.isError)
        #expect(result.text.contains("maximum is 366"))
    }

    @Test("A range that runs backwards is refused")
    func backwardsRangeIsRefused() async {
        let result = await call(
            "calendar_search", ["from": .string("2026-08-31"), "to": .string("2026-08-01")])
        #expect(result.isError)
    }

    // MARK: The history rule

    @Test("An event that has ended cannot be updated")
    func pastEventCannotBeUpdated() async {
        let store = FakeEventStore()
        let result = await call(
            "update_event", ["id": .string("ev-past"), "title": .string("Rewritten")],
            store: store)
        #expect(result.isError)
        #expect(result.text.contains("already ended"))
        #expect(store.updated.isEmpty)
    }

    @Test("An event that has ended cannot be deleted")
    func pastEventCannotBeDeleted() async {
        let store = FakeEventStore()
        let result = await call(
            "delete_event", ["id": .string("ev-past"), "confirm": .bool(true)], store: store)
        #expect(result.isError)
        #expect(store.deleted.isEmpty)
    }

    /// The boundary is the end, not the start — extending an overrunning meeting is a
    /// real need, and the rule is about finished events, not started ones.
    @Test("An event in progress can still be edited")
    func runningEventIsEditable() async {
        let store = FakeEventStore()
        let result = await call(
            "update_event", ["id": .string("ev-running"), "end": .string("2026-08-09T13:00")],
            store: store)
        #expect(!result.isError)
        #expect(store.updated.count == 1)
    }

    @Test("A read-only calendar refuses writes")
    func readOnlyCalendarRefusesWrites() async {
        let store = FakeEventStore()
        let result = await call(
            "update_event", ["id": .string("ev-holiday"), "title": .string("Nope")], store: store)
        #expect(result.isError)
        #expect(result.text.contains("read-only"))
        #expect(store.updated.isEmpty)
    }

    // MARK: Create

    @Test("An unknown calendar is refused, listing the writable ones")
    func unknownCalendarIsRefused() async {
        let result = await call(
            "create_event",
            [
                "calendar": .string("Nonexistent"), "title": .string("X"),
                "start": .string("2026-09-01T09:00"), "end": .string("2026-09-01T10:00"),
            ])
        #expect(result.isError)
        #expect(result.text.contains("Personal"))
        #expect(result.text.contains("Work"))
        #expect(!result.text.contains("Holidays"), "a read-only calendar is not an option")
    }

    @Test("Creating into a read-only calendar is refused")
    func createIntoReadOnlyIsRefused() async {
        let result = await call(
            "create_event",
            [
                "calendar": .string("Holidays"), "title": .string("X"),
                "start": .string("2026-09-01"), "end": .string("2026-09-02"),
            ])
        #expect(result.isError)
        #expect(result.text.contains("read-only"))
    }

    /// All-day is inferred from the shape of the input, not from a flag.
    @Test("Two plain days make an all-day event; a time makes a timed one")
    func allDayIsInferred() async {
        let store = FakeEventStore()
        _ = await call(
            "create_event",
            [
                "calendar": .string("Personal"), "title": .string("Trip"),
                "start": .string("2026-09-01"), "end": .string("2026-09-03"),
            ], store: store)
        #expect(store.events.last?.isAllDay == true)

        _ = await call(
            "create_event",
            [
                "calendar": .string("Personal"), "title": .string("Call"),
                "start": .string("2026-09-01T09:00"), "end": .string("2026-09-01T10:00"),
            ], store: store)
        #expect(store.events.last?.isAllDay == false)
    }

    /// Allowed on purpose, but it must never be silent.
    @Test("Creating an event in the past is allowed and flagged")
    func pastCreateIsFlagged() async {
        let result = await call(
            "create_event",
            [
                "calendar": .string("Personal"), "title": .string("Logged after the fact"),
                "start": .string("2026-07-01T09:00"), "end": .string("2026-07-01T10:00"),
            ])
        #expect(!result.isError)
        #expect(result.text.contains("in the past"))
    }

    @Test("An end before the start is refused")
    func endBeforeStartIsRefused() async {
        let result = await call(
            "create_event",
            [
                "calendar": .string("Personal"), "title": .string("Backwards"),
                "start": .string("2026-09-01T10:00"), "end": .string("2026-09-01T09:00"),
            ])
        #expect(result.isError)
    }

    /// Moving only the start, past an end that stays put, must still be caught.
    @Test("An update that would invert the event is refused")
    func updateCannotInvertEvent() async {
        let store = FakeEventStore()
        let result = await call(
            "update_event", ["id": .string("ev-future"), "start": .string("2026-08-12T20:00")],
            store: store)
        #expect(result.isError)
        #expect(store.updated.isEmpty)
    }

    // MARK: Span

    @Test("Span defaults to this occurrence, never the whole series")
    func spanDefaultsToThis() async {
        let store = FakeEventStore()
        let id = store.events.first { $0.isRecurring }!.id.encoded
        _ = await call(
            "update_event", ["id": .string(id), "title": .string("Renamed")], store: store)
        #expect(store.updated.first?.span == .this)
    }

    @Test("Span future is passed through")
    func spanFutureIsHonoured() async {
        let store = FakeEventStore()
        let id = store.events.first { $0.isRecurring }!.id.encoded
        _ = await call(
            "delete_event",
            ["id": .string(id), "confirm": .bool(true), "span": .string("future")], store: store)
        #expect(store.deleted.first?.span == .future)
    }

    @Test("An unrecognised span is refused rather than guessed")
    func badSpanIsRefused() async {
        let result = await call(
            "update_event",
            ["id": .string("ev-future"), "title": .string("X"), "span": .string("all")])
        #expect(result.isError)
        #expect(result.text.contains("span"))
    }

    // MARK: Delete

    @Test("Delete without confirm=true changes nothing")
    func deleteRequiresConfirmation() async {
        let store = FakeEventStore()
        let before = store.events.count
        let result = await call("delete_event", ["id": .string("ev-future")], store: store)
        #expect(result.isError)
        #expect(result.text.contains("confirm=true"))
        #expect(store.events.count == before)
    }

    @Test("Delete describes what it removed and how to recreate it")
    func deleteIsAuditable() async {
        let store = FakeEventStore()
        let result = await call(
            "delete_event", ["id": .string("ev-future"), "confirm": .bool(true)], store: store)
        #expect(!result.isError)
        #expect(result.text.contains("Dentist"))
        #expect(result.text.contains("Clinic"))
        #expect(result.text.contains("create_event("))
        #expect(result.text.contains("start=\"2026-08-12T16:00\""))
        #expect(result.text.contains("no longer exists"))
    }

    /// The recreate line cannot restore a recurrence rule, so it must say so.
    @Test("Deleting a series occurrence warns the recreate call is a one-off")
    func seriesDeleteWarnsAboutRecurrence() async {
        let store = FakeEventStore()
        let id = store.events.first { $0.isRecurring }!.id.encoded
        let result = await call(
            "delete_event", ["id": .string(id), "confirm": .bool(true)], store: store)
        #expect(result.text.contains("not the recurrence rule"))
    }

    // MARK: Detail

    @Test("Detail states whether the event can still be edited")
    func detailReportsEditability() async {
        let past = await call("calendar_get", ["id": .string("ev-past")])
        #expect(past.text.contains("NOT editable"))

        let running = await call("calendar_get", ["id": .string("ev-running")])
        #expect(running.text.contains("in progress"))

        let future = await call("calendar_get", ["id": .string("ev-future")])
        #expect(future.text.contains("upcoming"))
    }

    /// EventKit cannot invite anyone, so attendees must be labelled read-only.
    @Test("Attendees are shown as read-only")
    func attendeesAreMarkedReadOnly() async {
        let result = await call("calendar_get", ["id": .string("ev-past")])
        #expect(result.text.contains("Aurora Fakeperson"))
        #expect(result.text.contains("cannot invite"))
    }

    @Test("An unknown tool name is refused")
    func unknownToolIsRefused() async {
        let result = await call("calendar_wipe_everything")
        #expect(result.isError)
    }
}

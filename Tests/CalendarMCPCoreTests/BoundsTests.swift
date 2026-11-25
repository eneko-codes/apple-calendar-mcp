import Foundation
import Testing

@testable import CalendarMCPCore

/// The edges of the tool standard for this server's own tools: each bound and one past it,
/// the text of each notice, pages and windows that chain, the longest result, and the texts
/// the model reads. Every calendar, event, person and place in here is invented.
@Suite("Bounds")
struct BoundsTests {

    // MARK: Invented calendars with as many rows as a test asks for

    private static func padded(_ index: Int) -> String {
        String(format: "%04d", index)
    }

    /// `text` filled out to `width` characters, about the widest an ordinary one gets.
    private static func wide(_ text: String, _ width: Int) -> String {
        text + String(repeating: "x", count: max(width - text.count, 0))
    }

    /// As long as the identifier EventKit gives an event of a synced account: two UUIDs
    /// joined by a colon.
    private static func identifier(_ index: Int) -> String {
        let block = String(format: "%08d", index) + "-0000-4000-8000-000000000000"
        return block + ":" + block
    }

    /// One event an hour from 1 August 2026, each an occurrence of a series, so that its
    /// id carries the start time too and the row is as wide as an ordinary one gets.
    private static func meetings(_ count: Int) -> [EventDetail] {
        (0..<count).map { index in
            let start = Fixtures.date(2026, 8, 1).addingTimeInterval(TimeInterval(index) * 3600)
            return Fixtures.event(
                id: identifier(index), title: wide("Invented meeting \(padded(index)) ", 48),
                start: start, end: start.addingTimeInterval(1800),
                location: wide("Example Building, Room \(padded(index)) ", 32), isRecurring: true,
                occurrenceStart: start)
        }
    }

    private static let august: [String: Value] = ["from_date": "2026-08-01", "to_date": "2026-08-31"]

    /// One event with `count` attendees, handed over out of order.
    private static func crowd(_ count: Int, notes: String? = nil) -> EventDetail {
        Fixtures.event(
            id: "ev-crowd", title: "Invented assembly", start: Fixtures.date(2026, 8, 20, 9, 0),
            end: Fixtures.date(2026, 8, 20, 10, 0), notes: notes,
            attendees: (0..<count).reversed().map {
                Attendee(name: "Invented Attendee \(padded($0))", status: "accepted")
            })
    }

    /// One listing tool, and a store that gives it `count` rows of the widest ordinary
    /// width, in the order the tool lists them. `row` is text found in row `index` only.
    private struct Listing: Sendable, CustomTestStringConvertible {
        var tool: String
        var things: String
        var limits: ClosedRange<Int>
        var defaultLimit: Int
        var arguments: [String: Value] = [:]
        var store: @Sendable (Int) -> FakeEventStore
        var row: @Sendable (Int) -> String

        var testDescription: String { tool }

        func call(_ count: Int, _ extra: [String: Value] = [:]) async -> ToolResult {
            await CalendarMCPCoreTests.call(
                tool, arguments.merging(extra) { _, new in new }, store: store(count))
        }

        /// The rows of a store with `count` of them that `text` shows, in order.
        func rows(in text: String, of count: Int) -> [Int] {
            (0..<count).filter { text.contains(row($0)) }
        }
    }

    private static let calendars = Listing(
        tool: ToolCatalog.listName, things: "calendars", limits: Configuration.calendarLimitRange,
        defaultLimit: Configuration.defaultCalendarLimit,
        store: { count in
            FakeEventStore(
                // Out of order, as a store may hand them over.
                calendars: (0..<count).reversed().map {
                    CalendarInfo(
                        title: wide("Invented calendar \(padded($0)) ", 40),
                        sourceName: wide("Example account ", 30), isWritable: true,
                        isDefaultForNewEvents: $0 == 0)
                }, events: [])
        },
        row: { "Invented calendar \(padded($0)) " })

    private static let search = Listing(
        tool: ToolCatalog.searchName, things: "events", limits: Configuration.searchLimitRange,
        defaultLimit: Configuration.defaultSearchLimit, arguments: august,
        store: { FakeEventStore(events: meetings($0)) },
        row: { "Invented meeting \(padded($0)) " })

    private static let attendees = Listing(
        tool: ToolCatalog.getName, things: "attendees", limits: Configuration.attendeeLimitRange,
        defaultLimit: Configuration.defaultAttendeeLimit, arguments: ["id": "ev-crowd"],
        store: { FakeEventStore(events: [crowd($0)]) },
        row: { "Invented Attendee \(padded($0)) (" })

    private static let listings = [calendars, search, attendees]

    // MARK: Pages

    @Test("A call with no optional argument returns one default page, announced before the data", arguments: listings)
    private func defaultPage(_ listing: Listing) async {
        let total = listing.defaultLimit + 5
        let result = await listing.call(total)
        #expect(!result.isError)
        #expect(
            result.text.hasPrefix(
                "Showing 1–\(listing.defaultLimit) of \(total) \(listing.things). Pass offset=\(listing.defaultLimit) for the next page.\n\n"))
        #expect(listing.rows(in: result.text, of: total) == Array(0..<listing.defaultLimit))
        #expect(result.text.utf16.count <= ToolStandard.usualPage)
    }

    @Test("A result that holds every row from the start carries no notice", arguments: listings)
    private func wholeListingHasNoNotice(_ listing: Listing) async {
        let result = await listing.call(listing.defaultLimit)
        #expect(listing.rows(in: result.text, of: listing.defaultLimit).count == listing.defaultLimit)
        #expect(!result.text.contains("Showing"))
        #expect(!result.text.contains("is outside"))
        #expect(!result.text.contains("clipped"))
        #expect(!result.text.contains("characters"))
    }

    @Test("limit at its maximum is used as asked, and a full page of the widest rows fits a result", arguments: listings)
    private func limitAtItsMaximum(_ listing: Listing) async {
        let maximum = listing.limits.upperBound
        let total = maximum + 10
        let result = await listing.call(total, ["limit": .int(maximum)])
        #expect(!result.text.contains("is outside"))
        #expect(
            result.text.hasPrefix(
                "Showing 1–\(maximum) of \(total) \(listing.things). Pass offset=\(maximum) for the next page.\n\n"))
        #expect(listing.rows(in: result.text, of: total) == Array(0..<maximum))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
    }

    @Test("limit one past either end is moved to the nearest value, and the result says which", arguments: listings)
    private func limitPastItsRange(_ listing: Listing) async {
        let maximum = listing.limits.upperBound
        let total = maximum + 10

        let over = await listing.call(total, ["limit": .int(maximum + 1)])
        #expect(
            over.text.hasPrefix(
                """
                limit=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.
                Showing 1–\(maximum) of \(total) \(listing.things). Pass offset=\(maximum) for the next page.


                """))
        #expect(listing.rows(in: over.text, of: total) == Array(0..<maximum))

        let under = await listing.call(total, ["limit": .int(0)])
        #expect(under.text.hasPrefix("limit=0 is outside 1–\(maximum); 1 was used.\nShowing 1–1 of \(total) "))
        #expect(listing.rows(in: under.text, of: total) == [0])
    }

    @Test("Each page starts where the last one ended, and the last says that is all", arguments: listings)
    private func pagesChain(_ listing: Listing) async {
        let first = await listing.call(7, ["limit": .int(3)])
        #expect(first.text.hasPrefix("Showing 1–3 of 7 \(listing.things). Pass offset=3 for the next page.\n\n"))
        #expect(listing.rows(in: first.text, of: 7) == [0, 1, 2])

        let second = await listing.call(7, ["limit": .int(3), "offset": .int(3)])
        #expect(second.text.hasPrefix("Showing 4–6 of 7 \(listing.things). Pass offset=6 for the next page.\n\n"))
        #expect(listing.rows(in: second.text, of: 7) == [3, 4, 5])

        let last = await listing.call(7, ["limit": .int(3), "offset": .int(6)])
        #expect(last.text.hasPrefix("Showing 7–7 of 7 \(listing.things). That is all.\n\n"))
        #expect(listing.rows(in: last.text, of: 7) == [6])
    }

    @Test("An offset past the end returns no row and says so; a negative one is moved to zero", arguments: listings)
    private func offsetEdges(_ listing: Listing) async {
        let past = await listing.call(7, ["offset": .int(7)])
        #expect(!past.isError)
        #expect(past.text.hasPrefix("Showing 0 of 7 \(listing.things): offset=7 is past the end. That is all.\n\n"))
        #expect(listing.rows(in: past.text, of: 7).isEmpty)
        #expect(past.text.contains("(nothing at this offset)"))

        let lastRow = await listing.call(7, ["offset": .int(6)])
        #expect(listing.rows(in: lastRow.text, of: 7) == [6])

        let negative = await listing.call(7, ["offset": .int(-1)])
        let range = Configuration.offsetRange
        #expect(negative.text.hasPrefix("offset=-1 is outside \(range.lowerBound)–\(range.upperBound); 0 was used.\n\n"))
        #expect(listing.rows(in: negative.text, of: 7) == Array(0..<7))
    }

    @Test("A listing with nothing in it says so, and carries no notice", arguments: listings)
    private func emptyListing(_ listing: Listing) async {
        let none = await listing.call(0)
        #expect(!none.isError)
        #expect(!none.text.contains("(nothing at this offset)"))
        #expect(!none.text.contains("Showing"))
    }

    @Test("A listing states its order, and keeps it whatever order the store answers in")
    func orderIsStated() async {
        #expect(await Self.calendars.call(1).text.contains("ordered by name, then account"))
        #expect(await Self.search.call(1).text.contains("ordered by start"))
        #expect(await Self.attendees.call(1).text.contains("ordered by name"))
    }

    @Test("Events that start together are ordered by end, then title, the same on every call")
    func tiesAreBroken() async throws {
        let start = Fixtures.date(2026, 8, 5, 10, 0)
        func event(_ id: String, _ title: String, minutes: Double) -> EventDetail {
            Fixtures.event(id: id, title: title, start: start, end: start.addingTimeInterval(minutes * 60))
        }
        let events = [
            event("ev-b", "Invented beta", minutes: 30), event("ev-a", "Invented alpha", minutes: 30),
            event("ev-c", "Invented gamma", minutes: 15),
        ]
        for order in [events, events.reversed()] {
            let text = await call(ToolCatalog.searchName, Self.august, store: FakeEventStore(events: order)).text
            let positions = try ["Invented gamma", "Invented alpha", "Invented beta"].map {
                try #require(text.range(of: $0)).lowerBound
            }
            #expect(positions == positions.sorted())
        }
    }

    @Test("Calendars with the same name are ordered by account")
    func calendarTiesAreBroken() async throws {
        let store = FakeEventStore(
            calendars: ["Invented B", "Invented A"].map {
                CalendarInfo(title: "Shared", sourceName: $0, isWritable: true, isDefaultForNewEvents: false)
            }, events: [])
        let text = await call(ToolCatalog.listName, store: store).text
        let first = try #require(text.range(of: "Invented A")).lowerBound
        let second = try #require(text.range(of: "Invented B")).lowerBound
        #expect(first < second)
    }

    // MARK: Rows wider than any maximum foresaw

    @Test("A page of rows too wide to fit holds fewer of them and says where to resume")
    func widePageShrinks() async throws {
        // The number leads the name, so that looking for a row never has to walk the filler.
        let filler = String(repeating: "w", count: 1000)
        let store = FakeEventStore(
            calendars: (0..<200).map {
                CalendarInfo(
                    title: "row-\(Self.padded($0))-\(filler)", sourceName: "Example account",
                    isWritable: true, isDefaultForNewEvents: false)
            }, events: [])
        var offset = 0
        var seen: [Int] = []
        while offset < 200 {
            let result = await call(
                ToolCatalog.listName, ["limit": .int(200), "offset": .int(offset)], store: store)
            #expect(result.text.utf16.count <= ToolStandard.longestResult)
            let shown = (0..<200).filter { result.text.contains("row-\(Self.padded($0))-") }
            let last = try #require(shown.last)
            #expect(shown.first == offset)
            #expect(shown.count < 200)
            let next = last + 1 < 200 ? "Pass offset=\(last + 1) for the next page." : "That is all."
            #expect(result.text.hasPrefix("Showing \(offset + 1)–\(last + 1) of 200 calendars. \(next)\n\n"))
            seen += shown
            offset = last + 1
        }
        #expect(seen == Array(0..<200))
    }

    @Test("A search page whose ids are far too wide holds fewer rows and still fits a result")
    func wideSearchPageShrinks() async {
        // The id is the one field of a row that is never clipped: a clipped id finds nothing.
        let filler = String(repeating: "i", count: 3000)
        let events = Self.meetings(100).enumerated().map { index, event in
            Fixtures.event(id: "id-\(Self.padded(index))-\(filler)", title: event.title, start: event.start, end: event.end)
        }
        let result = await call(
            ToolCatalog.searchName, Self.august.merging(["limit": .int(100)]) { _, new in new },
            store: FakeEventStore(events: events))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
        #expect(result.text.hasPrefix("Showing 1–12 of 100 events. Pass offset=12 for the next page.\n\n"))
        #expect(result.text.contains("id=id-0011-\(filler)") && !result.text.contains("id=id-0012-"))
    }

    // MARK: Long fields in a search row

    @Test("A title, calendar name or location wider than a row allows is clipped, and the result says so before the data")
    func longRowFieldsAreClipped() async {
        let width = Configuration.rowFieldWidth
        let title = "T" + String(repeating: "t", count: width)
        let name = "C" + String(repeating: "c", count: width)
        let location = "L" + String(repeating: "l", count: width)
        let start = Fixtures.date(2026, 8, 5, 10, 0)
        let store = FakeEventStore(events: [
            Fixtures.event(
                id: "ev-long", title: title, start: start, end: start.addingTimeInterval(1800),
                calendarTitle: name, location: location)
        ])
        let result = await call(ToolCatalog.searchName, Self.august, store: store)
        #expect(
            result.text.hasPrefix(
                """
                Title is clipped to \(width) characters in each row. Read one in full with calendar_get.
                Calendar is clipped to \(width) characters in each row. Read one in full with calendar_get.
                Location is clipped to \(width) characters in each row. Read one in full with calendar_get.

                1 event ·
                """))
        #expect(
            result.text.contains(
                "  \(title.prefix(width))…  [\(name.prefix(width))…]  \(location.prefix(width))…  id=ev-long"))
        #expect(!result.text.contains(title) && !result.text.contains(name) && !result.text.contains(location))

        // The tool the notice names does hold all three in full.
        let record = await call(ToolCatalog.getName, ["id": "ev-long"], store: store)
        #expect(record.text.contains(title) && record.text.contains(name) && record.text.contains(location))
        #expect(!record.text.contains("clipped"))
    }

    @Test("A title exactly as wide as a row allows is shown whole, with no notice")
    func fieldAtTheWidthIsWhole() async {
        let title = String(repeating: "t", count: Configuration.rowFieldWidth)
        let start = Fixtures.date(2026, 8, 5, 10, 0)
        let result = await call(
            ToolCatalog.searchName, Self.august,
            store: FakeEventStore(events: [
                Fixtures.event(id: "ev-edge", title: title, start: start, end: start.addingTimeInterval(1800))
            ]))
        #expect(result.text.contains("  \(title)  [Work]"))
        #expect(!result.text.contains("clipped"))
    }

    // MARK: The range of a search

    private static func day(_ date: Date) -> String {
        DateParsing.roundTrip(date, isAllDay: true, calendar: Fixtures.calendar)
    }

    private static func adding(days: Int, to date: Date) -> Date {
        Fixtures.calendar.date(byAdding: .day, value: days, to: date)!
    }

    private static func single(_ id: String, _ title: String, _ start: Date, hours: Double = 1) -> EventDetail {
        Fixtures.event(id: id, title: title, start: start, end: start.addingTimeInterval(hours * 3600))
    }

    @Test("to_date is included: a plain day runs to its end, and a moment takes what starts on it")
    func toDateIsInclusive() async {
        let store = FakeEventStore(events: [
            Self.single("ev-last", "Invented late call", Fixtures.date(2026, 8, 31, 23, 0), hours: 0.5),
            Self.single("ev-next", "Invented next day", Fixtures.date(2026, 9, 1, 0, 0)),
        ])
        let oneDay = await call(
            ToolCatalog.searchName, ["from_date": "2026-08-31", "to_date": "2026-08-31"], store: store)
        #expect(oneDay.text.hasPrefix("1 event · 2026-08-31 → 2026-08-31 · "))
        #expect(oneDay.text.contains("Invented late call") && !oneDay.text.contains("Invented next day"))

        let onTheMoment = await call(
            ToolCatalog.searchName, ["from_date": "2026-08-31", "to_date": "2026-08-31T23:00"], store: store)
        #expect(onTheMoment.text.hasPrefix("1 event · 2026-08-31 → 2026-08-31T23:00 · "))
        let justBefore = await call(
            ToolCatalog.searchName, ["from_date": "2026-08-31", "to_date": "2026-08-31T22:59"], store: store)
        #expect(justBefore.text.hasPrefix("0 events · "))
        #expect(justBefore.text.contains("No events in this range."))
    }

    @Test("With no date the search starts today and runs on")
    func noDateStartsToday() async {
        // Fixtures.now is 9 August 2026: the review of 3 August is over, the standup is on.
        let result = await call(ToolCatalog.searchName)
        #expect(!result.isError)
        #expect(result.text.contains("4 events so far · 2026-08-09 → onwards · Europe/Madrid"))
        #expect(result.text.contains("Standup") && !result.text.contains("Quarterly review"))
    }

    @Test("from_date alone runs on: one call looks one reach ahead, says where it stopped, and the next call continues")
    func fromDateAloneRunsOn() async {
        let from = Fixtures.date(2026, 8, 1)
        let reach = Self.adding(days: Configuration.longestScanDays, to: from)
        let store = FakeEventStore(events: [
            Self.single("ev-1", "Invented first", Fixtures.date(2026, 9, 1, 9, 0)),
            Self.single("ev-2", "Invented second", Fixtures.date(2027, 9, 1, 9, 0)),
            Self.single("ev-3", "Invented third", Fixtures.date(2029, 9, 1, 9, 0)),
            Self.single("ev-4", "Invented beyond", Self.adding(days: 30, to: reach)),
        ])
        let first = await call(ToolCatalog.searchName, ["from_date": "2026-08-01"], store: store)
        #expect(
            first.text.hasPrefix(
                """
                The scan stopped after 3 events; more may exist. Narrow by from_date=\(Self.day(reach)) for the events from then on.

                3 events so far · 2026-08-01 → onwards · Europe/Madrid · calendars: all · ordered by start
                """))
        #expect(!first.text.contains("Invented beyond"))

        // One query a piece, each inside what EventKit serves whole, end to end with no gap.
        let pieces = store.searches
        #expect(pieces.count == Configuration.longestScanDays / Configuration.scanChunkDays)
        #expect(pieces.first?.from == from && pieces.last?.to == reach)
        for (piece, next) in zip(pieces, pieces.dropFirst()) { #expect(piece.to == next.from) }
        for piece in pieces {
            #expect(piece.to == Self.adding(days: Configuration.scanChunkDays, to: piece.from))
        }

        let second = await call(ToolCatalog.searchName, ["from_date": .string(Self.day(reach))], store: store)
        #expect(second.text.contains("Invented beyond"))
    }

    @Test("A range longer than one call looks at is searched as far as that, not refused")
    func longRangeIsNotRefused() async {
        let reach = Self.adding(days: Configuration.longestScanDays, to: Fixtures.date(2020, 1, 1))
        let store = FakeEventStore(events: [
            Self.single("ev-early", "Invented early", Fixtures.date(2021, 3, 1, 9, 0)),
            Self.single("ev-late", "Invented late", Fixtures.date(2029, 3, 1, 9, 0)),
        ])
        let result = await call(
            ToolCatalog.searchName, ["from_date": "2020-01-01", "to_date": "2030-01-01"], store: store)
        #expect(!result.isError)
        #expect(
            result.text.hasPrefix(
                "The scan stopped after 1 events; more may exist. Narrow by from_date=\(Self.day(reach)) for the events from then on.\n\n1 event so far · 2020-01-01 → 2030-01-01 · "))
        #expect(result.text.contains("Invented early") && !result.text.contains("Invented late"))
    }

    @Test("A range inside one call's reach is covered whole, so its total is exact")
    func rangeInsideTheReachIsExact() async {
        let store = FakeEventStore(events: [
            Self.single("ev-early", "Invented early", Fixtures.date(2026, 3, 1, 9, 0)),
            Self.single("ev-late", "Invented late", Fixtures.date(2028, 3, 1, 9, 0)),
        ])
        let result = await call(
            ToolCatalog.searchName, ["from_date": "2026-01-01", "to_date": "2028-12-31"], store: store)
        #expect(result.text.hasPrefix("2 events · 2026-01-01 → 2028-12-31 · "))
        #expect(store.searches.count == 3)
    }

    @Test("The scan stops as soon as its page is full, and then says only that more exist")
    func scanStopsWhenThePageIsFull() async {
        let limit = Configuration.defaultSearchLimit
        let events = (0..<60).map {
            Self.single(
                "ev-\($0)", "Invented meeting \(Self.padded($0)) ",
                Fixtures.date(2026, 8, 10).addingTimeInterval(TimeInterval($0) * 3600), hours: 0.5)
        }
        let store = FakeEventStore(events: events)
        let first = await call(ToolCatalog.searchName, store: store)
        #expect(
            first.text.hasPrefix(
                "Showing 1–\(limit) events; more exist. Pass offset=\(limit) for the next page.\n\nat least 60 events · 2026-08-09 → onwards · "))
        #expect(store.searches.count == 1)

        // The second page needs more matches than exist, so the scan runs to its reach.
        let reach = Self.adding(days: Configuration.longestScanDays, to: Fixtures.date(2026, 8, 9))
        let second = await call(ToolCatalog.searchName, ["offset": .int(limit)], store: store)
        #expect(
            second.text.hasPrefix(
                """
                Showing \(limit + 1)–60 of 60 events found before the scan stopped. That is all.
                The scan stopped after 60 events; more may exist. Narrow by from_date=\(Self.day(reach)) for the events from then on.

                60 events so far ·
                """))
        #expect(second.text.contains("Invented meeting 0059 ") && !second.text.contains("Invented meeting 0039 "))
    }

    @Test("to_date alone covers one reach up to it, and says how to look further back")
    func toDateAloneLooksBack() async {
        let lower = Self.adding(days: -Configuration.longestScanDays, to: Fixtures.date(2026, 8, 10))
        let store = FakeEventStore(events: [
            Self.single("ev-old", "Invented long ago", Self.adding(days: -400, to: lower)),
            Self.single("ev-recent", "Invented recent", Fixtures.date(2026, 8, 5, 9, 0)),
        ])
        let result = await call(ToolCatalog.searchName, ["to_date": "2026-08-09"], store: store)
        let dayBefore = Self.day(Self.adding(days: -1, to: lower))
        #expect(
            result.text.hasPrefix(
                """
                The scan stopped after 1 events; more may exist. Narrow by to_date=\(dayBefore) for the events before \(Self.day(lower)).

                1 event · \(Self.day(lower)) → 2026-08-09 ·
                """))
        #expect(result.text.contains("Invented recent") && !result.text.contains("Invented long ago"))

        let earlier = await call(ToolCatalog.searchName, ["to_date": .string(dayBefore)], store: store)
        #expect(earlier.text.contains("Invented long ago"))
    }

    @Test("to_date alone with a time of day starts on a whole day, so looking further back leaves no gap")
    func timedToDateAloneLeavesNoGap() async {
        // 1464 days before 9 August 2026 at 09:00 is 6 August 2022 at 09:00: the range
        // starts on the 7th, and the call that continues ends with the whole of the 6th.
        let furthest = Self.adding(days: -Configuration.longestScanDays, to: Fixtures.date(2026, 8, 9, 9, 0))
        let lower = Self.adding(days: 1, to: Fixtures.calendar.startOfDay(for: furthest))
        let store = FakeEventStore(events: [
            Self.single("ev-evening", "Invented evening before", lower.addingTimeInterval(-4 * 3600)),
            Self.single("ev-small-hours", "Invented small hours", lower.addingTimeInterval(3 * 3600)),
            Self.single("ev-last", "Invented on the moment", Fixtures.date(2026, 8, 9, 9, 0)),
        ])
        let first = await call(ToolCatalog.searchName, ["to_date": "2026-08-09T09:00"], store: store)
        let dayBefore = Self.day(Self.adding(days: -1, to: lower))
        #expect(
            first.text.hasPrefix(
                """
                The scan stopped after 2 events; more may exist. Narrow by to_date=\(dayBefore) for the events before \(Self.day(lower)).

                2 events · \(Self.day(lower)) → 2026-08-09T09:00 ·
                """))
        #expect(first.text.contains("Invented small hours") && first.text.contains("Invented on the moment"))
        #expect(!first.text.contains("Invented evening before"))

        let earlier = await call(ToolCatalog.searchName, ["to_date": .string(dayBefore)], store: store)
        #expect(earlier.text.contains("Invented evening before") && !earlier.text.contains("Invented small hours"))
    }

    @Test("A scan that stops at a time of day names that minute, so the call that continues leaves no gap")
    func timedReachIsNamedToTheMinute() async {
        let from = Fixtures.date(2026, 8, 1, 9, 30)
        let reach = Self.adding(days: Configuration.longestScanDays, to: from)
        let result = await call(
            ToolCatalog.searchName, ["from_date": "2026-08-01T09:30"], store: FakeEventStore(events: []))
        let named = DateParsing.roundTrip(reach, isAllDay: false, calendar: Fixtures.calendar)
        #expect(named.hasSuffix("T09:30"))
        #expect(
            result.text.hasPrefix(
                "The scan stopped after 0 events; more may exist. Narrow by from_date=\(named) for the events from then on.\n\n0 events so far · 2026-08-01T09:30 → onwards · "))
        #expect(result.text.contains("No events in the part of the range that was looked at."))
    }

    @Test("A search out of time returns what it has, marked partial, with the call that continues")
    func searchOutOfTimeIsPartial() async {
        let store = FakeEventStore(events: [
            Self.single("ev-early", "Invented early", Fixtures.date(2026, 6, 1, 9, 0)),
            Self.single("ev-late", "Invented late", Fixtures.date(2028, 6, 1, 9, 0)),
        ])
        let result = await call(
            ToolCatalog.searchName, ["from_date": "2026-01-01", "to_date": "2028-12-31"], store: store,
            scanBudget: .zero)
        let reached = Self.adding(days: Configuration.scanChunkDays, to: Fixtures.date(2026, 1, 1))
        #expect(!result.isError)
        #expect(
            result.text.hasPrefix(
                "Partial: the time limit was reached after 1 events. Narrow by from_date=\(Self.day(reached)) for the events from then on.\n\n1 event so far · "))
        #expect(result.text.contains("Invented early") && !result.text.contains("Invented late"))
        // The first piece is always looked at, so narrowing always gets somewhere.
        #expect(store.searches.count == 1)
    }

    @Test("An event that runs across two pieces of the range is listed once, and one that began before it is marked")
    func eventsAcrossBoundaries() async {
        let boundary = Self.adding(days: Configuration.scanChunkDays, to: Fixtures.date(2026, 1, 1))
        let store = FakeEventStore(events: [
            Fixtures.event(
                id: "ev-across", title: "Invented long trip", start: Self.adding(days: -5, to: boundary),
                end: Self.adding(days: 5, to: boundary)),
            Fixtures.event(
                id: "ev-before", title: "Invented season", start: Fixtures.date(2025, 12, 20),
                end: Fixtures.date(2026, 1, 10)),
        ])
        let result = await call(
            ToolCatalog.searchName, ["from_date": "2026-01-01", "to_date": "2027-12-31"], store: store)
        #expect(result.text.hasPrefix("2 events · "))
        #expect(result.text.components(separatedBy: "Invented long trip").count == 2)
        #expect(result.text.contains("Invented season  [Work]  ongoing  id=ev-before"))
        #expect(!result.text.contains("Invented long trip  [Work]  ongoing"))
    }

    // MARK: The window on one event's record

    private static let longNotes = (0..<900).map { "Invented note line \(padded($0)), nothing real in it." }
        .joined(separator: "\n")

    private static func record(_ event: EventDetail) -> String {
        let listed = event.attendees.sorted { $0.name < $1.name }.prefix(Configuration.defaultAttendeeLimit)
        return Format(calendar: Fixtures.calendar).detail(event, attendees: Array(listed), now: Fixtures.now)
    }

    private func window(_ text: String) -> String {
        // The notices end at the first blank line; a record has none before its notes.
        guard text.hasPrefix("Event: characters") || text.contains(" was used.\nEvent: characters"),
            let gap = text.range(of: "\n\n")
        else { return text }
        return String(text[gap.upperBound...])
    }

    private func get(_ event: EventDetail, _ extra: [String: Value] = [:]) async -> ToolResult {
        await call(
            ToolCatalog.getName, ["id": "ev-crowd"].merging(extra) { _, new in new },
            store: FakeEventStore(events: [event]))
    }

    @Test("A long record comes as one default window, announced before the data, with the facts that identify the event in it")
    func defaultWindow() async {
        let event = Self.crowd(3, notes: Self.longNotes)
        let whole = Self.record(event)
        let size = Configuration.defaultMaxCharacters
        #expect(whole.count > size)
        let result = await get(event)
        #expect(
            result.text.hasPrefix(
                "Event: characters 1–\(size) of \(whole.count). Pass character_offset=\(size) for the rest.\n\nInvented assembly\n"))
        #expect(window(result.text) == String(whole.prefix(size)))
        for fact in ["  when ", "  state ", "  id        ev-crowd", "Invented Attendee 0002 (accepted)"] {
            #expect(result.text.contains(fact), "\(fact)")
        }
    }

    @Test("Windows chain: each starts where the last ended, and together they are the whole record")
    func windowsChain() async {
        let event = Self.crowd(3, notes: Self.longNotes)
        let whole = Self.record(event)
        var offset = 0
        var joined = ""
        while offset < whole.count {
            let result = await get(event, ["character_offset": .int(offset), "max_characters": .int(7000)])
            let part = window(result.text)
            let last = offset + part.count
            let next = last < whole.count ? "Pass character_offset=\(last) for the rest." : "That is all."
            #expect(result.text.hasPrefix("Event: characters \(offset + 1)–\(last) of \(whole.count). \(next)\n\n"))
            #expect(part.count == min(7000, whole.count - offset))
            joined += part
            offset = last
        }
        #expect(joined == whole)
    }

    @Test("A record that fits one window carries no notice, and lists every field once")
    func shortRecordHasNoNotice() async {
        let result = await call(ToolCatalog.getName, ["id": "ev-past"])
        #expect(
            result.text == """
                Quarterly review
                  when      Mon 03 Aug 2026, 09:00–10:30 · Europe/Madrid
                  calendar  Work
                  state     ended 6 days ago
                  id        ev-past
                  location  Room 2
                  attendees 1, ordered by name · read-only: EventKit cannot invite
                            Aurora Fakeperson (accepted)
                  notes     Prepare Q2 figures.
                """)
    }

    @Test("max_characters at its maximum is used as asked; one past either end is moved and reported")
    func windowSizeBounds() async {
        let event = Self.crowd(3, notes: Self.longNotes)
        let maximum = Configuration.maxCharactersRange.upperBound
        #expect(Self.record(event).count > maximum)

        let atMaximum = await get(event, ["max_characters": .int(maximum)])
        #expect(!atMaximum.text.contains("is outside"))
        #expect(window(atMaximum.text).count == maximum)
        #expect(atMaximum.text.utf16.count <= ToolStandard.longestResult)

        let over = await get(event, ["max_characters": .int(maximum + 1)])
        #expect(
            over.text.hasPrefix(
                "max_characters=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.\nEvent: characters 1–\(maximum) of "))
        #expect(window(over.text).count == maximum)

        let under = await get(event, ["max_characters": .int(0)])
        #expect(under.text.hasPrefix("max_characters=0 is outside 1–\(maximum); 1 was used.\nEvent: characters 1–1 of "))
        #expect(window(under.text) == "I")
    }

    @Test("character_offset past the end returns no text and says so; a negative one is moved to zero")
    func windowOffsetEdges() async {
        let event = Self.crowd(3, notes: Self.longNotes)
        let whole = Self.record(event)
        let past = await get(event, ["character_offset": .int(whole.count + 50)])
        #expect(
            past.text
                == "Event: characters 0 of \(whole.count): character_offset=\(whole.count + 50) is past the end. That is all.\n\n")

        let negative = await get(event, ["character_offset": .int(-3)])
        let range = Configuration.offsetRange
        #expect(
            negative.text.hasPrefix(
                "character_offset=-3 is outside \(range.lowerBound)–\(range.upperBound); 0 was used.\nEvent: characters 1–"))
    }

    @Test("A window of characters that take several UTF-16 units each still fits a result, and still chains")
    func windowOfWideCharacters() async {
        // Eight UTF-16 units to the character: a full window would be four results long.
        let event = Self.crowd(0, notes: String(repeating: "👩‍👩‍👧", count: 30_000))
        let whole = Self.record(event)
        let maximum = Configuration.maxCharactersRange.upperBound
        var offset = 0
        var joined = ""
        while offset < whole.count {
            let result = await get(event, ["character_offset": .int(offset), "max_characters": .int(maximum)])
            #expect(result.text.utf16.count <= ToolStandard.longestResult)
            let part = window(result.text)
            #expect(!part.isEmpty && part.count < maximum)
            let last = offset + part.count
            #expect(result.text.hasPrefix("Event: characters \(offset + 1)–\(last) of \(whole.count). "))
            joined += part
            offset = last
        }
        #expect(joined == whole)
    }

    @Test("An event's attendees and its record are each announced, both before the data")
    func attendeesAndWindowTogether() async {
        let event = Self.crowd(5, notes: Self.longNotes)
        let result = await get(event, ["limit": .int(2)])
        let size = Configuration.defaultMaxCharacters
        #expect(result.text.hasPrefix("Showing 1–2 of 5 attendees. Pass offset=2 for the next page.\nEvent: characters 1–\(size) of "))
        #expect(result.text.contains("Pass character_offset=\(size) for the rest.\n\nInvented assembly\n"))
        #expect(result.text.contains("Invented Attendee 0001 (") && !result.text.contains("Invented Attendee 0002 ("))
    }

    // MARK: Receipts

    private static let createArguments: [String: Value] = [
        "calendar": "Personal", "title": "Invented visit", "start": "2026-09-01T09:00",
        "end": "2026-09-01T10:00",
    ]

    @Test("Creating answers with a short receipt, not the event")
    func createReceiptIsShort() async {
        let store = FakeEventStore()
        let result = await call(
            ToolCatalog.createName,
            Self.createArguments.merging(["notes": .string(Self.longNotes), "location": "Invented place"]) { _, new in new },
            store: store)
        #expect(
            result.text == """
                Created event 'Invented visit' in Personal.
                  when Tue 01 Sep 2026, 09:00–10:00 · Europe/Madrid
                  id   created-6

                calendar_get returns the full record.
                """)
        #expect(store.events.last?.notes == Self.longNotes)
    }

    @Test("Updating answers with a short receipt, and says when it clipped a long title")
    func updateReceiptIsShort() async {
        let title = "T" + String(repeating: "t", count: 300)
        let start = Fixtures.date(2026, 8, 20, 9, 0)
        let store = FakeEventStore(events: [
            Fixtures.event(
                id: "ev-long", title: title, start: start, end: start.addingTimeInterval(3600),
                notes: Self.longNotes)
        ])
        let result = await call(
            ToolCatalog.updateName, ["id": "ev-long", "location": "Invented place"], store: store)
        let width = Configuration.rowFieldWidth
        #expect(
            result.text == """
                Title is clipped to \(width) characters in each row. Read one in full with calendar_get.

                Updated event '\(title.prefix(width))…' in Work. Fields changed: location.
                  when Thu 20 Aug 2026, 09:00–10:00 · Europe/Madrid
                  id   ev-long

                calendar_get returns the full record.
                """)
    }

    @Test("An update cannot empty the title, and says so instead of reporting a change")
    func titleCannotBeEmptied() async {
        let store = FakeEventStore()
        let result = await call(ToolCatalog.updateName, ["id": "ev-future", "title": ""], store: store)
        #expect(result.isError)
        #expect(result.text == "Argument 'title' is not valid: it is empty; an event needs a title")
        #expect(store.updated.isEmpty)
    }

    private func delete(notes: String, attendees: Int = 0) async -> (result: ToolResult, store: FakeEventStore) {
        let store = FakeEventStore(events: [Self.crowd(attendees, notes: notes)])
        let result = await call(ToolCatalog.deleteName, ["id": "ev-crowd", "confirm": true], store: store)
        return (result, store)
    }

    @Test("Deleting returns the record once, whole when it fits")
    func deleteReturnsTheRecordOnce() async {
        let notes = Self.longNotes.split(separator: "\n").prefix(300).joined(separator: "\n")
        let (result, store) = await delete(notes: notes, attendees: 3)
        #expect(!result.isError && store.deleted.count == 1)
        #expect(
            result.text.hasPrefix(
                """
                Deleted 'Invented assembly' from Work. Its id no longer exists: ev-crowd

                It cannot be restored. create_event with these arguments makes a new event like it, without its 3 attendees, whom EventKit cannot invite:

                  calendar Work
                  title    Invented assembly
                  start    2026-08-20T09:00
                  end      2026-08-20T10:00
                  notes    Invented note line 0000, nothing real in it.
                """))
        #expect(result.text.components(separatedBy: "Invented note line 0000,").count == 2)
        #expect(result.text.hasSuffix("Invented note line 0299, nothing real in it."))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
    }

    @Test("A deleted record too long for one result is cut, and the result says first that the rest is gone")
    func deleteCutsALongRecord() async {
        let limit = Configuration.deletedRecordCharacters
        let (result, store) = await delete(notes: String(repeating: "n", count: 100_000))
        #expect(!result.isError && store.deleted.count == 1)
        #expect(result.text.hasPrefix("The deleted event's record is "))
        #expect(
            result.text.contains(
                " characters long and only the first \(limit) are below. The rest cannot be read again: the event no longer exists.\n\nDeleted 'Invented assembly'"))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)

        // Two UTF-16 units to the character: the record is halved until it fits.
        let (wide, _) = await delete(notes: String(repeating: "😀", count: 100_000))
        #expect(wide.text.contains("only the first \(limit / 2) are below."))
        #expect(wide.text.utf16.count <= ToolStandard.longestResult)
    }

    @Test("A deleted record exactly as long as the limit is whole, and one character more is cut")
    func deleteAtTheLimit() async {
        let limit = Configuration.deletedRecordCharacters
        let overhead = Format.deletedRecord(Self.crowd(0, notes: "n"), calendar: Fixtures.calendar).count - 1
        let (whole, _) = await delete(notes: String(repeating: "n", count: limit - overhead))
        #expect(whole.text.hasPrefix("Deleted 'Invented assembly'"))
        let (cut, _) = await delete(notes: String(repeating: "n", count: limit - overhead + 1))
        #expect(cut.text.hasPrefix("The deleted event's record is \(limit + 1) characters long and only the first \(limit) are below."))
    }

    // MARK: Values refused, never moved

    @Test("A wrong type is refused with the form expected")
    func wrongTypesAreRefused() async {
        let cases: [(tool: String, arguments: [String: Value], expected: String)] = [
            (ToolCatalog.searchName, ["limit": "ten"], "Argument 'limit' is not valid: a whole number was expected"),
            (ToolCatalog.searchName, ["limit": 2.5], "Argument 'limit' is not valid: a whole number was expected"),
            (ToolCatalog.searchName, ["offset": true], "Argument 'offset' is not valid: a whole number was expected"),
            (ToolCatalog.searchName, ["query": 5], "Argument 'query' is not valid: text was expected"),
            (ToolCatalog.searchName, ["calendars": [1, 2]], "Argument 'calendars' is not valid: an array of text was expected"),
            (ToolCatalog.searchName, ["from_date": 20_260_801], "Argument 'from_date' is not valid: text was expected"),
            (ToolCatalog.listName, ["limit": [1]], "Argument 'limit' is not valid: a whole number was expected"),
            (ToolCatalog.getName, ["id": 7], "Argument 'id' is not valid: text was expected"),
            (ToolCatalog.getName, ["id": "ev-past", "max_characters": "all"], "Argument 'max_characters' is not valid"),
            (ToolCatalog.getName, ["id": "ev-past", "character_offset": 1.5], "Argument 'character_offset' is not valid"),
            (ToolCatalog.updateName, ["id": "ev-future", "notes": 5], "Argument 'notes' is not valid: text was expected"),
            (ToolCatalog.updateName, ["id": "ev-future", "start": 9], "Argument 'start' is not valid: text was expected"),
            (ToolCatalog.updateName, ["id": "ev-future", "title": "X", "span": 3], "Argument 'span' is not valid: text was expected"),
            (ToolCatalog.updateName, ["id": "ev-future", "alarms": "soon"], "Argument 'alarms' is not valid: an array of offsets was expected"),
            (ToolCatalog.updateName, ["id": "ev-future", "alarms": [true]], "each alarm must be text like \"-15m\""),
            (ToolCatalog.deleteName, ["id": "ev-future", "confirm": "yes"], "Argument 'confirm' is not valid: true or false was expected"),
        ]
        for (tool, arguments, expected) in cases {
            let store = FakeEventStore()
            let result = await call(tool, arguments, store: store)
            #expect(result.isError, "\(tool) \(arguments)")
            #expect(result.text.contains(expected), "\(tool) \(arguments): \(result.text)")
            #expect(store.updated.isEmpty && store.deleted.isEmpty, "\(tool) \(arguments)")
        }
    }

    @Test("An argument a tool does not take is refused with the ones it takes, not ignored")
    func unknownArgumentsAreRefused() async {
        // The names of version 1: ignoring them would search from today and look like an answer.
        let old = await call(ToolCatalog.searchName, ["from": "2026-08-01", "to": "2026-08-31"])
        #expect(old.isError)
        #expect(
            old.text
                == "'from' is not an argument of calendar_search. It takes: calendars, from_date, limit, offset, query, to_date.")

        let status = await call(ToolCatalog.statusName, ["verbose": true])
        #expect(status.text == "'verbose' is not an argument of calendar_status. It takes no arguments.")

        let store = FakeEventStore()
        let delete = await call(
            ToolCatalog.deleteName, ["id": "ev-future", "confirm": true, "force": true], store: store)
        #expect(delete.isError && store.deleted.isEmpty)

        let long = await call(ToolCatalog.listName, [String(repeating: "n", count: 5000): 1])
        #expect(long.text.count < 200)
    }

    @Test("A whole number sent as 20.0 is taken as 20, and a null as not given")
    func lenientForms() async {
        let result = await Self.search.call(30, ["limit": 20.0, "offset": .null, "query": .null, "calendars": .null])
        #expect(!result.isError)
        #expect(result.text.hasPrefix("Showing 1–20 of 30 events."))
    }

    @Test("A day or a time that does not exist is refused, never moved to a nearby one")
    func nonexistentDatesAreRefused() async {
        // 29 March 2026 is the day Madrid's clocks skip from 02:00 to 03:00.
        for value in ["2026-02-30", "2026-04-31T09:00", "2026-03-29T02:30", "2026-02-30T09:00:00+01:00"] {
            let search = await call(ToolCatalog.searchName, ["from_date": .string(value)])
            #expect(search.isError, "\(value)")
            #expect(
                search.text.hasPrefix("Argument 'from_date' names a day or a time that does not exist: '\(value)'"),
                "\(value): \(search.text)")

            let store = FakeEventStore()
            let before = store.events.count
            let create = await call(
                ToolCatalog.createName, Self.createArguments.merging(["start": .string(value)]) { _, new in new },
                store: store)
            #expect(create.isError && store.events.count == before, "\(value)")
        }
        // The same days and times one step away do exist.
        for value in ["2026-02-28", "2024-02-29", "2026-03-29T03:00", "2026-02-28T09:00:00+01:00"] {
            #expect(!(await call(ToolCatalog.searchName, ["from_date": .string(value)])).isError, "\(value)")
        }
        let shapeless = await call(ToolCatalog.searchName, ["from_date": "30/02/2026"])
        #expect(shapeless.text.hasPrefix("Argument 'from_date' is not a date this server accepts: '30/02/2026'"))
    }

    @Test("An alarm further from the start than the range allows is refused, with the range")
    func alarmsOutOfReachAreRefused() async {
        let days = Configuration.alarmMinutesRange.upperBound / 1440
        let outOfReach: [Value] = [
            .array([.string("-\(days + 1)d")]), .array([.int(Configuration.alarmMinutesRange.upperBound + 1)]),
            .array([.string("9223372036854775807d")]),
        ]
        for alarms in outOfReach {
            let store = FakeEventStore()
            let result = await call(ToolCatalog.updateName, ["id": "ev-future", "alarms": alarms], store: store)
            #expect(result.isError && store.updated.isEmpty, "\(alarms)")
        }
        let tooFar = await call(ToolCatalog.updateName, ["id": "ev-future", "alarms": outOfReach[0]])
        #expect(tooFar.text.contains("an alarm must be within \(days) days of the start"))
        let atTheEdge = await call(
            ToolCatalog.updateName, ["id": "ev-future", "alarms": .array([.string("-\(days)d")])])
        #expect(!atTheEdge.isError)
    }

    // MARK: Errors and time

    @Test("An error repeats at most a short piece of what the caller sent")
    func errorsClipWhatTheyEcho() async {
        let long = String(repeating: "n", count: 5000)
        let clipped = String(repeating: "n", count: ToolStandard.echoWidth) + "…"
        let cases: [(tool: String, arguments: [String: Value])] = [
            (long, [:]),
            (ToolCatalog.getName, ["id": .string(long)]),
            (ToolCatalog.searchName, ["from_date": .string(long)]),
            (ToolCatalog.createName, Self.createArguments.merging(["calendar": .string(long)]) { _, new in new }),
            (ToolCatalog.updateName, ["id": "ev-future", "calendar": .string(long)]),
            (ToolCatalog.updateName, ["id": "ev-future", "title": "X", "span": .string(long)]),
            (ToolCatalog.updateName, ["id": "ev-future", "alarms": [.string(long)]]),
        ]
        for (tool, arguments) in cases {
            let result = await call(tool, arguments)
            #expect(result.isError, "\(arguments.keys)")
            #expect(result.text.contains(clipped), "\(arguments.keys): \(result.text.prefix(200))")
            #expect(!result.text.contains(clipped.dropLast() + "n"), "\(arguments.keys)")
            #expect(result.text.count < 1000, "\(arguments.keys)")
        }
    }

    @Test("An error lists a few candidates and counts the others")
    func errorsListAFewCandidates() async {
        let store = FakeEventStore(
            calendars: (0..<40).map {
                CalendarInfo(
                    title: "Invented calendar \(Self.padded($0))", sourceName: "Example account",
                    isWritable: true, isDefaultForNewEvents: false)
            }, events: [])
        let result = await call(
            ToolCatalog.createName, Self.createArguments.merging(["calendar": "Missing"]) { _, new in new },
            store: store)
        #expect(result.isError)
        let few = Configuration.fewNames
        #expect(result.text.contains("Invented calendar \(Self.padded(few - 1)) and \(40 - few) more"))
        #expect(!result.text.contains("Invented calendar \(Self.padded(few))"))
    }

    @Test("Every error this server words is far inside the longest error, whatever it is handed")
    func errorsAreShort() {
        let long = String(repeating: "n", count: 50_000)
        let errors: [ToolError] = [
            .notAuthorized(.denied), .notAuthorized(.writeOnly), .notAuthorized(.restricted),
            .notAuthorized(.notDetermined), .missingArgument("id"),
            .badArgument(name: "limit", reason: "a whole number was expected"), .unknownTool(long),
            .badDate(argument: "start", value: long), .nonexistentDate(argument: "start", value: long),
            .alarmTooFar, .rangeEndsBeforeItStarts, .endBeforeStart, .notFound(id: long),
            .unknownArgument(name: long, tool: ToolCatalog.searchName, taken: ["from_date", "to_date"]),
            .calendarNotFound(title: long, available: Array(repeating: long, count: 500)),
            .calendarReadOnly(title: long), .cannotMoveRecurringEvent(title: long),
            .confirmationRequired(action: "Deleting an event"), .nothingToUpdate, .storeFailure(long),
            .timedOut(seconds: 30),
        ]
        for error in errors {
            #expect(error.message.utf16.count <= ToolStandard.longestError / 5, "\(Diagnostics.kind(of: error))")
        }
    }

    @Test("A call that does not finish is abandoned at its deadline and answered with an error that says so")
    func stuckCallTimesOut() async {
        let store = FakeEventStore()
        store.searchDelay = .seconds(30)
        let started = ContinuousClock.now
        let result = await call(ToolCatalog.searchName, Self.august, store: store, timeout: .seconds(1))
        #expect(result.isError)
        #expect(result.text.hasPrefix("The call did not finish within 1 seconds and was abandoned."))
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test("The deadline of a call, and the time a search may spend, are within the standard's time limit")
    func deadlineIsWithinTheTimeLimit() {
        #expect(Configuration.callTimeout <= ToolStandard.timeLimit)
        #expect(Configuration.scanBudget < Configuration.callTimeout)
    }

    @Test("One query never asks EventKit for more than it serves whole")
    func piecesAreInsideEventKitsSpan() {
        // EKEventStore.h: a predicate longer than four years is shortened to its first four.
        #expect(Configuration.scanChunkDays < 4 * 365)
        #expect(Configuration.longestScanDays % Configuration.scanChunkDays == 0)
    }

    // MARK: What the model reads

    @Test("The instructions and every tool description are within the longest a client keeps")
    func textsAreWithinTheLimit() {
        #expect(
            ToolStandard.overlongTexts(instructions: CalendarMCPServer.instructions, catalog: ToolCatalog.all())
                .isEmpty)
        #expect(!CalendarMCPServer.instructions.isEmpty)
    }

    private func properties(of tool: Tool) -> [String: [String: Value]] {
        guard case .object(let schema) = tool.inputSchema,
            case .object(let properties)? = schema["properties"]
        else { return [:] }
        return properties.compactMapValues(\.objectValue)
    }

    @Test("Every listing's schema states the range and default of limit and offset that the code enforces", arguments: listings)
    private func schemaStatesThePage(_ listing: Listing) throws {
        let tool = try #require(ToolCatalog.all().first { $0.name == listing.tool })
        let limit = try #require(properties(of: tool)["limit"])
        #expect(limit["minimum"]?.intValue == listing.limits.lowerBound)
        #expect(limit["maximum"]?.intValue == listing.limits.upperBound)
        #expect(limit["default"]?.intValue == listing.defaultLimit)
        let offset = try #require(properties(of: tool)["offset"])
        #expect(offset["minimum"]?.intValue == Configuration.offsetRange.lowerBound)
        #expect(offset["maximum"]?.intValue == Configuration.offsetRange.upperBound)
        #expect(offset["default"]?.intValue == 0)
        // The description states the same maximum, taken from the same constant.
        #expect(tool.description?.contains("limit (up to \(listing.limits.upperBound))") == true)
        #expect(tool.description?.contains("\(listing.defaultLimit)") == true)
    }

    @Test("The window's schema states the range and default the code enforces")
    func schemaStatesTheWindow() throws {
        let tool = try #require(ToolCatalog.all().first { $0.name == ToolCatalog.getName })
        let size = try #require(properties(of: tool)["max_characters"])
        #expect(size["minimum"]?.intValue == Configuration.maxCharactersRange.lowerBound)
        #expect(size["maximum"]?.intValue == Configuration.maxCharactersRange.upperBound)
        #expect(size["default"]?.intValue == Configuration.defaultMaxCharacters)
        #expect(Configuration.defaultMaxCharacters == ToolStandard.usualPage)
        let offset = try #require(properties(of: tool)["character_offset"])
        #expect(offset["minimum"]?.intValue == 0 && offset["default"]?.intValue == 0)
        #expect(
            tool.description?.contains("max_characters (up to \(Configuration.maxCharactersRange.upperBound))") == true)
        #expect(tool.description?.contains("up to \(Configuration.defaultMaxCharacters) characters in all") == true)
    }

    @Test("Every number in a schema has a range, and every default lies inside it")
    func everyNumberHasARange() {
        for tool in ToolCatalog.all() {
            for (name, property) in properties(of: tool) where property["type"]?.stringValue == "integer" {
                guard let minimum = property["minimum"]?.intValue, let maximum = property["maximum"]?.intValue
                else {
                    Issue.record("\(tool.name).\(name) states no range")
                    continue
                }
                if let value = property["default"]?.intValue {
                    #expect((minimum...maximum).contains(value), "\(tool.name).\(name)")
                }
            }
        }
    }

    @Test("Only the standard names page, window and date a result")
    func standardArgumentNames() {
        let standard: Set = ["limit", "offset", "from_date", "to_date", "character_offset", "max_characters"]
        // `start` and `end` are not here: they are the two ends of the event a write sets.
        let lookalikes: Set = [
            "max", "count", "max_results", "page", "page_size", "skip", "from", "to", "since", "until",
            "after", "before", "start_date", "end_date", "max_chars", "max_length", "char_offset", "cursor",
        ]
        var used: Set<String> = []
        for tool in ToolCatalog.all() {
            let names = Set(properties(of: tool).keys)
            #expect(names.isDisjoint(with: lookalikes), "\(tool.name)")
            used.formUnion(names.intersection(standard))
        }
        #expect(used == standard)
    }

    @Test("No date of a search is required: a call with no argument is one usual page")
    func searchRequiresNothing() throws {
        let tool = try #require(ToolCatalog.all().first { $0.name == ToolCatalog.searchName })
        #expect(tool.inputSchema.objectValue?["required"] == nil)
    }

    @Test("The texts the model reads state the sizes the code enforces")
    func textsStateTheSizes() async throws {
        let instructions = CalendarMCPServer.instructions
        #expect(instructions.contains("no more than \(Configuration.longestScanDays) days"))
        #expect(instructions.contains("after \(Configuration.callTimeout.components.seconds) seconds"))

        let search = try #require(ToolCatalog.all().first { $0.name == ToolCatalog.searchName }?.description)
        #expect(search.contains("no more than \(Configuration.longestScanDays) days"))
        #expect(search.contains("than \(Configuration.rowFieldWidth) characters is clipped"))
        let delete = try #require(ToolCatalog.all().first { $0.name == ToolCatalog.deleteName }?.description)
        #expect(delete.contains("up to \(Configuration.deletedRecordCharacters) characters"))

        let status = await call(ToolCatalog.statusName).text
        #expect(status.contains("\(Configuration.defaultSearchLimit) events by default, \(Configuration.searchLimitRange.upperBound) at most"))
        #expect(status.contains("\(Configuration.longestScanDays) days in one call"))
        #expect(status.contains("\(Configuration.callTimeout.components.seconds) seconds"))
    }
}

# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Do not modify or delete an existing calendar event.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real calendar, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

**Then take the gentlest route that answers it:** read without writing; failing that, create your own event and work on that; failing that, ask the owner to make a throwaway one; failing that, work on a copy. Touching what the owner made is the last resort, has to have been named in the ask, and has to be undoable. Anything you are allowed to create must be clearly named `TESTING: ...` and removed in the same session.

## What this is

A local MCP server (Swift 6, stdio transport) exposing the macOS Calendar app through `EventKit`. No network, no credential, no cloud API — iCloud is only the sync engine, and the gate is TCC consent. **No third-party dependency**: `Package.swift` lists none, and the MCP protocol (JSON-RPC over stdio) is `MCPServer.swift` over Foundation. Adding a package needs the owner's say-so.

**`MCPServer.swift`, `Value.swift`, `ToolStandard.swift` and the tests `MCPProtocolTests.swift` and `ToolStandardTests.swift` are copied unchanged into every one of the owner's MCP servers** (the test files differ only in their `@testable import`). A change to one is made to every copy in the same piece of work; never let a copy drift.

`ToolStandard.swift` holds what every tool here must keep to: the longest result, description and error, the time a call may take, the fixed wording of each notice that says what a result left out (`Notice`), and the guard `MCPServer.swift` passes every result through. A tool bounds its own result and says how to get the rest; the guard only catches the one that forgot.

## Apple frameworks

[EventKit](https://developer.apple.com/documentation/eventkit) is the whole of it. Used: `EKEventStore` (authorisation, fetch, save, remove), `EKEvent`, `EKCalendar`, `EKAlarm`, `EKRecurrenceRule`/`EKRecurrenceEnd` (read only), `EKParticipant` (read only), `EKSpan`. Consent key: [`NSCalendarsFullAccessUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nscalendarsfullaccessusagedescription).

## Native surface not used

The framework offers more than this server exposes. Before proposing a tool, check it against this list rather than assuming.

- `EKReminder` — reminders are a separate entity behind a separate permission.
- `EKStructuredLocation` — a location object with a geofence. `event.location` is plain text here, which is why there is no location-based alarm.
- `EKRecurrenceDayOfWeek`, and constructing an `EKRecurrenceRule` at all — recurrence is read and summarised, never written.
- `EKVirtualConferenceDescriptor`/`EKVirtualConferenceProvider` — for an app that supplies conference links.
- `EKParticipant` writes — EventKit cannot invite anyone; that is Calendar.app's job.

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-calendar-mcp | grep NSCalendarsFullAccessUsageDescription
```

## Architecture

**Apple silicon only, deliberately.** `scripts/pack.sh` builds for arm64 alone — a plain `swift build -c release`, no `--arch` flags — and fails if the binary
holds any other architecture. A universal build doubles the bundle for an architecture
macOS 26 is the last release to support. Do not add an x86_64 slice back.

**How a tool keeps to the tool standard here.** Sizes are constants in `Configuration`, and the schemas, the descriptions, the instructions and `calendar_status` quote them by interpolation, never as literals; `VersionTests` holds the two figures the manifest states to them. `Arguments.int` moves a quantity (`limit`, `offset`, a window) into its range and collects the sentence that says so in `notices`; a wrong type, an argument the tool does not take, a date that does not exist and an alarm out of reach are refused. `calendars_list` sorts its rows into an order it states and goes through `ToolStandard.page`. `calendar_get` renders the whole record with one page of attendees and cuts it with `ToolStandard.window`. Both render through `ToolStandard.fitting`, so a tool never leans on the guard. `BoundsTests` holds every bound, notice and length to this: a new listing takes `limit` and `offset` through `Arguments.page` and gets an entry in its `listings`.

**`calendar_search` pages at the source.** EventKit has no cursor, no order of its own, and silently shortens a query longer than four years (`EKEventStore.h`). So `CalendarTools.scan` walks the range in pieces of `Configuration.scanChunkDays`, oldest first, sorts each piece, and stops when the page is full, the range ends, `Configuration.longestScanDays` have been looked at or `Configuration.scanBudget` has run out. Which of the four it was decides the notice: an exact total, "more exist", `Notice.scanStopped` or `Notice.partial`, the last two with the `from_date` that continues. The store's `search` therefore answers for one piece and never pages.

**Writes answer with a receipt, not the event.** `create_event` and `update_event` return the title, the time and the id; `delete_event` returns the record once, as `create_event` arguments, up to `Configuration.deletedRecordCharacters`, because nothing can read it afterwards.

**Every call runs under `Deadline`**, which abandons it after `Configuration.callTimeout`. EventKit's queries are synchronous and cannot be cancelled, so an abandoned write may still land; the error says so.

## Diagnostics

Logs go to stderr through `Diagnostics`, which the host captures (Claude Desktop writes it to `~/Library/Logs/Claude/mcp-server-<name>.log`). stdout is the JSON-RPC stream: never `print`. The API takes no free-form text on purpose. Do not add one, and do not log an argument, a result, an error's `localizedDescription` or an identifier; log a fixed event, the tool name, the error's kind and a duration.

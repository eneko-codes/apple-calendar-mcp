<p align="center">
  <img src="extension/icon.png" width="128" height="128" alt="apple-calendar-mcp icon">
</p>

# apple-calendar-mcp

A local MCP server, written in Swift, exposing the macOS **Calendar** app to Claude
through `EventKit`. It ships as a Claude extension.

No network, no credentials, no cloud API. iCloud is only the sync engine that fills the
local calendar store; this server reads and writes that local store, and the gate is
macOS **privacy consent** rather than authentication.

Not affiliated with or endorsed by Apple Inc.

## Requirements

- macOS 15 or later
- Swift 6.0 or later (Xcode 26 ships it)
- A code signing identity. Ad-hoc works, but every rebuild then asks for permission
  again — see [Signing](#signing-and-why-it-is-not-optional).

## Tools

| Tool | Kind | What it does |
|---|---|---|
| `calendar_status` | read | Reports the permission, the binary in use and the sizes results keep to. Reads no events. |
| `calendars_list` | read | Calendars, a page at a time, with their account and whether they accept writes. |
| `calendar_search` | read | Events, a page at a time, oldest first, from today onwards or between `from_date` and `to_date`. Echoes the range, time zone and calendars it actually used. |
| `calendar_get` | read | One event's record, including whether it is past, in progress or upcoming, with a page of its attendees; a long record a window at a time. |
| `create_event` | write | Adds an event and answers with a short receipt. Cannot invite attendees or create a series. |
| `update_event` | write | Changes fields, including on a past event, and answers with a short receipt. Can move an event to another calendar; refuses that for a recurring one. |
| `delete_event` | **destructive** | Permanent. Requires `confirm: true`. Works on past events too. Returns what it removed, once. |

## Bounded results

No result is longer than a client passes into the conversation, and none leaves something
out without saying so. What a result does not hold is announced in its first lines, with
the exact arguments that return the rest.

| Tool | A call with no optional argument returns | The rest |
|---|---|---|
| `calendars_list` | 50 calendars, by name | `limit` (up to 200) and `offset` |
| `calendar_search` | 40 events from today onwards, oldest first | `limit` (up to 100) and `offset`; `from_date` and `to_date` |
| `calendar_get` | 10,000 characters of the record, with its first 50 attendees | `character_offset` and `max_characters` (up to 20,000); `limit` (up to 200) and `offset` for attendees |

A search row clips a title, a calendar name or a location longer than 80 characters and
leaves out notes and attendees; `calendar_get` has them. A `limit`, an `offset` or a window
size outside its range is moved to the nearest allowed value, and the result says which
one was used. A wrong type, an argument the tool does not take, a date that does not exist
(30 February, a local time the clocks skip) and an alarm more than 366 days from the start
are refused instead.

`create_event` and `update_event` answer with a receipt: the title, when the event is and
its id. `delete_event` returns the record it removed once, as the arguments `create_event`
takes, up to 38,000 characters, because nothing can read the event afterwards: read one
with long notes through `calendar_get` first.

A call that has not finished after 30 seconds is abandoned and answered with an error.
EventKit's calls cannot be cancelled, so a write abandoned that way may still go through.

The figures above are constants in `Sources/CalendarMCPCore/Configuration.swift`; the tool
descriptions, the schemas and `calendar_status` quote them from there.

### Upgrading from 1.x

| Tool | 1.x | 2.0 |
|---|---|---|
| `calendar_search` | `from`, required | `from_date`, optional: without it the search starts today. `from` is refused |
| `calendar_search` | `to`, required, excluded | `to_date`, optional, **included**: a plain day runs to its end. `to` is refused |
| `calendar_search` | a range over 366 days was refused | any range; one call looks at 1,464 days and says how to continue |
| `calendar_search` | `limit` up to 200, 50 by default | up to 100, 40 by default |
| `calendars_list` | no arguments | `limit`, `offset` |
| `calendar_get` | `id` | `id`, `limit`, `offset`, `character_offset`, `max_characters` |
| `create_event`, `update_event` | answered with the whole event | answer with a receipt |
| `delete_event` | printed the notes twice, with no bound | prints each field once, up to 38,000 characters |

## Frameworks and APIs

| Used | For | Reference |
|---|---|---|
| EventKit — `EKEventStore`, `EKEvent`, `EKCalendar`, `EKAlarm`, `EKRecurrenceRule`, `EKParticipant`, `EKSpan` | Every read and write | [EventKit](https://developer.apple.com/documentation/eventkit) |
| `NSCalendarsFullAccessUsageDescription` | The consent string macOS shows | [Information Property List](https://developer.apple.com/documentation/bundleresources/information-property-list/nscalendarsfullaccessusagedescription) |

EventKit areas this server does not use: `EKReminder` (a separate entity with its own
permission), `EKStructuredLocation` (`location` is carried as plain text, so no
location-based alarm), `EKVirtualConferenceProvider`, and `EKRecurrenceDayOfWeek` —
recurrence rules and participants are read and summarised, never constructed.

## The rules worth knowing before you use it

**Dates take exactly three forms:**

```
2026-08-12                  a whole day, local time
2026-08-12T09:00            local time
2026-08-12T09:00:00+02:00   explicit offset
```

An event whose `start` and `end` are both plain days is all-day. There is no separate
flag — two sources of truth for the same fact drift apart.

**Occurrences of a repeating series share one EventKit identifier.** EventKit gives every
Tuesday of a weekly meeting the same `eventIdentifier`, so an id alone cannot say which
one you meant. Occurrence ids therefore look like:

```
A1B2C3D4-…-C7D1|2026-08-14T08:00:00Z
```

The separator is `|` and not `:`, because a CalDAV identifier can itself contain a colon —
which real ones do. `span` (`this` or `future`) then decides whether a write hits one
occurrence or every later one. It defaults to `this`, so a series is never rewritten by
accident.

**EventKit cannot invite attendees.** `EKParticipant` is read-only. Existing guests are
reported, but `create_event` cannot convene anyone — that has to happen in Calendar.app.
It also cannot create repeating events.

**A search is walked in pieces, and one call looks at four years at most.** EventKit
silently shortens a query longer than four years to its first four, and promises no order.
So `calendar_search` asks for 366 days at a time, oldest first, sorts each piece, and stops
as soon as its page is full. One call looks at no more than 1,464 days: past that the result
says where it stopped and the `from_date` that continues from there. `from_date` alone
runs on with no end; `to_date` alone covers the 1,464 days up to it; with neither the
search starts today. Both dates are included.

**Moving an event to another calendar is a whole-series operation.** `update_event`'s
`calendar` argument sets `EKEvent.calendar` and re-saves — the same mechanism
Calendar.app itself uses. But a recurring event's calendar is a property of the series,
not of one occurrence, and EventKit does not define splitting a series across calendars,
so `update_event` refuses `calendar` outright for a recurring event, `span` notwithstanding.

`calendar_search`'s own `calendars` argument fails **closed**: a name that matches
nothing yields no events, never every event. That is not the obvious behaviour — EventKit
reads an empty calendar filter as *every* calendar — and getting it wrong would turn a
narrowed search into an unfiltered one.

## Install

### 1. Build the bundle

```bash
security find-identity -v -p codesigning   # copy the 40-character hash of an Apple Development or Developer ID Application identity
MCPB_SIGN_IDENTITY="<identity hash>" ./scripts/pack.sh
```

Pass the hash, not the certificate's name: `pack.sh` prints the identity it signs with,
and the name is yours.

That builds an arm64 (Apple silicon only) release binary, signs it, checks the embedded
`Info.plist` survived both linking and signing, prints the designated requirement, and
writes `dist/apple-calendar-mcp.mcpb`. It fails loudly rather than shipping a bundle that
would silently refuse to work.

### 2. Install it

Open `dist/apple-calendar-mcp.mcpb` with Claude. Then **quit Claude Desktop completely and
reopen it** — reinstalling does not replace a server process that is already running, and
the old one keeps answering.

### 3. Grant the permission

Call `calendar_status`; the first call that needs data raises the consent dialog. Approve
**full access**. The entry appears as **apple-calendar-mcp** under
System Settings → Privacy & Security → Calendars
(Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Calendarios).

macOS 14 split calendar access into full and write-only. **Write-only is not enough**: it
cannot read events back, so the server could not confirm what it created. `calendar_status`
says so explicitly if that is the state you land in.

The binary is **its own privacy subject**: Claude Desktop launches MCP servers through
`Contents/Helpers/disclaimer`, which calls `responsibility_spawnattrs_setdisclaim`, so the
child cannot inherit the host app's permissions — and Claude.app declares no Calendars
usage description anyway. Hence the `Info.plist` embedded at link time.

If no dialog ever appears:

```bash
otool -P extension/server/apple-calendar-mcp | grep NSCalendarsFullAccessUsageDescription
```

### Signing, and why it is not optional

`swift build` leaves a signature the linker generated, flagged `linker-signed`. macOS
treats that as signed by nobody: it produces **no designated requirement**, so there is
nothing to anchor a permission to except the binary's cdhash — and every rebuild changes
that. Worse, a linker-signed binary never gets a consent dialog at all; the request
returns with the status still "not determined".

Signing with a real certificate produces a requirement anchored to the bundle identifier
and the certificate instead:

```
designated => identifier "codes.eneko.apple-calendar-mcp" and anchor apple generic
              and certificate leaf[subject.CN] = "Apple Development: …"
```

That survives rebuilds: same identity, same requirement, no second consent dialog. `pack.sh` prints the requirement on
every build, so a silent regression to ad-hoc is visible immediately.

**Changing certificate re-prompts once.** The requirement quotes the certificate, so
moving between ad-hoc, Apple Development and Developer ID each costs one fresh round of
consent. Notarisation requires a Developer ID Application certificate. Check a
certificate's expiry date in Keychain Access rather than assuming how long it lasts.

### Preparing something to distribute

```bash
MCPB_HARDENED=1 MCPB_SIGN_IDENTITY="<Developer ID Application hash>" ./scripts/pack.sh
```

That adds the hardened runtime and a secure timestamp, which notarisation requires.
EventKit is reached directly and needs no entitlements.

## Tool switches

Plug and play: there is nothing to configure. Every calendar is reachable, the sizes in
[Bounded results](#bounded-results) are fixed, and `calendar_status` reports them so a
caller does not have to guess or read the source.

Every tool can be turned on and off individually, because the bundle declares them all in
its manifest. That is where policy lives — not in this code. Turning off `create_event`,
`update_event` and `delete_event` leaves a strictly read-only server.

**Reinstalling may reset the switches.** Check them after every install.

## Manual registration instead

```json
{
  "mcpServers": {
    "Apple Calendar": {
      "command": "/absolute/path/to/apple-calendar-mcp/.build/release/apple-calendar-mcp"
    }
  }
}
```

You lose the per-tool switches. Do not do both at once: two registrations under the same
display name collide, and `calendar_status` prints the binary path precisely so you can
tell which one answered.

## Known limits

- **No repeating events can be created**, and no attendees invited. Both are EventKit
  limitations, not choices.
- **A recurring event cannot change calendar.** Unlike the two above, this is this
  server's own choice, not EventKit's: nothing documents what happens if you try, and a
  wrong guess would corrupt a real series. See "the rules worth knowing" above.
- **Identifiers are not durable.** Resynchronising an account can regenerate them, which
  is why every workflow starts with a search.
- **An event that started before the searched range** appears with its real start date and
  an `ongoing` marker. It genuinely overlaps the range; the marker exists so that does not
  read as a bug.
- **A search cannot say how many events match when it stops at a full page** before the end
  of a range longer than 366 days: it says that more exist and how to get them. A range
  inside 366 days always gets an exact total.
- **`delete_event` cuts a record longer than 38,000 characters**, and says so first. The
  rest is gone with the event.

## Development

```bash
swift build
swift test
```

All tests run against an in-memory fake at a fixed instant. They need no permissions and
never touch a real calendar — see `CLAUDE.md`, whose first section is the rule that makes
that non-negotiable.

`MCPServer.swift`, `Value.swift` and `ToolStandard.swift`, with their tests
`MCPProtocolTests.swift` and `ToolStandardTests.swift`, are the same files in every one of
the author's MCP servers. `BoundsTests.swift` holds this server's own tools to the limits
`ToolStandard.swift` sets.

Manual verification against a live calendar is the owner's job.

## Licence

MIT.

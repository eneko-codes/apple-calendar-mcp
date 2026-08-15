# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## HARD RULE — THE OWNER'S CALENDAR IS NOT YOURS TO EDIT

**It is FORBIDDEN to modify or delete any event the owner made.** This rule outranks
every other instruction in this file. It applies to every agent and every session, with
no "just this once" and no restoring-it-afterwards.

Never:

- update or delete a pre-existing event, for any reason, however small the change;
- read a real event to "see what the shape is" — the fixtures show the shape;
- create a scratch calendar, or write into a calendar the owner did not sanction;
- read the Calendar store directly from disk;
- leave anything behind that was not there when the session started.

**One narrow exception, granted by the owner.** A **temporary test event** may be
created, exercised and deleted, provided that:

- its title marks it as disposable at a glance (`ZZTest …`);
- it is placed far enough from real time that it cannot be mistaken for a commitment, and
  never invites anyone — `EventKit` cannot invite, and it must stay that way;
- it is deleted in the same session that made it, even if the session is going badly;
- the owner is told it existed and that it is gone.

The exception covers events this agent created and nothing else. Note the trap: this
server refuses to edit an event that has already ended, so a test event created in the
past **cannot be deleted through the tools** and becomes exactly the litter this rule
forbids. Create test events in the future.

**Fixtures first, always.** `FakeEventStore` drives the whole tool layer with invented
titles and dates, and that is where a change is proven. Reach for a live test only for
code the fake cannot reach at all — everything below the `EventStore` seam, where
`SystemEventStore` talks to Apple.

Allowed without asking, because none of it touches calendar data:

| Action | Why it is safe |
|---|---|
| `swift build`, `swift test` | Tests run against the in-memory fake |
| `initialize`, `tools/list` over stdio | Protocol only; no store is opened |
| `EKEventStore.authorizationStatus(for:)` | Returns an enum, reads no events |
| `otool -P` on the built binary | Inspects the embedded Info.plist |

Full verification against a real calendar remains the **owner's** job, by hand, with MCP
Inspector. `verification.md` is the script for it. The test-event exception above is
for proving one specific below-the-seam behaviour, not for running that script.

## Language

**Everything in this repository is written in English** — code, comments, tool
descriptions, error messages, documentation and commit messages. The one exception is
literal macOS UI strings quoted inside permission instructions, which must match what
is on screen (for example the System Settings pane name in the user's locale).

## What this is

A local MCP server (Swift 6, stdio transport) exposing the macOS Calendar app through
`EventKit`. There is no network, no credential and no cloud API: iCloud is only the
sync engine that fills the local store, and the gate is TCC consent.

This server covers **calendars only**. Reminders are a separate EventKit entity with a
separate TCC permission and will get their own repository.

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

`Sources/CalendarMCPCore` holds everything; `Sources/apple-calendar-mcp/main.swift` is
a launcher that exists only because a Swift executable target cannot be imported by a
test target.

**`EventStore` is the seam.** Dispatch, formatting and argument decoding go through the
protocol and never touch EventKit, so the tool layer is fully testable against
`FakeEventStore`. Only `SystemEventStore` talks to Apple.

**`ToolCatalog` is the authorisation surface.** A tool absent from `ToolCatalog.all()`
cannot be called, and its name is the label on the permission switch in Claude Desktop.
Per the owner's plug-and-play rule, `Configuration` is now a plain enum of fixed
constants — no `user_config`, nothing to parse — so a tool description states a limit
the server always enforces rather than one a person configured.

## Invariants worth protecting

- **History is not editable.** `update_event` and `delete_event` refuse an event that
  has already ended. This is a design rule, not a technical limit: a finished event is
  evidence of what happened. The boundary is `end <= now`, so an event in progress can
  still be edited.
- **Occurrences of a recurring series share one `eventIdentifier`.** EventKit does not
  give each occurrence its own id, so a single occurrence is addressed by the composite
  `<eventIdentifier>|<occurrence-start-ISO>`. The separator is `|` and not `:` because
  a CalDAV `eventIdentifier` can itself contain a colon.
- **`span` picks between one occurrence and the rest of the series** (`this` /
  `future`), mapping to `EKSpan`. Defaulting to `future` would silently rewrite history
  the caller never asked about.
- **EventKit cannot invite attendees.** `EKParticipant` is read-only; `create_event`
  cannot convene anyone. The tool description must keep saying so.
- **Date input accepts exactly three forms:** `YYYY-MM-DD` (whole day),
  `YYYY-MM-DDTHH:MM` (local), and full ISO 8601 with offset. Anything else is an error
  naming all three.
- **All-day is inferred**, not flagged: `start` and `end` both date-only means all-day.
- **Every search echoes the resolved range and time zone.** It is how a model catches
  its own off-by-one-day before the user does.
- **A search range is capped at `Configuration.maximumRangeDays`, fixed at 366 days.**
  EventKit degrades badly over long spans and a mistaken range can otherwise sweep a
  decade. The constant is interpolated into the tool description, so the two cannot
  drift apart.
- **There is no calendar allow-list.** The owner removed it, along with the connector
  setting that used to configure it, in favour of plug-and-play: every calendar
  `calendars_list` reports is reachable by every other tool. The boundary is Claude
  Desktop's own per-tool permission switch, not anything enforced in this file.
- **`calendar_search`'s own `calendars` filter must fail closed.** This is the per-call
  argument, unrelated to the removed allow-list above.
  `predicateForEvents(withStart:end:calendars:)` reads an **empty** array as *every*
  calendar, so a filter that matched nothing would silently widen into no filter at all.
  Observed live: naming one calendar that did not exist returned events from every
  calendar on the machine. `resolveCalendars` therefore returns a three-way
  `ResolvedScope` and never an empty array — a restriction that fails open is worse than
  one that errors. This lives below the `EventStore` seam, so no test can reach it; the
  guard is the type.
- **No property may declare a union `type`.** Claude Desktop's schema sanitiser drops a
  property whose `type` is `["string", "null"]` or `["array", "null"]` and hands the
  model a bare `{}` in its place. An untyped array is then serialised to a string before
  it leaves the client and is rejected on arrival; an untyped string survives by luck,
  which is what hid the fault. Found in the sibling contacts server, where it made every
  list field of `update_contact` unusable; `update_event.alarms` had it too and only
  looked healthy because nothing had touched alarms yet. So `update_event` clears with
  `""` and `[]` rather than `null` — both of which `FieldEdit` already read as
  `.cleared` — and a test walks the whole catalogue to keep unions out.
- **`calendar_status` reports the effective limits.** They are fixed constants now, not
  settings, but stating them plainly still beats a caller having to guess or read the
  source.
- **A truncated search must say what it withheld.**
- **stdout carries JSON-RPC and nothing else.**

## Packaging as a Claude extension

`extension/manifest.json` plus `scripts/pack.sh` produce `dist/apple-calendar-mcp.mcpb`,
a zip with `manifest.json` at its root. `server.type` is `"binary"` — no Node, no Python,
just the Swift binary.

The one thing in the manifest that is load-bearing: **the `tools` array is what creates
the per-tool switches.** Claude Desktop lists and toggles tools from the manifest, before
the server has ever run. A tool missing from that array has no switch. Keep it in step
with `ToolCatalog`.

There is no `user_config` and `mcp_config.args` is empty: every former setting is now a
fixed constant in `Configuration`, per the owner's plug-and-play rule. The only place
left for a person to change this server's behaviour is the per-tool permission switch in
Claude Desktop.

`pack.sh` checks everything here that fails silently otherwise: that the embedded
`Info.plist` survived both linking and signing, that the signature is not `linker-signed`,
that a designated requirement exists at all, and that the executable bit survived the
zip. The MCPB
spec does not promise the installer preserves file modes; if a future Claude release
drops it, the symptom is a server that never starts and the fix is `chmod +x` on the
installed copy under `~/Library/Application Support/Claude/Claude Extensions/`.

## TCC notes

Claude Desktop spawns MCP servers through `Contents/Helpers/disclaimer`, which calls
`responsibility_spawnattrs_setdisclaim`. The child is therefore **its own TCC subject**
and cannot borrow the host app's usage descriptions — Claude.app declares none for
Calendars. Hence the embedded `Resources/Info.plist`.

macOS 14 split calendar access in two: `requestFullAccessToEvents()` and
`requestWriteOnlyAccessToEvents()`, with `EKAuthorizationStatus` gaining `.fullAccess`
and `.writeOnly`. This server needs full access; write-only cannot read back what it
created. Verified against the macOS 26.5 SDK headers.

**A linker-signed binary gets no TCC prompt at all.** `swift build` leaves exactly that,
and it produces no designated requirement, so nothing is ever logged and the status stays
"not determined". `pack.sh` re-signs and prints the requirement; if that line is empty the
build is broken in a way nothing else will show.

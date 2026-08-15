<p align="center">
  <img src="extension/icon.png" width="128" height="128" alt="apple-calendar-mcp icon">
</p>

# apple-calendar-mcp

A local MCP server, written in Swift, exposing the macOS **Calendar** app to Claude
through `EventKit`. It ships as a Claude extension.

No network, no credentials, no cloud API. iCloud is only the sync engine that fills the
local calendar store; this server reads and writes that local store, and the gate is
macOS **privacy consent** rather than authentication.

Reminders are a separate EventKit entity with a separate permission, and will get their
own repository.

Not affiliated with or endorsed by Apple Inc.

## Requirements

- macOS 15 or later
- Swift 6.0 or later (Xcode 26 ships it)
- A code signing identity. Ad-hoc works, but every rebuild then asks for permission
  again — see [Signing](#signing-and-why-it-is-not-optional).

## Tools

| Tool | Kind | What it does |
|---|---|---|
| `calendar_status` | read | Reports the permission, the binary in use and the effective limits. Reads no events. |
| `calendars_list` | read | Every calendar, its account, and whether it accepts writes. |
| `calendar_search` | read | Events in a date range. Echoes the range, time zone and calendars it actually used. |
| `calendar_get` | read | Full record for one id, including whether it can still be edited. |
| `create_event` | write | Adds an event. Cannot invite attendees or create a series. |
| `update_event` | write | Changes fields. Refuses events that have ended. |
| `delete_event` | **destructive** | Permanent. Requires `confirm: true`. Refuses events that have ended. |

## The rules worth knowing before you use it

**History is not editable.** `update_event` and `delete_event` refuse any event whose end
time has passed. A finished event is the record of what happened. The boundary is the
*end*, not the start — a meeting that is currently overrunning can still be extended.

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

**Search is capped at 366 days, fixed.** EventKit degrades badly over long spans and a
mistyped range can otherwise sweep a decade. The cap is interpolated into the tool's own
description, so Claude sees the real limit rather than a stale one.

`calendar_search`'s own `calendars` argument fails **closed**: a name that matches
nothing yields no events, never every event. That is not the obvious behaviour — EventKit
reads an empty calendar filter as *every* calendar — and getting it wrong would turn a
narrowed search into an unfiltered one.

## Install

### 1. Build the bundle

```bash
MCPB_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/pack.sh
```

That builds a universal (arm64 + x86_64) release binary, signs it, checks the embedded
`Info.plist` survived both linking and signing, prints the designated requirement, and
writes `dist/apple-calendar-mcp.mcpb`. It fails loudly rather than shipping a bundle that
would silently refuse to work.

```bash
security find-identity -v -p codesigning
```

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
cannot read events back, so the server could neither confirm what it created nor enforce
the rule against editing the past. `calendar_status` says so explicitly if that is the
state you land in.

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

That survives rebuilds — verified by installing two builds with different cdhashes and
the same identity, with no second consent dialog. `pack.sh` prints the requirement on
every build, so a silent regression to ad-hoc is visible immediately.

**Changing certificate re-prompts once.** The requirement quotes the certificate, so
moving between ad-hoc, Apple Development and Developer ID each costs one fresh round of
consent. An Apple Development certificate is valid for about a year; a Developer ID
Application certificate lasts five and is what notarisation requires.

### Preparing something to distribute

```bash
MCPB_HARDENED=1 MCPB_SIGN_IDENTITY="Developer ID Application: …" ./scripts/pack.sh
```

That adds the hardened runtime and a secure timestamp, which notarisation requires.
EventKit is reached directly and needs no entitlements.

## Tool switches

Plug and play: there is nothing to configure. Every calendar is reachable, the search
range and default page size are fixed at 366 days and 50 results, and `calendar_status`
reports them so a caller does not have to guess or read the source.

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
- **Identifiers are not durable.** Resynchronising an account can regenerate them, which
  is why every workflow starts with a search.
- **An event that started before the searched range** appears with its real start date and
  an `ongoing` marker. It genuinely overlaps the range; the marker exists so that does not
  read as a bug.

## Development

```bash
swift build
swift test
```

35 tests, all against an in-memory fake at a fixed instant. They need no permissions and
never touch a real calendar — see `CLAUDE.md`, whose first section is the rule that makes
that non-negotiable.

Manual verification against a live calendar is the owner's job; `verification.md` is
the script for it.

## Licence

MIT.

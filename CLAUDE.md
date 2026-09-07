# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Do not modify or delete an existing calendar event.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real calendar, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

**Then take the gentlest route that answers it:** read without writing; failing that, create your own event and work on that; failing that, ask the owner to make a throwaway one; failing that, work on a copy. Touching what the owner made is the last resort, has to have been named in the ask, and has to be undoable. Anything you are allowed to create must be clearly named `TESTING: ...` and removed in the same session.

## What this is

A local MCP server (Swift 6, stdio transport) exposing the macOS Calendar app through `EventKit`. No network, no credential, no cloud API — iCloud is only the sync engine, and the gate is TCC consent.

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-calendar-mcp | grep NSCalendarsFullAccessUsageDescription
```

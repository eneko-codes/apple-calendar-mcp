# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Do not modify or delete existing calendar events. Test events may be created but must be clearly named `TESTING: ...` and cleaned up when done.

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

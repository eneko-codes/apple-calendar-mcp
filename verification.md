# Manual verification

Everything below runs against **your real calendar**, which is why no agent may run it
(see the hard rule in `CLAUDE.md`). Work through it yourself, in order.

```bash
npx @modelcontextprotocol/inspector ./.build/release/apple-calendar-mcp
```

## 0 — Before you start

In Calendar.app, create a calendar named `ZZTest` and put three events in it:

| Event | When | Why |
|---|---|---|
| `ZZ Past` | yesterday, 09:00–10:00 | the history rule |
| `ZZ Future` | next week, 16:00–16:30, with a location and a 1-hour alarm | the normal path |
| `ZZ Series` | weekly, starting next week, 10:00–10:30 | occurrence ids and `span` |

Delete the whole `ZZTest` calendar when you finish. Nothing in this script should touch
anything outside it.

## 1 — Permission plumbing

| Step | Call | Expected |
|---|---|---|
| 1.1 | `calendar_status` | Before granting: `not requested yet`, with the System Settings path and the time zone. |
| 1.2 | `calendars_list` | Consent dialog appears, quoting the usage description. |
| 1.3 | Approve, then `calendar_status` | `GRANTED (full access)`. |
| 1.4 | In System Settings, downgrade to write-only if the UI offers it, restart, call `calendar_status` | `WRITE-ONLY, which is not enough`, explaining why. Restore full access afterwards. |

## 2 — Calendars

| Step | Call | Expected |
|---|---|---|
| 2.1 | `calendars_list` | `ZZTest` present and `writable`; a subscribed or holiday calendar shows `read-only`; exactly one row marked `(default)`. |

## 3 — Search

| Step | Call | Expected |
|---|---|---|
| 3.1 | `calendar_search` over next week, `"calendars":["ZZTest"]` | Header echoes the range and your time zone; `ZZ Future` and `ZZ Series` listed. |
| 3.2 | Check the `ZZ Series` line | Marked `series`, and its id contains `\|` followed by a timestamp. |
| 3.3 | Same search with `"limit":1` | One row plus `…N more · call again with offset=1`. |
| 3.4 | `"from":"2020-01-01","to":"2030-01-01"` | Refused: range longer than 366 days. |
| 3.5 | `"from"` after `"to"` | Refused. |
| 3.6 | A range with no events | Header, then `No events in this range.` |
| 3.7 | `"from":"2026-08-12T09:00"` and a plain-day `"to"` | Accepted — the three forms mix freely. |

**Time-zone check.** Search a single day that contains an event starting at 00:30. It
must appear on that day, not the one before. This is where a time-zone bug would show.

## 4 — Detail

| Step | Call | Expected |
|---|---|---|
| 4.1 | `calendar_get` on `ZZ Future` | `state: upcoming · editable`; alarm shown as `1h before`. |
| 4.2 | `calendar_get` on `ZZ Past` | `state: ended … · NOT editable`. |
| 4.3 | `calendar_get` on an event with guests | Attendees listed with `← read-only: EventKit cannot invite`. |
| 4.4 | `calendar_get` on the `ZZ Series` occurrence id | The occurrence you asked for, **not** the first in the series. |

Step 4.4 is the important one — it is the whole reason composite ids exist.

## 5 — Create

| Step | Call | Expected |
|---|---|---|
| 5.1 | `create_event` into `Nonexistent` | Refused, listing the writable calendars. |
| 5.2 | `create_event` into a subscribed calendar | Refused as read-only. |
| 5.3 | `create_event` with two plain days | All-day event in Calendar.app. |
| 5.4 | `create_event` with times and `"alarms":["-15m"]` | Timed event; alarm present. |
| 5.5 | `create_event` with a start in the past | Created, response carries `⚠ This event is in the past.` |
| 5.6 | `create_event` with end before start | Refused. |

## 6 — The history rule

| Step | Call | Expected |
|---|---|---|
| 6.1 | `update_event` on `ZZ Past` | Refused: `Cannot modify an event that has already ended`, with how long ago. |
| 6.2 | `delete_event` on `ZZ Past` with `confirm:true` | Refused. Confirm in Calendar.app that it is still there. |
| 6.3 | Create an event running *now* (started 10 min ago, ends in 20), then `update_event` its end | **Accepted** — the rule turns on the end, not the start. |

Step 6.3 is the one to check carefully: if it is refused, the boundary is wrong.

## 7 — Update and span

| Step | Call | Expected |
|---|---|---|
| 7.1 | `update_event` with no fields | Refused: nothing to change. |
| 7.2 | `update_event {"location":null}` on `ZZ Future` | Location cleared; other fields untouched. |
| 7.3 | `update_event` moving only `start` past the existing `end` | Refused. |
| 7.4 | `update_event` on a `ZZ Series` occurrence, default span | **Only that occurrence** changes in Calendar.app. |
| 7.5 | Same with `"span":"future"` | That one and every later occurrence change; earlier ones do not. |
| 7.6 | `"span":"all"` | Refused, naming the valid values. |

Steps 7.4 and 7.5 need visual confirmation in Calendar.app. This is the highest-risk
behaviour in the server.

## 8 — Delete

| Step | Call | Expected |
|---|---|---|
| 8.1 | `delete_event` without `confirm` | Refused; event still present. |
| 8.2 | `delete_event` on `ZZ Future` with `confirm:true` | Deleted, with the full record and a `create_event(...)` line. |
| 8.3 | Paste that `create_event` call back | The event returns with the same times and location. |
| 8.4 | `delete_event` on a `ZZ Series` occurrence | Only that occurrence gone; response warns the recreate call is a one-off, not the rule. |

Step 8.3 is the real test of the recreate block: if it does not round-trip, the delete
output is not the audit record it claims to be.

## 9 — Restart behaviour

| Step | Action | Expected |
|---|---|---|
| 9.1 | Restart Claude Desktop, `calendar_status` | Still granted, no second prompt. |
| 9.2 | `swift build -c release`, restart, `calendar_status` | With ad-hoc signing macOS prompts **again** — the cdhash changed. |

## Clean up

Delete the `ZZTest` calendar. Record the date and macOS version you verified on.

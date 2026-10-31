# Time Machine

Status: implemented (2026-10-31). Time Machine shows exactly what was played, and when, from
Runout's own stored history. The Overview analyses patterns; Time Machine browses the archive.
Nothing calls Last.fm or any other service, and nothing depends on where a play came from
(`docs/long-term-architecture.md`), so plays scrobbled to Runout directly will appear the same way.

## 1. What it shows

- **Timeline:** every year from the first play to today (a silent year shows as silent), and the
  months of the year in focus.
- **Whole history:** a grid of months, one row per year.
- **Year:** twelve small months, each day shaded by plays.
- **Month:** a calendar, Monday first, with ISO week numbers.
- **Week:** seven days.
- **Day:** every scrobble, in order, a page at a time, with "On this day" beside it. On phones,
  "On this day" is a closed disclosure above the plays, with a one-line summary of real counts.
- **Custom range:** a bar per day (up to 62 days) or per month, then the plays. Every day heading
  has its total: from one calendar request for ranges up to 400 days, and for longer ones from a
  request per page of plays, covering that page's days.

Every level lists its plays, except the whole history. Each cell, bar and heading links to its
period, and "Open in Overview" opens the same period there.

## 2. Rules

The Overview's rules apply (`docs/milestone-3-plan.md` §1):
- Removed plays aren't shown.
- Days are local dates in the reporting timezone, so a 23- or 25-hour day is one day.
- Identity keys (for links) are the Overview's, following merge chains.

**The play list**
- Strings are shown exactly as scrobbled: artist, track, and the album when one was sent.
- Nothing is collapsed: a track played twice is two rows, and plays in the same second are each
  listed and marked "same second".
- Pages are cut by a cursor on the play's slot, `(played_at, seq)`. A page boundary inside a second
  never repeats or skips a play, and plays added later don't shift earlier pages.

**Coverage**
- A day or month outside the imported history is hatched and labelled "not imported", or "partly
  imported" where only part of it is missing (`Analytics::Coverage`, the local-day rule).
- An empty day reads "No scrobbles on …" only when that day is fully imported.

**On this day**
- The same calendar date in every other year of the history, newest first, with real counts, the
  top three artists and the most played track.
- 29 February is listed only in leap years; other years are left out, never moved to the 28th.
- A zero day reads "No listening" only when that day is imported; otherwise "Not imported".
- Years still to come are left out.

**Arriving and the URL**
- The focus is the shared period (`?period=`), so the Overview follows it.
- Links also carry the existing deep-link form, `?at=2014`, `2014-03`, `2014-W11` or `2014-03-15`,
  plus `?at=all` for the whole history.
- Arriving with `?at=` opens that period, and a custom range opens as itself. Otherwise Time Machine
  opens the latest local day with listening, which may be long before today. An empty history gets
  its own message.
- Moving around adds browser history entries, so Back and Forward retrace the way. Every view is a
  URL.
- Previous and next stop at the start of the history and at today.

**Keyboard**
- Each calendar or strip is one tab stop. Arrow keys move: by date in calendars (left and right a
  day, up and down a week, Home and End to Monday and Sunday), and by position in strips.
- Enter opens.
- Escape goes up a level (day and week to month, month to year, year and range to the whole
  history), unless a field, an open menu or a dialog has focus. Nothing is captured while typing
  in Search.

## 3. API

All three are read-only, need a signed-in user, and act on that user's plays only. Each answers 409
when no listening account is connected, and 400 for input it can't read.

- `GET /api/calendar`: the whole history.
  - `firstDay` and `lastDay`, local days with plays.
  - Plays per year and per month.
  - `coverage`.
- `GET /api/calendar?from=YYYY-MM-DD&to=YYYY-MM-DD`: plays per local day, inclusive, at most 400
  days. Days without plays are left out; `coverage` says which of those are known to be empty.
- `GET /api/plays?period=…&cursor=…&limit=…`: plays in order, 100 per page by default (at most
  500), with `total`, `nextCursor` and `coverage`. Each play has its UTC instant, local date and
  time, and the artist, track and album names as scrobbled, with the Overview's ids.
- `GET /api/on-this-day?date=YYYY-MM-DD`: the other years, as above.

Types: `src/data/types.ts`. Services: `Analytics::Calendar`, `Analytics::Plays`,
`Analytics::OnThisDay`, sharing `Analytics::Identity` and `Analytics::Coverage` with the Overview.

## 4. Performance (measured)

Medians of 5 runs on this Mac's local PostgreSQL 17, timezone America/Los_Angeles, from
`server/test/benchmark/time_machine_benchmark.rb`. The benchmark's synthetic histories are
written straight into a disposable database. Its plays aren't matched to the catalogue, so every
identity comes from names, the costlier path.

| | 209,000 plays | 1,000,000 plays |
|---|---|---|
| Whole history (once per visit) | 222 ms | 562 ms |
| A year of days | 14 ms | 65 ms |
| A month of days | 1 ms | 6 ms |
| The busiest day's plays | 9 ms | 32 ms |
| A month's or a year's first page | 10–11 ms | 28–34 ms |
| A year, the page after 2,500 plays | 6 ms | 12 ms |
| On this day (20 years) | 5 ms | 21 ms |

On the owner's real history (209,383 plays), measured read-only: whole history 236 ms, a year of
days 26 ms, a day's first page 90 ms, a year's first page 36 ms, on this day 37 ms.

## 5. Verification

- **Backend tests:**
  - local boundaries and daylight saving changes;
  - inclusive ranges and leap days;
  - pagination inside one second, and plays added between pages;
  - removed plays and user isolation;
  - identity keys equal to the Overview's;
  - confirmed-empty versus missing days;
  - bad input and authentication.
- **Frontend tests:**
  - arrival with and without deep links, and the old `?at=` forms;
  - calendar links and keyboard;
  - Escape, and not while typing;
  - paging and same-second marks;
  - empty and missing days;
  - On this day;
  - neighbours at the edges, the whole history, and the empty states.
- **Visual check, 2026-10-31:** native headless Chrome, with each API request answered by the same
  services on the real history (read-only, no session created), at 1440 px and 390 px.
  - **Views:** the latest day; whole history; 2014; February 2015; week 11 of 2014; the busiest
    day; 29 February 2016; the November 2014 clock change; short and long custom ranges; and the
    "Open in Time Machine" link from the Overview.
  - **Results:** no horizontal overflow, no NaN or undefined values, no unnamed controls, no
    console errors. Arrows, Enter, Back and Escape were checked in the browser.

## 6. Running it locally

```sh
cd server && bin/rails server                  # the API, port 3000
VITE_RUNOUT_API_URL=/api npm run dev           # the site, http://localhost:5173 (or set it in .env)
```

Sign in with Last.fm on the site, then open Time Machine. History storage can stay off: Time
Machine only reads.

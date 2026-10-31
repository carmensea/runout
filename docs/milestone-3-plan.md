# Milestone 3: Overview analytics and search

Status: implemented (2026-11-01). The Overview and Search read Runout's own stored listening
history. Nothing calls Last.fm, and nothing depends on which service a play came from
(`docs/long-term-architecture.md`).

## 1. Analytics rules

These apply to every figure the Overview shows, so a period and its comparison period are always
measured the same way.

**What counts**
- Stored plays not removed by an approved review (`scrobbles.removed_at IS NULL`). A removed play
  is hidden, not deleted, and returns if restored.
- Every stored play counts once. Two plays in the same second are two plays (`seq` slots); nothing
  is deduplicated at read time.
- Totals come only from stored plays. Nothing is estimated or extrapolated.

**Time**
- Every play is placed in the user's reporting timezone (`users.reporting_timezone`, an IANA name)
  by PostgreSQL's timezone database, per play. Daylight saving changes are handled exactly: a play
  at 02:30 BST lands at hour 2, and the repeated 01:00–02:00 hour in autumn counts both plays at
  hour 1.
- Periods are calendar dates in that timezone, inclusive, as the frontend defines them
  (`src/lib/period.ts`): `all`, `l12` (this month so far and the eleven before), `year`, `month`,
  `week` (ISO weeks, Monday first; week 1 contains the year's first Thursday), `day` and `custom`.
- A period's plays are those from local midnight on its first day up to local midnight after its
  last day. A local midnight that doesn't exist (a daylight saving gap at midnight) starts at the
  first instant after the gap.

**Identity of artists, albums and tracks**
- A play's names are matched to the catalogue (Stage 2.5). Where they are, the catalogue entity
  identifies it, following merges. Different spellings matched to one artist count as one artist.
- Merges chain: A merged into B, and later B into C, makes A, B and C one entity, C, however long
  the chain. Each merge's pointer is kept as decided, so the history of decisions stays. A merge
  that would make a cycle is refused; were one written anyway, every entity on or leading into it
  stands for itself, so no play is lost or counted twice (`Mergeable`, `Catalogue::Roots`).
- Last.fm sends an artist's MusicBrainz ID with some plays and not others. A name without an ID
  joins the one identified artist with that name when nothing contradicts it (`inferred`,
  `Catalogue::ArtistInference`): exactly one identified candidate after merges, no other name-only
  artist, alias, manual link, dismissed review or disputed ID, and no recording or release among
  its plays by another identified artist. Existing name-only twins are merged into it, recorded
  with their evidence, and can be reverted (`catalogue:revert_inference`); a reverted inference is
  never made again. Recordings and releases with IDs are never merged.
- Where they aren't (not matched yet, or matched ambiguously and waiting for review), the play is
  identified by its normalised names (Unicode NFKC, lower case, collapsed whitespace): the artist
  by its name, a track or album by its artist plus its own name. Such plays are always counted and
  listed, never dropped. Ids differ by kind: `a…`, `t…`, `l…` for catalogue entities, and `n…`,
  `m…`, `o…` for name-based ones. They are stable across requests.
- Plays with no album name have no album. They count in every total, but not as an album.
- Names shown: the catalogue's name, or else the most played spelling.

**Coverage**
- Each Overview says whether its period lies within imported history:
  - `complete`: all of it;
  - `partial`: some of it;
  - `none`: none of it.
- Missing ranges are kept as UTC instants (import windows are UTC) and shown as the local
  calendar days they touch. The end is exclusive, so a range ending at local midnight doesn't touch
  the next day. A first or last day only partly missing is marked, and shown with its local time
  (a UTC month in Pacific time: "2014-05-31 17:00 to 2014-06-30 17:00"). A day starts at local
  midnight, or at the first moment after it where daylight saving time skips midnight. Settings
  labels import periods by the same rule (`Analytics::Period.local_days`, `src/lib/ranges.ts`).
- The part of a period still in the future is not "missing".
- A period with no plays and complete coverage means there was no listening. A period with no
  plays and no coverage means nothing is known about it. The UI keeps the two apart.

**Comparisons**
- The comparison period is a second, independent Overview computed under the same rules. The UI
  shows absolute values side by side; a percentage change is never shown where the comparison is
  zero.

**Not available yet**
- Genres, artist metadata and album artwork arrive in Milestone 4. Until then they are `null`, never
  estimated, and the UI says so.

**Definitions shown in the UI**
- **On repeat:** most plays of one track in a single local day, at least two.
- **Back in rotation:** an artist played in the period after 12 months or more without a play
  (local calendar months).
- **New artist:** counted in the month of its first-ever play.
- **Exploration:** the share of a month's plays going to artists first heard in the previous 90 days.
- **Rediscovered:** an artist back in the period after two years or more without a play.
- **Rank by year:** an artist's position among all artists that calendar year (local). Outside the
  top 10, it shows as "outside top 10".
- **Trend:** the period divided into 12 equal parts. For `all`, the span from the first play to the
  last.

## 2. Search

- Searches the user's own history only: an artist, album or track appears only if this user has a
  stored play of it that isn't removed.
- Case-insensitive on normalised names: partial matches anywhere in the name, and misspellings
  through trigram similarity (`pg_trgm`, similarity of 0.3 or more).
- Ranking: exact name, then names starting with the query, then names containing it, then by
  similarity. Ties go to the more played.
- Up to five artists, five albums and five tracks. Ids are the Overview's.
- Plays not matched to the catalogue are found through their own strings.

## 3. API

- `GET /api/overview?period=year:2014` returns `OverviewData` (`src/data/types.ts`), plus `coverage`.
  `genres`, `metadata` and `stats.albumsWithoutArtwork` are `null`. It answers 400 for a period it
  can't read, and 409 when no listening account is connected.
- `GET /api/search?q=` returns `SearchResults`. Queries under two characters return nothing.
- Both require a signed-in user and act on that user's data only.

## 4. Performance (measured)

All data synthetic: histories imported through the real pipeline (`test/benchmark/history_benchmark.rb`
with `STOP_AFTER=matching`), measured by `test/benchmark/analytics_benchmark.rb`. Medians of 3 runs on
this Mac's local PostgreSQL 17, timezone Europe/London.

| | 209,000 plays | 1,000,000 plays |
|---|---|---|
| A day | 119 ms | 393 ms |
| A week | 136 ms | 519 ms |
| A month | 160 ms | 669 ms |
| A year | 212 ms | 761 ms |
| The last 12 months | 215 ms | 769 ms |
| Five years (custom) | 493 ms | 2.1 s |
| All time | 1.9 s | 8.5 s |
| A year with its comparison year (two requests) | 498 ms | 1.8 s |
| Search (seven queries) | 18–186 ms | 51–513 ms |
| Queries per Overview | 42–44 | 42–44 |
| Queries per search | 3 | 3 |

Process memory stayed under 100 MB.

**Bottlenecks found and fixed:**

| Problem | Fix | Before | After |
|---|---|---|---|
| "Back in rotation" named each candidate artist with a correlated subquery over the period's plays, which made the all-time Overview quadratic | Join to per-artist names instead | 693 s all time at 1M | 13 s |
| Every aggregate scanned wide rows (text keys and names per play) | Plays become narrow rows of integers and local date parts, computed once; names are looked up only for rows returned | 13 s all time at 1M | 8.6 s |
| A month table over all history was built for every request | Each artist's previous month is either in the period or its last play before it, both already known, so the table is gone | 1.8 s a year at 1M | 0.76 s |
| Search counted plays for every loosely matching name | The 200 closest catalogue entities per kind go on to play counts | 1.7 s, broadest query at 1M | 0.5 s |
| Ties fell back to catalogue ids, so equal counts could order differently between databases | Internal ids follow names, so ties are alphabetical | — | — |

**Not added:** rollup tables or caching. At this history's size every view is under 0.5 s except all time
(1.9 s). All time at 1M plays (8.5 s) is the one case that would justify a rollup; decide after real use.

## 5. Contract

`server/test/contract/overview_contract_test.rb` computes the Overview of a fixed synthetic history and
compares it with `src/test/contract/overview-2014.json`. `src/test/contract/contract.test.tsx` renders
that same file through the Overview page. Regenerate deliberately with `UPDATE_CONTRACT=1`.

## 6. Visual review

The Overview was rendered in native headless Chrome with real API responses computed from the 209,000-play
synthetic history, at 1440 px and 390 px: all time, a year with comparison, a month, search and the phone
layout.
- No horizontal overflow, no NaN or undefined values, no console errors.
- The search panel lists exact matches first.
- One fix: the rank chart's year labels ran together over 23 years; it now labels every n-th year.

# Milestone 3: Overview analytics and search

Status: in progress (2026-11-01). The Overview and Search read Runout's own stored listening
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
- Missing ranges are listed in local dates. The part of a period still in the future is not
  "missing".
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

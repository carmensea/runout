# Milestone 2 plan: historical import and synchronization

Status: **Stages 2.0 to 2.2 are implemented**: feature flag, read-only probe, findings, storage
report (2.0); database schema and models, with no data stored (2.1); client reliability (2.2).
Stages 2.1 onwards are plans, reviewed one at a time. No history is imported until the Last.fm
storage questions (`docs/lastfm-permission-email.md`) are resolved.

This extends `docs/backend-plan.md` (revision 2): scrobble identity (§4), import consistency (§5)
and security (§11) still apply. Where this document is more specific, it supersedes those sections.
Deviations from that plan are listed in §13.

---

## 1. Scope

**In scope**

- One-off import of a user's full history (designed for 15+ years, up to about 1M scrobbles).
- Resumable, idempotent Solid Queue jobs; progress, failures, retries and recovery.
- Incremental sync, back-dated scrobble catch-up and periodic reconciliation.
- Deduplication, corrected scrobbles (renames on Last.fm) and preservation of original strings.
- Canonical artists, albums and tracks, resolved from the strings Last.fm sends.
- Import status API and the minimum frontend changes to show it.
- Storage measurement, and a licensing gate that keeps all of this switched off by default.

**Out of scope (later milestones)**

- `/api/overview`, `/api/search` and every chart calculation (Milestone 3).
- Tags, genres, artwork and MusicBrainz enrichment (Milestone 4).
- Deployment (Milestone 5).

## 2. Licensing gate and data minimisation

- **Feature flag.** `LASTFM_HISTORY_STORAGE_ENABLED` is **off in every environment**, including
  development (implemented in Stage 2.0 as `HistoryImport.enabled?`). This tightens revision 2,
  which had it on in development. While off:
  - import endpoints answer `409 { "error": "history_storage_disabled" }`;
  - jobs refuse to run and record why.
- **Allowed before Last.fm replies (decision 4):**
  - read-only API verification (`bin/rails lastfm:probe`), which holds results in memory and
    stores nothing;
  - synthetic-data tests and benchmarks.

  **Not allowed:** a full historical ingestion of a real account. The flag stays off until the
  storage question is resolved.
- **Store only what charts need:**
  - Timestamp, artist, track and album strings, and MusicBrainz IDs (MBIDs) when present.
  - Not: images, URLs, "now playing", or full API responses.
  - `loved` is **deferred**, not designed out (decision 3); see §6.1 for how it can be added later.
  - Staging rows are deleted as soon as a window merges.
- **A measured size is not a licensing answer.** The synthetic benchmark (about 70 MB for a
  209k-play history, §6.5) does not establish that the history fits within Last.fm's terms.
  Whether, and how, the 100 MB "Reasonable Usage Cap" applies is still the open question.
  Storage stays disabled until Last.fm answers.
- **Measure, don't assume.** `bin/rails runout:storage_report` reports:
  - the on-disk size (`pg_total_relation_size`) of every table holding Last.fm-derived data;
  - a per-user estimate (row counts × average row width).

  Whether that figure is what Last.fm's 100 MB cap means is part of the open licensing question.
- **Estimate (to be measured in Stage 2.9, not promised).**
  - About 150 to 200 bytes per scrobble, including the primary key and unique index, plus name
    variants.
  - 15 years at 20k scrobbles a year (300k) is roughly 50 to 70 MB. Your account (about 209k
    scrobbles, per Stage 2.0) would be roughly 31 to 42 MB of scrobble rows before name variants
    and the catalogue.
  - 1M scrobbles is roughly 170 to 230 MB, which may exceed the cap. §12 covers what changes if
    Last.fm only allows less.
- **Deletion.** Account deletion already cascades. Milestone 2 adds clean-up of catalogue rows
  that no remaining scrobble references (§6.4), so a deleted user leaves no Last.fm data behind.

## 3. Assumptions verified first (Stage 2.0)

None of these are documented clearly enough to build on. Stage 2.0 checks each against the real
API using your account, **reading only**. It prints counts and field names, never values, and
stores nothing.

| # | Question | Why it matters |
|---|---|---|
| A1 | Does the JSON response carry `@attr.total`? If not, is `totalPages` with `limit=1` equal to the count? | Window verification and reconciliation |
| A2 | Are `from` and `to` inclusive or exclusive at the boundary second? | Plays at a window edge. Windows overlap by design either way (§4.2), so this only changes efficiency, not correctness |
| A3 | Are results always ordered newest first, and stable across repeated reads? | Paging and the per-second ordering used by `seq` |
| A4 | Is the "now playing" entry present only on page 1, without a date? | Counting |
| A5 | With "hide recent listening" on, does an unsigned call fail, and does a call signed with the session key succeed? | Private profiles |
| A6 | After a rename, does the old username stop working for `user.getRecentTracks`? | Not testable on demand. With no stable Last.fm ID (backend-plan §2), sync never follows a rename by itself: a mismatch stops sync until the operator relinks (§5.1) |
| A7 | How many requests per second does Last.fm tolerate before error 29? (Measured gently, stopping at the first 29) | Pacing |
| A8 | How far back can a scrobble be back-dated (offline scrobbling)? Documentation only; not testable safely | Catch-up window length |

Results are in `docs/lastfm-api-findings.md` (verified 2026-10-29):

- A1, A2 and A3 are confirmed: `total` is available, ranges are `[from, to)`, and results are
  newest first and stable.
- A5 is confirmed for public profiles only.
- A4, A6, A7 and A8 remain assumptions, with the designs above unchanged.

## 4. How a full import works

### 4.1 Overview

```
ImportRun (one per user per full import)
 └─ ImportWindow × N        bounded UTC time ranges, newest first
     ├─ fetch    → import_window_rows (staging)
     ├─ verify   → counts agree across two reads
     └─ merge    → scrobbles (+ revisions, soft deletions), staging cleared
```

Newest first, so recent years (the default chart range) are complete soonest.

### 4.2 Planning windows

1. **Start.** Resolve the account (§5.1) and read `registered_at`; history cannot predate it.
2. **Split.** Create one window per calendar month, in UTC, from the registration month to the
   current month. Windows are half-open, `[from, to)`.
3. **Request the window as-is.** Stage 2.0 verified that `from` is inclusive and `to` exclusive
   (A2), so Last.fm already returns `[from, to)`. Rows outside the window are still filtered out as
   a defensive check, and counted if any appear, so a change in API behaviour can't put a play in
   two windows.
4. **Probe.** For each window, read page 1 with `limit=200`. If `totalPages > 20` (more than 4,000
   plays), split the window in half and repeat. 4,000 plays a month is about 130 a day, so splits
   are rare.
5. **Idempotent planning.** Windows are upserted on `(user_id, window_from, window_to)`, so
   re-planning creates nothing twice.

Scale check: 15 years is 180 monthly windows. At 20k scrobbles a year that is about 1,500 pages,
plus one probe and one verification read per window: roughly 1,900 requests. At the default
pacing of 1 request per second (A7 may change this), that's about 32 minutes.

### 4.3 Fetching and verifying a window

1. Fetch pages 1 to `totalPages` with `limit=200`, sending `sk` and `api_sig` if A5 requires it.
2. **Parse each track:**
   - drop the "now playing" entry;
   - a row with no `date.uts` is counted in `malformed_count`, never silently skipped;
   - keep the exact strings: no trimming, no case or Unicode changes.
3. Write the rows to `import_window_rows` together with a `variant_hash`: SHA-256 of the exact
   tuple (artist, artist MBID, track, track MBID, album, album MBID).
4. **Verified** means all of the following hold:
   - every page succeeded and the total row count matches what Last.fm reported (A1);
   - a second read of page 1, taken after the last page, reports the same total and the same
     first row (catches new or back-dated plays landing mid-fetch);
   - `malformed_count = 0`, or the window is marked `needs_review` and not committed automatically.
5. **Mismatch.** Clear the staging rows and refetch, up to 3 attempts. After that the window is
   `failed`, with details kept (§7).

Windows that include "now" never verify cleanly while you're listening. The current month is
therefore fetched only up to the start of the run; incremental sync (§5) takes over from there.

### 4.4 Merging

One transaction per window, holding a per-user advisory lock (`pg_advisory_xact_lock`).
Transaction-level locks are safe on a direct connection (backend-plan §9).

The merge follows the algorithm in backend-plan §4. For each second `t`:

**`seq` is a storage slot, not an identity across snapshots.** Last.fm may return plays in the
same second in a different order, or with changed metadata, between fetches. So the merge never
treats a stored `seq` (or a staged `position`) as identifying the same logical play. Matching uses
the multiset of plays in that second:

1. Pair the staged and stored rows whose variant is identical. Identical plays in one second are
   indistinguishable, so any one-to-one pairing between them loses nothing. The staged
   `occurrence` numbers only make the counts explicit, so identical plays stay separate.
2. Pair what's left on each side in order; each such pair is a **name correction**, recorded in
   `scrobble_corrections`. The scrobble's `id`, `played_at` and `seq` never change.
   - **Unambiguous** (exactly one leftover play on each side in that second): state `applied`,
     and `scrobbles.name_variant_id` moves to the new variant. It is recorded, so it can be
     reviewed and reversed.
   - **Anything uncertain:** several leftover plays on either side, so the pairing would be a
     guess, or leftover counts that differ, so it could equally be a deletion plus a new play.
     State `pending_review`, and neither side is applied. The scrobble keeps its original variant
     and no removal or insertion happens in that second until a decision.
   - **Order is ignored throughout.** A change in the order Last.fm returns plays within a second
     never produces a correction.
3. Staged rows still unpaired are **new plays**: insert them with the next free `seq`.
4. Stored rows still unpaired are **missing upstream**:
   - record a `scrobble_removals` row in state `observed`, with `first_missing_fetch_id`;
   - when the next verified fetch of this window also misses them (two consecutive reads agree),
     set `confirming_fetch_id` and state `pending_review`;
   - **every removal requires review (decision 2).** The merge never sets `removed_at` itself.
     Pending removals are listed for review (`bin/rails import:removals` from Stage 2.4; the
     Settings panel from Stage 2.8):
     - **Approving** sets `removed_at` (still a soft delete).
     - **Dismissing** keeps the scrobble. If a later fetch sees the play again, an open proposal
       becomes `restored` automatically.
   - Pending removals don't block the rest of the merge: new plays and name corrections in the same
     window are still applied.
5. Delete the window's staging rows; mark the window `committed` and set `committed_at`.

**Never destructive.** No code path hard-deletes scrobbles except account deletion. A failed,
partial or interrupted window writes nothing to `scrobbles`, because the merge runs only after
verification, inside one transaction. Re-running a merge on the same verified data changes nothing.

## 5. Keeping up to date

### 5.1 Account verification before every run

Last.fm exposes no stable account ID (backend-plan §2), so a run never guesses who it is
importing for. Each run starts by calling `user.getInfo` signed with the stored session key, then
checks:

1. The returned username equals the linked identity's username (case-insensitive) **and** is
   still allowed by `LASTFM_ALLOWED_USERNAME`.
2. The returned registration time equals the stored `identities.registered_at`.

If both hold, `user.getRecentTracks` is called with that username. Otherwise:

- **Username differs** (probably a rename): the run stops before fetching anything. The
  connection goes to `failed` with the message "Your Last.fm username changed. Relink the account
  (server/README.md) to resume syncing." History already stored is kept. Nothing is fetched under
  either name until the operator relinks and signs in again.
- **Registration time differs, or is missing:** the run stops the same way, with an
  `identity_changed` message. The session key may now act for a different account.
- **Error 9 (invalid session key):** mark the identity revoked and stop. The connection becomes
  `none` and the user is asked to sign in again; existing history is kept.

Imported history belongs to the Runout user (`scrobbles.user_id`), never to a username, so a
relink re-points the identity without moving any rows.

### 5.2 Schedules (`config/recurring.yml`)

| Job | When | Range |
|---|---|---|
| `SyncAllUsersJob` → `IncrementalSyncJob(user)` | Every 30 minutes | From the newest stored `played_at` minus 24 hours, to the start of the run |
| `CatchUpJob(user)` | Daily | The last 14 days, refetched as verified windows (A8 may change the length) |
| `ReconcileJob(user)` | Weekly | Every month: Last.fm's count (A1) against stored non-removed rows; mismatched months are queued for refetch |
| `CatalogueCleanupJob` | Daily | Removes variants and catalogue rows that no scrobble references |

Incremental sync and catch-up reuse the window fetch, verify and merge pipeline. There is only
one code path that writes `scrobbles`.

## 6. Data model (implemented in Stage 2.1)

All user-owned tables carry `user_id uuid` with `on_delete: :cascade`, so deleting an account
removes its history in one statement. Every history model refuses to create rows while history
storage is disabled (`HistoryStorage` concern, `LASTFM_HISTORY_STORAGE_ENABLED`).

### 6.1 History and reconciliation

**`scrobbles`**: one row per play.

| Column | Type | Notes |
|---|---|---|
| `id` | bigint | Each play's own internal ID (Last.fm provides none) |
| `user_id` | uuid, not null | |
| `played_at` | timestamp, not null | UTC, second precision |
| `seq` | smallint, not null, default 0 | Slot among plays in the same second; check `seq >= 0` |
| `name_variant_id` | bigint, not null | Exact strings Last.fm sent; FK restrict |
| `removed_at` | timestamp | Soft delete, set only by an approved removal |
| `first_seen_fetch_id` | bigint | Audit: the fetch that first stored it |
| `created_at` | timestamp | No `updated_at`: kept lean |

Indexes:
- Unique `(user_id, played_at, seq)` is the identity, and also serves user-scoped date-range
  queries. Track identity is deliberately **not** in the key: identical plays in one second are
  separate rows, and a renamed play never becomes a second row.
- `(name_variant_id)`.

There is no separate range index; a test confirms the planner uses the identity index.

**`scrobble_corrections`**: `user_id`, `scrobble_id`, `from_variant_id`, `to_variant_id`,
`import_window_fetch_id`, `state` (`applied`, `pending_review`, `dismissed`), `reason`,
`decided_at`, `decided_by_id`, `decision_note`.
- Checks: the variant must change, and decided states need `decided_at`.
- At most one `pending_review` per scrobble (partial unique index).
- Rows are never deleted.

**`scrobble_removals`**: `user_id`, `scrobble_id`, `first_missing_fetch_id`,
`confirming_fetch_id`, `state` (`observed`, `pending_review`, `approved`, `dismissed`,
`restored`), `decided_at`, `decided_by_id`, `decision_note`.
- `pending_review` requires `confirming_fetch_id` (two reads), and decided states need
  `decided_at`.
- At most one open proposal per scrobble (partial unique index).
- Rows are never deleted.

**`loved` (deferred, decision 3).** It's not requested (`extended=0`) or stored in Milestone 2.
Forward compatibility:
- The recent-tracks client already accepts `extended:`, so it can be requested later.
- A later migration can add `scrobbles.loved boolean NULL`, where NULL means "not known yet",
  without touching existing rows.
- A reconciliation pass with `extended=1` can then fill it. Nothing in the identity, merge or
  catalogue design depends on it.

### 6.2 Import state

**`import_runs`**: `user_id`, `kind` (`full`, `sync`, `catch_up`, `reconcile`), `state`
(`planning`, `running`, `completed`, `failed`, `cancelled`), `expected_scrobbles`,
`committed_scrobbles`, `started_at`, `finished_at`, `last_error`.

**`import_windows`**: a range `[window_from, window_to)`, monthly by default.

| Column | Notes |
|---|---|
| `user_id`, `window_from`, `window_to` | Unique together; check `window_from < window_to` |
| `state` | `pending → fetching → validating → validated → committing → committed`, plus `failed`, `needs_review` and `split` (a window replaced by smaller ones, linked by `parent_window_id`) |
| `expected_total`, `fetched_count`, `malformed_count`, `attempts` | |
| `claim_token` (uuid), `lease_expires_at` | Crash recovery: one worker holds a lease (30 minutes); an expired lease can be taken over. `claim!` is a single conditional `UPDATE` and rejects non-UUID tokens |
| `lock_version` | Optimistic locking against stale concurrent writers |
| `last_http_status`, `last_lastfm_error`, `last_error_page`, `last_error_message` | For "Technical details" and resume |
| `validated_at`, `committed_at` | Required by check constraints for the states that imply them |

- **No overlaps.** An exclusion constraint (`btree_gist`, `tsrange`) guarantees one user's live
  (non-`split`) windows never overlap, so every play belongs to exactly one window.
- **Coverage.** `ImportCoverage.ranges(user)` returns the committed periods (adjacent windows
  merged), and `complete?(user, from, to)` checks a period. Anything outside is not known to be
  complete, so charts must not present it as complete.

**`import_window_fetches`**: one row per attempt.
- Columns: `attempt` (unique per window), `outcome` (`in_progress`, `validated`, `mismatch`,
  `failed`), `expected_total`, `row_count`, `malformed_count`, `http_status`, `lastfm_error`,
  `error_page`, `error_message`, `started_at`, `finished_at`.
- Used for audit and by the two-reads removal rule.

**`import_window_rows`**: the staged snapshot of one fetch.
- Columns: `played_at`, `position` (order within the second, as returned), `occurrence` (nth
  identical play in that second), `variant_hash`, raw strings and MBIDs.
- Unique on `(fetch, played_at, position)` and on `(fetch, played_at, variant_hash, occurrence)`.
- Deleted with its fetch.

### 6.3 Catalogue (shared, no user data)

**`name_variants`** (immutable once written)

- Exact strings: `artist_name`, `track_name`, `album_name` (`""` means Last.fm sent no album).
- `artist_mbid`, `track_mbid`, `album_mbid`.
- `variant_hash`: SHA-256 over a JSON array of the exact fields, so field boundaries are
  unambiguous and nil differs from `""`. Unique.
- Links: `artist_id`, `album_id`, `track_id` (nullable), plus `match_method` (`mbid`,
  `normalized_name`, `manual`) and `matched_at`.
- The model refuses edits to the strings or the hash.

**`artists`**, **`albums`** (scoped to `artist_id`) and **`tracks`** (scoped to `artist_id`):

- name or title, plus the normalised form;
- `mbid`, unique **only when present**;
- `merged_into_id`, a self-reference for redirecting duplicates later.

Normalised names are indexed but **never unique**, so the schema never forces two distinct artists
or recordings together because their names match. A test keeps two Nirvanas and an unlabelled
"nirvana" apart.

### 6.4 Canonical resolution rules

1. **MBID first.** A variant with an artist, album or track MBID links to the row with that MBID,
   creating it if needed.
2. **Otherwise the normalised name.** Normalisation is Unicode NFKC, case-folded, trimmed, with
   runs of whitespace collapsed. Albums and tracks are scoped to their resolved artist.
3. **Known limitation.** Two different artists with the same name and no MBIDs collapse into
   one. Separating them needs MusicBrainz data (Milestone 4). The original strings are always kept,
   so resolution can be re-run without re-importing.
4. **Re-resolution** (`bin/rails catalogue:resolve`) is idempotent and changes only the links on
   `name_variants`, never `scrobbles`.
5. **Clean-up** removes variants and catalogue rows that no scrobble references. It runs after
   account deletion, and daily.

### 6.5 Performance notes

- **Inserts:** `insert_all` in batches of 1,000 within a window's merge transaction.
- **Merge work:** pairing is in Ruby, per window (at most about 4,000 rows), with one query loading
  the window's existing rows by `(user_id, played_at)`.
- **No partitioning or rollups in Milestone 2.** Stage 2.9 measures import and merge speed on
  synthetic histories of 300k and 1M scrobbles, plus query plans for the range index, before any
  optimisation is proposed.
- **Measured storage (Stage 2.1, synthetic, rolled back).** `bin/rails "runout:storage_estimate[209000]"`,
  shaped like the first real account:

  | Table | Rows | Size, including indexes |
  |---|---|---|
  | `scrobbles` | 209,000 | 34.9 MB (about 175 bytes per play) |
  | `name_variants` | 41,800 | 17.1 MB |
  | `tracks` | 35,530 | 11.0 MB |
  | `albums` | 12,540 | 3.8 MB |
  | `artists` | 4,180 | 1.2 MB |
  | `import_window_rows` (one full window) | 4,000 | 1.5 MB |
  | **Total** | | **69.8 MB**, about 350 bytes per play |

  Measured on freshly truncated tables inside a rolled-back transaction; repeated runs agree to
  within 0.1 MB.

  This covers scrobbles, variants, the catalogue and **one** staging window. It does not yet
  include:
  - reconciliation records (`scrobble_corrections`, `scrobble_removals`);
  - fetch history (`import_window_fetches` grows with every sync);
  - staging during a full import, when several windows can be staged at once;
  - Milestone 4 metadata (tags, mappings, artwork references).

  Later measurements (Stage 2.9) must include all of these. The variant and catalogue counts are assumptions: about one distinct name combination per five
  plays. The real ratio is unknown until import. A ratio of one in three would add roughly 12 MB.

## 7. Jobs on Solid Queue

### 7.1 Job graph

| Job | Queue | Does |
|---|---|---|
| `StartImportJob(user)` | `default` | Account resolution (§5.1), plan windows, enqueue fetches newest first |
| `FetchWindowJob(window)` | `lastfm` | Fetch, then verify; on success enqueue the merge |
| `MergeWindowJob(window)` | `default` | Merge (§4.4), update run progress, finish the run when all windows are merged |
| `IncrementalSyncJob`, `CatchUpJob`, `ReconcileJob` | `default` | Create windows; the work happens in the same fetch and merge jobs |

### 7.2 Concurrency and pacing

- **Queues** (`config/queue.yml`):
  - `lastfm`: 1 thread, so all Last.fm traffic from this process is serialised.
  - `default`: 1 thread.
  - This is still within the conservative settings from Milestone 1.
- **One import per user:** `limits_concurrency to: 1, key: ->(user) { user.id }` on
  `StartImportJob` and the sync jobs.
- **Pacing (implemented in Stage 2.2):** `Lastfm::RequestPacer`, backed by the
  `api_request_slots` table, gives one schedule shared by every process.
  - Each request atomically reserves the next slot (`LASTFM_MIN_REQUEST_INTERVAL`, default 1 s)
    using the database clock.
  - HTTP 429 and error 29 push the next slot out for every process (a global cool-down).
  - A wait longer than 120 s raises instead of blocking a worker.
  - Reservations bypass ActiveRecord's query cache, which Rails enables for every request and
    job; otherwise repeated reservations would read a cached "go now".
  - Don't call Last.fm inside a long database transaction: the slot row stays locked until it
    commits.

### 7.3 Idempotency and recovery

- **Every job re-reads state first** and does nothing if there is nothing to do (for example, the
  window is already `committed`). Enqueuing a job twice is harmless.
- **State changes** use `lock_version`, so concurrent duplicates cannot both proceed.
- **Process crashes** (deploy or OOM):
  - Solid Queue reclaims jobs whose process died.
  - A window whose lease has expired (30 minutes) while `fetching`, `validating` or `committing`
    is reset to `pending` by a watchdog in `SyncAllUsersJob`, discarding its staging rows.
  - Merges are transactional, so a crash mid-merge leaves no partial writes.
- **Retries** (`ApplicationJob` from Milestone 1, plus per-job policy):
  - Last.fm temporary errors and 429: polynomial backoff, 8 attempts.
  - A verification mismatch: up to 3 window attempts, then `failed`.
  - Error 9: stop and revoke. Errors 10 and 26: stop all Last.fm jobs and record an alert.
- **Resume:** `POST /api/import/resume` re-queues `failed` windows (and `needs_review` windows,
  once reviewed). It never restarts merged windows.

## 8. API contracts

### 8.1 `GET /api/connection` (existing `ConnectionState`; no new variants)

| Server state | Response |
|---|---|
| No full import yet | `{ status: "connected", username, timezone }` (as now) |
| Full import running | `{ status: "importing", username, timezone, progress }` |
| Import complete, syncing normally | `{ status: "synced", username, timezone, lastSyncedAt }` |
| Import or sync failed | `{ status: "failed", username, timezone, lastSyncedAt, message }` |

- `progress` is `min(0.99, merged_scrobbles / expected_scrobbles)` until the run completes, then 1.
  It is monotonic and measured in scrobbles, the unit the user knows.
- `message` is plain language: "Imported 182,340 of about 214,000 scrobbles. March 2014 could not
  be fetched (Last.fm error 8)." The banner's existing "Resume import" link points to Settings.

### 8.2 New endpoints

- `GET /api/import` returns `ImportStatus`, for Settings' "Technical details":

  ```ts
  interface ImportStatus {
    enabled: boolean;                  // the licensing flag
    run: null | {
      kind: 'full' | 'sync' | 'catch_up' | 'reconcile';
      state: 'planning' | 'running' | 'completed' | 'failed' | 'cancelled';
      startedAt: string; finishedAt: string | null;
      expectedScrobbles: number | null; mergedScrobbles: number;
    };
    windows: { total: number; merged: number; failed: number; needsReview: number };
    failures: Array<{ from: string; to: string; page: number | null; httpStatus: number | null;
                      lastfmError: number | null; message: string; attempts: number }>;
    lastSyncedAt: string | null;
  }
  ```

- `POST /api/import`: start the full import. Returns 409 if the feature flag is off or an import is
  already running.
- `POST /api/import/resume`: re-queue failed windows.
- `POST /api/import/refresh`: "Refresh now", an incremental sync.

All `POST`s go through Milestone 1's same-origin checks.

### 8.3 `/api/overview` and `/api/search`

These stay unbuilt until Milestone 3, but must stop returning 404. They answer
`501 { "error": "not_available" }`, and the frontend treats 501 as "History imported; charts
arrive in the next version", not as an error.

### 8.4 Frontend changes (minimum)

- Settings: import panel with Start import (shown only when `enabled`), Resume, Refresh now, and
  Technical details.
- Overview: handle the 501 described in §8.3.

The banner and sidebar already render `importing`, `synced` and `failed`.

## 9. Testing strategy

- **`FakeLastfm`** (test support): an in-memory history served through WebMock that behaves like
  `user.getRecentTracks`. It handles pagination, newest-first order, "now playing", `from` and `to`
  with either boundary behaviour (A2), and scripted mutations at a chosen request number:
  - new and back-dated plays;
  - renames and deletions;
  - multiple plays in the same second;
  - error 29, error 8, HTTP 500 and timeouts.
- **Invariant tests:** after any scripted sequence that finishes verified, the stored non-removed
  scrobbles equal the remote history as a multiset of `(played_at, variant)`, and identities are
  stable across renames.
- **Idempotency tests:** a second identical import, or any job enqueued twice, changes nothing.
- **Crash tests:** stop after fetch and before merge, or mid-merge (via a raised error), then
  resume. The result equals an uninterrupted run.
- **Safety tests:** a partial or failed window writes nothing; removals need two agreeing reads and
  respect the threshold.
- **Contract tests:** serializer output is checked against the TypeScript types through shared JSON
  examples that both test suites load.

## 10. Stages

Each stage is one reviewable change: it can be tested on its own and leaves `main` working.
Nothing touches real Last.fm data until Stage 2.9, and only after licensing is resolved.

| Stage | Delivers | Acceptance |
|---|---|---|
| **2.0 Verify and gate** (done 2026-10-29) | The feature flag (off), a read-only `bin/rails lastfm:probe` for A1 to A7, `docs/lastfm-api-findings.md`, and the storage report skeleton | Probe prints only field names and counts; findings documented; plan updated where an assumption failed |
| **2.1 Schema** (done 2026-10-29) | Migrations and models for §6, with constraints and indexes | Migrations reversible; constraint tests (uniqueness, cascades, check constraints); no jobs |
| **2.2 Recent-tracks client** (done 2026-10-29) | `get_recent_tracks(from:, to:, page:)`, parser, pacing | Fixture tests for parsing (missing MBIDs, "now playing", missing date, Unicode kept exact), pacing and error mapping |
| **2.3 Window fetch and verify** | Planner (months, bisection), fetch to staging, verification | `FakeLastfm` tests: mid-fetch inserts trigger a refetch; failure after 3 attempts is recorded with page and status; nothing reaches `scrobbles` |
| **2.4 Merge engine** | §4.4 including revisions and the removal safety rules | Invariant, idempotency and safety tests; same-second and rename cases |
| **2.5 Catalogue resolution** | Variants to artists, albums and tracks; re-resolution; clean-up | MBID and name rules; re-running changes nothing; account deletion leaves no orphans |
| **2.6 Orchestration** | Jobs, queues, concurrency limits, progress, watchdog, resume | Crash and duplicate-enqueue tests; progress is monotonic; flag off means jobs refuse |
| **2.7 Sync, catch-up, reconcile** | Recurring jobs (§5) | Back-dated play inside 14 days is caught; a deliberate count mismatch triggers a refetch; a username or registration-time mismatch stops sync with a relink message and fetches nothing |
| **2.8 API and frontend** | `ConnectionState` mapping, `/api/import` endpoints, 501 handling, Settings import panel | Request tests per state; frontend tests for every connection state and panel action; shared contract examples pass on both sides |
| **2.9 Measure and accept** | Synthetic 300k and 1M benchmarks (time, memory, database size), then a real import of your account **once licensing allows** | Measured numbers recorded; real import matches Last.fm's playcount within the documented tolerance (§11) and reconciliation finds no mismatches |

## 11. Milestone 2 acceptance criteria

1. A full import of a 15-year synthetic history completes, and stored non-removed scrobbles equal
   the source exactly. An interrupted import resumes to the same result.
2. Re-running any job, or the whole import, changes nothing.
3. A rename on Last.fm produces a revision, not a duplicate. Same-second plays stay distinct.
4. Plays deleted on Last.fm become pending removals after two agreeing verified reads, and are
   soft-removed only after review approval. Nothing is ever removed automatically, and nothing is
   hard-deleted outside account deletion.
5. Incremental sync picks up new plays within one cycle. Catch-up picks up a back-dated play inside
   its window.
6. Failures show the window, page, HTTP status and Last.fm code, and Resume completes them.
7. With the flag off, no Last.fm history is fetched or stored.
8. Account deletion removes every Last.fm-derived row, including orphaned catalogue rows.
9. **Real-account check** (only after licensing allows):
   - stored count against `user.getInfo` `playcount`, with any difference explained (Last.fm's
     playcount can include plays not returned in history; to be confirmed);
   - the storage report recorded;
   - weekly reconciliation clean.
10. CI green, including the new suites. Benchmark results committed as documentation.

## 12. If Last.fm limits storage

Depending on the answer, these fall-backs keep the architecture intact:

- **A size cap below the history size:** keep raw scrobbles for a rolling period, and derive daily
  aggregates for older history. Older periods would lose name-correction tracking and per-play
  detail, but charts would still work.
- **No long-term storage:** compute charts on demand from the API, with short HTTP-cache-compliant
  caching. Full-history charts would be very slow, and this is likely impractical for 15 years.
- **Private use only:** no design change; the deployment stays behind sign-in, as it already is.

## 13. Changes from backend-plan revision 2

- `loved` is deferred, not stored in Milestone 2, and can be added later without rework (§6.1).
- Removals always need review; there is no automatic threshold (§4.4).
- The licensing flag is off in development too, until you opt in.
- Stage 2.2 client decisions:
  - **Global pacing** uses a small non-history table (`api_request_slots`), so it holds across
    processes.
  - **Client retries:** the client retries transient failures itself (up to 4 attempts, full
    jitter, Retry-After honoured up to 300 s) before a job's own retry policy applies.
  - **The token exchange is never retried.** `auth.getSession` tokens are single-use.
  - **Error classes:** `Unparseable`, a non-JSON or truncated body, is retryable; `BadResponse`,
    valid JSON missing required data, is permanent.
  - **Malformed entries:** the parser counts them (`malformed_count`) alongside `undated_count`.
- Stage 2.1 schema decisions:
  - **Corrections** are recorded in `scrobble_corrections`, and uncertain ones wait for review
    rather than being applied automatically.
  - **Removal proposals** live in `scrobble_removals`, with a `restored` state.
  - **Window states** are `pending, fetching, validating, validated, committing, committed`, plus
    `failed`, `needs_review` and `split`. Windows also have leases and a no-overlap exclusion
    constraint.
  - **Staging** records an `occurrence` number for identical same-second plays.
  - **Catalogue** rows have a `merged_into_id` redirect.
  - **`scrobbles`** has no `updated_at` and no separate range index (the identity index serves).
- "Now" handling: the current month is fetched only up to the start of the run.
- Account verification (§5.1): runs never follow a username change automatically, because Last.fm
  has no stable account ID. A mismatch stops sync until an explicit relink.

## 14. Decisions (resolved 2026-10-29)

1. **Window order:** newest first.
2. **Deletions:** every removal requires review before it's applied (§4.4). No automatic threshold.
3. **`loved`:** deferred, with forward compatibility preserved (§6.1).
4. **Before Last.fm replies:** read-only API verification and synthetic-data testing are allowed.
   No full historical ingestion of a real account (§2).

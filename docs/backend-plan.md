# Runout backend plan (revision 2)

Status: Milestone 1 (Rails foundation and authentication) is implemented in `server/`.
Everything after Milestone 1 is a plan and has not been built.

Decisions recorded from review:

- Rails 8 in API-only mode, in `server/`. The React/TypeScript frontend stays at the repo root.
- PostgreSQL: Neon in production, local PostgreSQL 17 in development and test.
- Hosting: Render, one paid web service running Puma with Solid Queue inside it.
- Sign-in: Last.fm only, with an internal `users` table and provider identities.
- Genres: a database-backed, editable taxonomy, seeded from version-controlled data.

---

## 1. Licensing (unresolved until Last.fm replies)

The questions for Last.fm are drafted in `docs/lastfm-permission-email.md` (not sent).

Quotes are from the Last.fm API Terms of Service (`last.fm/api/tos`).

| Clause | Text | Status |
|---|---|---|
| §4.3.4 | "The Reasonable Usage Cap is a maximum of 100 MB … not to exceed the Reasonable Usage Cap in total at any time" | **Unresolved.** It is not clear whether stored history counts toward the cap, or how it is measured. |
| §4.3.4 | "implement suitable caching in accordance with the HTTP headers sent with web service responses" | **Unresolved** for long-term storage of history. |
| §2.7 | Credit Last.fm with a "powered by AudioScrobbler" button. Artist, album and track pages must link to their Last.fm catalogue pages. Public access only to pages Last.fm has approved. | Confirmed. Whether a private deployment counts as public access is **unresolved**. |
| §3.1 | Non-commercial use only | Confirmed |
| §4.4 | Usage limits are enforced; no figures are published | Confirmed. The actual figures are unknown. |
| §5.1.6 | Last.fm Data must not be used to personally identify or contact users | Confirmed |
| §9.3 | Delete all Last.fm Data on termination | Confirmed |

What this means for the build:

- We do **not** assume that compact storage satisfies the 100 MB cap. Whether we may store history long term, and how much, is unresolved.
- Milestone 1 stores only what sign-in needs: the username, session key and registration date.
- History import (Milestone 2) runs behind `LASTFM_HISTORY_STORAGE_ENABLED`, which defaults to **off** in production until Last.fm gives written clarification.
- Local development with your own account is your call. The flag is on by default in development.
- A rake task will report the size of all stored data derived from Last.fm, so storage can be compared with whatever Last.fm allows.
- Attribution: the footer now has a text credit and a link to Last.fm. The email asks for the official badge asset. Detail pages (not built yet) must link to Last.fm catalogue pages when they are built.

## 2. Account identity

**Finding (2026-10-29, real API):** `user.getInfo` returns **no numeric account ID**, in JSON or
XML. The documented sample (`<id>1000002</id>`) is out of date. The live response has `name`,
`url`, `registered` (Unix seconds), `playcount` and some counters. A first real sign-in failed
closed on this: no account was created.

**Decision (single-account private deployment, with a multi-user-ready schema):**

- **Locked to configured accounts.** `LASTFM_ALLOWED_USERNAME` names the one Last.fm account that
  may sign in (`Lastfm::AccountPolicy`). Any other account is refused (`account_not_allowed`).
- **Verified on every sign-in.**
  - `auth.getSession` and `user.getInfo` (signed with the new session key, no `user` parameter)
    must report the same username.
  - `user.getInfo` must include a registration time, otherwise `identity_unverified`.
- **Runout's own IDs.** `users.id` is a Runout UUID and never derives from Last.fm data.
- **Lookup key.**
  - `identities.uid` is the normalised (lowercased) username. It is a lookup key that only an
    explicit relink changes, not a permanent identity.
  - It stays unique on (`provider`, `uid`).
- **Registration time is a consistency check only.**
  - `identities.registered_at` is recorded at the first sign-in and must match on every later one,
    otherwise `identity_changed`. A missing stored value counts as a mismatch.
  - It is never a lookup key, never unique, and never grounds for merging accounts.
- **No automatic merging or guessing.**
  - In single-account mode, once an account is linked, a sign-in under any other username is
    refused with `relink_required`, even if the registration time matches.
  - No second user is created and no history moves.
- **Recovery after a rename is explicit.** The operator:
  1. updates `LASTFM_ALLOWED_USERNAME`;
  2. runs `bin/rails "lastfm:relink[old,new]"`, which checks that the new name's public
     registration time matches, re-points `uid`, clears the stored session key and marks the link
     revoked;
  3. signs in as the new username, which is the actual proof of control.

  A future multi-user version would add a relink flow in the UI on top of the same rules.
- **Multi-user readiness.** Configuring several usernames switches the policy to multi-account
  mode: each configured username gets its own Runout user. The schema (`users`, `identities`,
  `sessions`, `lastfm_connections`) needs no change. Tests cover both modes.

## 3. Database schema

### Milestone 1 (built)

| Table | Columns | Constraints |
|---|---|---|
| `users` | `id` uuid, `display_name`, `reporting_timezone` (IANA), timestamps | |
| `identities` | `user_id`, `provider`, `uid` (normalised username: lookup key, changed only by relink), `username`, `credentials` (encrypted JSON), `profile_url`, `registered_at` (consistency check, not unique), `revoked_at`, `last_authenticated_at` | Unique (`provider`, `uid`) |
| `sessions` | `user_id`, `token_digest` (SHA-256), `expires_at`, `last_seen_at`, `ip_address`, `user_agent` | Unique `token_digest` |
| `lastfm_connections` | `user_id`, `identity_id`, `history_state` (`not_started`, `importing`, `imported`, `failed`), `last_synced_at`, `last_error` | Unique `identity_id` |

### Milestone 2 and later (planned)

**Shared catalogue** (no user data): `artists`, `albums`, `tracks`, and `name_variants`.

- `name_variants` holds the exact strings received for artist, track and album names, plus their MusicBrainz IDs. Each distinct combination is stored once.
- Canonical matching links a variant to `artist_id`, `track_id` and `album_id`. The original strings are never overwritten.

**Listening history:**

- `scrobbles`: `id`, `user_id`, `played_at` (timestamptz, UTC), `seq` (smallint), `variant_id`, `loved`, `removed_at`, `first_seen_import_id`.
- `scrobble_revisions`: `scrobble_id`, `from_variant_id`, `to_variant_id`, `detected_at`, `import_id`. An audit trail for name changes on Last.fm.
- `import_runs` and `import_windows`, used for checkpoints (see §5).

**Taxonomy:** see §6.

## 4. Scrobble identity

Last.fm gives scrobbles no ID. Each one is a timestamp in seconds plus names.

**Why the earlier unique key was wrong.** That key was (`user_id`, `played_at`, `variant_id`).

- If a scrobble's names change on Last.fm (a Pro edit, or autocorrection), re-importing produces a new `variant_id`. The key would then treat it as a new play, and the history would double-count it.
- Two genuine plays of the same track in the same second would collapse into one.

**Revised key.** Unique (`user_id`, `played_at`, `seq`), where `seq` is 0, 1, 2… among the plays recorded in that same second. Names are data, not identity.

**Merge algorithm.** It runs for each verified window (see §5). For each second `t` in the window:

1. **Remote** = the multiset of variants Last.fm returns for `t`. **Local** = the stored rows for `t` that haven't been removed, ordered by `seq`.
2. Pair rows whose variants are identical, matching them one to one.
3. Pair what's left on each side in order. Each pair counts as a **name correction**: update `variant_id` on the existing row and record a `scrobble_revisions` entry. The row's ID, `played_at` and `seq` don't change.
4. Remote rows still unpaired are **new plays**: insert them with the next free `seq`.
5. Local rows still unpaired are **missing upstream**: set `removed_at` (a soft delete), but only under the rules in §5.

**Result:**

- A name change never creates a duplicate.
- Two real plays in the same second remain two rows.
- Two plays in the same second with identical names stay distinct, because they're counted rather than collapsed.

## 5. Import consistency

**Windows.** History is imported in bounded UTC windows. Calendar months are the default; a month is split in half recursively until each window needs no more than 20 pages of 200 scrobbles.

**A window counts as verified** only when all of the following hold:

1. Every page in the window was fetched successfully: no errors, every expected page present, the number of rows matches what the pages reported.
2. The window's `total` from Last.fm is read again after fetching, and it is unchanged. If it changed, refetch the window, up to 3 times.
3. No row was dropped because its data was malformed. Rows with missing timestamps are counted and logged, never silently skipped. The track marked `nowplaying="true"` has no timestamp and is excluded before counting.

**Writes:**

- Rows fetched for a window go into `import_window_rows`, a staging table, first.
- They are merged into `scrobbles` in a single transaction, and only once the window is verified.
- A failed or partial window **writes nothing**. Its checkpoint records the page, HTTP status, Last.fm error code and attempt count, and the window can be retried.

**Removal safety.** A merge may soft-delete local rows only when:

- the window is verified, **and**
- the same rows were also missing in the previous verified fetch of that window, so two consecutive reads agree, **and**
- the removals are no more than 2% of the window, or 50 rows, whichever is larger. Anything above that pauses the merge and marks it for review.

Hard deletion happens only when the user deletes their account or asks for their data to be erased.

**Checkpoints.** `import_windows` stores: `window_from`, `window_to`, `state` (`pending`, `fetching`, `verified`, `merged`, `failed`), `expected_total`, `fetched_count`, `attempts`, `last_error`, `verified_at`, `merged_at`. Resuming means picking up windows that aren't `merged`. Jobs are idempotent: a merge re-run on the same verified data changes nothing.

**Keeping up to date:**

| Job | Schedule | Window |
|---|---|---|
| Incremental sync | Every 30 minutes | From the newest stored `played_at` minus 24 hours, to now |
| Back-dated scrobble catch-up | Daily | The last 14 days. Last.fm's offline-scrobble limit is an **assumption to verify** |
| Reconciliation | Weekly | Compares each month's count from Last.fm with the stored count, using `limit=1` so the response's `totalPages` equals the count (**assumption to verify** in Milestone 2). Mismatched months are queued for a full verified re-fetch and merge. |

**Error handling:**

| Last.fm error | Treatment |
|---|---|
| 29 (rate limit exceeded), 8, 11, 16 (temporary failures), HTTP 5xx, timeouts | Retry with exponential backoff and jitter, keeping the checkpoint |
| 9 (invalid session key) | Mark the identity revoked and stop syncing |
| 10, 26 (API key problems) | Stop all jobs and record an alert |
| 6 (invalid parameters) | Fail the window and keep the details |

## 6. Genre taxonomy and how percentages are calculated

### Tables

| Table | Holds |
|---|---|
| `tags` | Original tag strings, never discarded |
| `artist_tags`, `track_tags` | Which tags each artist or track has, with `source`, Last.fm's `weight` (0–100, where the top tag is 100) and `fetched_at` |
| `genres` | `slug`, `name`, `parent_id` (subgenres point to a broad genre), `level` |
| `tag_genre_mappings` | Links tags to genres, with `weight` between 0 and 1 and an `origin` of `seed` or `manual`. One tag can map to several genres |
| `taxonomy_settings` | Tuning values: `min_tag_weight` (default 10), `min_mapped_weight` (default 10) |

- **Seeds** live in `server/db/seeds/taxonomy.yml` and are applied idempotently by slug. They never overwrite `manual` rows.
- **Unmapped tags** stay in `tags`. `rake taxonomy:unmapped` lists them, ranked by how many scrobbles they cover.

### Calculation

For an item `x`, which is an artist or a track:

1. Keep the tags with weight `w(x,t) ≥ min_tag_weight`.
2. Each broad genre's raw score is `S(x,g) = Σₜ w(x,t) · m(t,g)`, where `m(t,g)` is the mapping weight.
3. If `Σ_g S(x,g) ≥ min_mapped_weight`, the item's broad distribution is `p(x,g) = S(x,g) / Σ_g' S(x,g')`. The values add up to exactly 1.
4. Otherwise the item is **Untagged**: `p(x, untagged) = 1`.

For a scrobble `s`, use the track's distribution if the track has enough mapped tags, otherwise the artist's: `p(s,g) = p(track,g)` or `p(artist,g)`. Every scrobble therefore contributes exactly 1 in total, split across broad genres and Untagged.

For a period with `N` scrobbles, `share(g) = Σ_s p(s,g) / N`. The shares of all broad genres plus Untagged add up to exactly 1.

### Display

- **Seven slots:** the six broad genres with the largest share over the selected period, plus **Other** (the sum of every remaining broad genre). Untagged is reported separately as `untaggedShare`, drawn hatched.
- Slots + Other + Untagged = 100%.
- **By year:** the same seven slots are used for every year, so the bands stay continuous, and each year adds up to 100%.
- **Rounding:** integer percentages are rounded with the largest-remainder method, so the displayed values also add up to exactly 100.
- **Subgenres:** `p(x,sub) = p(x,broad(sub)) · S(x,sub) / Σ S(x, subgenres of the same broad genre)`. If an item has a broad genre but no subgenre, its share goes to "Other `<broad>`". Subgenre shares add up to their broad genre's share, so this view also totals 100%.
- **Contributing artists** for a genre are ranked by allocated scrobbles, `Σ p(s,g)` over that artist's scrobbles. The counts can be fractional and are rounded for display; the caption will say so.
- These charts show one distribution that adds up to 100% overall. "Most listened genres" uses the same shares. Nothing else on the page reuses the raw tag weights.

## 7. Timezone

- `users.reporting_timezone` is set from the browser's timezone at first sign-in and will be editable in Settings. All local-time bucketing (hour, weekday, date, month) uses it for the **entire** history. Scrobbles stay in UTC.
- **Limitation, to be documented in Settings:** hour-of-day, weekday and day boundaries assume you were in the reporting timezone for your whole history. Periods spent living or travelling elsewhere will appear shifted.
- A possible later addition is a `user_timezone_periods` table (`from`, `to`, `tz`), which could be added without restructuring. It is not planned for the MVP.

## 8. Performance

- **No performance targets are promised yet.**
- Milestone 3 adds `bin/rails benchmark:seed`, which generates synthetic users with 50k, 250k and 1M scrobbles. The data will have realistic shapes: long-tail artist popularity, daily and weekly rhythms, gaps, and multi-year histories.
- We then measure every Overview query (p50 and p95 timings, `EXPLAIN (ANALYZE, BUFFERS)`) locally and on a Neon branch. Optimisations such as rollup tables or materialised views are added only where those measurements show a need.

## 9. Database connections (Neon)

- **What Neon's pooler is:** PgBouncer in transaction mode (`pool_mode=transaction`).
- **Prepared statements:** the pooler **supports protocol-level prepared statements** (PgBouncer 1.22 and later, with `max_prepared_statements=1000`). Rails' `pg` adapter uses protocol-level statements, so they are not in themselves a reason to avoid the pooler. Only SQL-level `PREPARE`/`EXECUTE` is unsupported.
- **What doesn't work through the pooler** is anything tied to a single database session:
  - `SET` / `RESET`
  - `LISTEN` / `NOTIFY`
  - session-level advisory locks
  - temporary tables that persist across transactions
- **Consequences:**
  - Rails migrations take a session-level advisory lock, so they must run on a direct connection. Neon recommends direct connections for migrations.
  - Solid Queue's compatibility with the transaction-mode pooler hasn't been verified yet.
- **Decision:** use the direct (non-pooled) connection for everything at first. Revisit pooling if connection counts become a problem.
- **Connection budget (direct):** each Puma process holds up to `RAILS_MAX_THREADS` (3) connections to the primary database, plus Solid Queue's supervisor, dispatcher and worker threads (2) against the queue database, plus the cache database. That is on the order of 10 to 15 connections for one instance, well inside the 104 that Neon documents for a 0.25 CU compute (7 of them reserved). Verify with `pg_stat_activity` after the first deploy rather than relying on this arithmetic.

## 10. Hosting and cost estimate

**Render.** One web service running Puma, with Solid Queue inside the web server (`SOLID_QUEUE_IN_PUMA=1`). It serves the built frontend and `/api` from a single origin.

- **Plan:** "Standard" (1 CPU, 2 GB). The 512 MB "Starter" plan is too tight for Rails plus import jobs.
- **Price:** Render's documentation lists the specs, but its pricing page returned no figures when I checked. **Confirm the price on render.com/pricing.**
- **Job settings** (`server/config/queue.yml`):
  - 1 worker process with 2 threads (`JOB_THREADS`)
  - dispatcher polling every 5 s (batches of 100), worker polling every 5 s
- **Durability versus retries.** These are different things:
  - *Durability:* enqueued jobs live in Postgres, so they survive deploys and restarts.
  - *Retries:* Solid Queue does **not** retry a job that raises; the job moves to
    `solid_queue_failed_executions`. Retries are declared in `ApplicationJob`: Last.fm
    temporary failures and rate limiting retry with polynomial backoff, up to 8 attempts (about an
    hour); deadlocks and lost connections retry 3 times; jobs for deleted records are discarded.
  - Import jobs (Milestone 2) are also idempotent and checkpointed (§5), so a retry or a manual
    re-run never duplicates work.

**Neon cost estimate.** Launch plan rates when checked: **$0.106 per CU-hour**, **$0.35 per GB-month**, no monthly minimum.

- Solid Queue polls continuously, so the compute **never scales to zero**. Scale-to-zero only happens after 5 idle minutes.
- Always on at 0.25 CU: 730 h × 0.25 = 182.5 CU-h ≈ **$19.35/month**.
- At 0.5 CU: ≈ **$38.70/month**.
- Storage below 1 GB: under **$0.35/month**.
- The Free plan's 100 CU-hours a month can't support an always-on worker.
- A possible saving later is moving the scheduler out of Puma, so compute can sleep between syncs. This is not planned for the MVP.

## 11. Security

- **Last.fm credentials:** the API key and shared secret come from environment variables or Rails credentials and are never sent to the browser. The Last.fm session key is encrypted with Active Record Encryption, non-deterministically.
- **Session cookie:** HttpOnly, SameSite=Lax, Secure in production, with the `__Host-` prefix in production. It holds a random 256-bit token; the database stores only its SHA-256 digest.
- **Session lifetime:** 30-day sliding expiry, capped at 90 days from sign-in (absolute lifetime), after which the user signs in again. Sessions are rotated on sign-in and deleted on sign-out.
- **Sign-in protection:** Last.fm's callback has no `state` parameter, so a one-time random nonce is added to the callback URL and stored in an **encrypted**, HttpOnly cookie scoped to `/api/auth/lastfm` that expires after 10 minutes. It is compared in constant time and deleted on use.
- **Host header:** production answers only for the `APP_ORIGIN` host (`/up` is exempt for Render's health check).
- **State-changing requests** must carry an `Origin` that matches the app's origin, plus `X-Requested-With: XMLHttpRequest`.
- **Data isolation:**
  - Controllers read user data only through `Current.user`, and no endpoint accepts a `user_id`.
  - Request tests check that one user can't reach another's data.
  - Postgres row-level security is a later hardening option.
- **Logs** filter `token`, `sk`, `api_sig`, `api_key`, `secret`, `state` and `credentials`.
- **Sign-out** deletes the server-side session and clears the cookie.
- **Account deletion** (`DELETE /api/account`, from Settings) requires typing the Last.fm username, then deletes the user. Foreign keys cascade to identities (with the encrypted session key), sessions and the connection, and will cascade to scrobbles and import data in later milestones. It is also the mechanism for honouring ToS §9.3 (deleting Last.fm Data on termination); it does not by itself establish compliance with the rest of the terms.
- **Disconnecting Last.fm** is the same as deleting the account while Last.fm is the only way to sign in. Runout cannot revoke its own access on Last.fm's side, so after deletion Settings links to `last.fm/settings/applications`. If the user revokes access there first, the next Last.fm call returns error 9 and the identity is marked revoked (§5).

## 12. Milestones

1. **Foundation and authentication (done):**
   - Rails app, migrations, sessions, the Last.fm client, `GET /api/connection`, sign-out, account deletion
   - frontend sign-in, Settings (sign out, delete account), plus Last.fm attribution
   - tests and CI
2. **History import and sync:** windows, checkpoints, the merge algorithm, reconciliation. Gated by `LASTFM_HISTORY_STORAGE_ENABLED`.
3. **Benchmarks, then Overview analytics:** benchmark datasets first, then `/api/overview` and `/api/search`, then contract tests against the frontend types.
4. **Taxonomy and metadata enrichment:** tags, mappings, the percentage rules above, MusicBrainz lookups.
5. **Deployment:** Render and Neon, after Last.fm replies.

## 13. Assumptions to verify

- That `user.getInfo` signed with a session key and no `user` parameter returns the authorised account. The docs say `user` defaults to the authenticated user.
- ~~That the numeric `id` is stable across username changes.~~ **Resolved:** no numeric ID is returned at all (see §2).
- Last.fm's actual rate limits.
- The offline-scrobble backdating limit (assumed 14 days).
- That `total` / `totalPages` can be used for counts.
- Whether signed `getRecentTracks` calls return scrobbles from private profiles.
- Solid Queue's compatibility with Neon's transaction pooler.
- Render's pricing.

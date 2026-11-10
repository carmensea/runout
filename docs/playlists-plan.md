# Milestone 5, Phase 2: Spotify playlists from On This Day (implementation plan)

Reviewed 2026-11-05 against the current repository and Spotify's current documentation. This refines
`docs/milestone-5-plan.md` §3 (approved 2026-11-04); where the two differ, this file wins. **No code
is written until the owner approves this plan.** Nothing merges or deploys without the owner, and no
real playlist is created in the owner's Spotify account before a supervised first test.

## 1. What changed since the plan was approved

**Spotify (checked 2026-11-05, official pages).** The plan's §3.1 holds, with these precisions:

| Rule | Confirmed |
|---|---|
| Create | `POST /me/playlists`, body `name`, `description`, `public` (defaults to **true**, so Runout always sends `false`), scope `playlist-modify-private`. The old `/users/{id}/playlists` is removed. |
| Add items | `POST /playlists/{id}/items`, body `uris` (max **100** per request), optional zero-based `position`; omitted appends. |
| Read contents | `GET /playlists/{id}/items`, max `limit` **50** per page, scope `playlist-read-private`; rows use `item`, not `track`. Items are returned only for playlists the user owns. |
| Find a playlist | `GET /me/playlists` (paged), scope `playlist-read-private`. |
| Search | `GET /search?type=track`, `limit` **0–10**, default 5; `isrc:`, `track:`, `artist:` filters still documented. |
| Track lookup | `GET /tracks?ids=` (batch) is removed; `GET /tracks/{id}` stays, one request per track. |
| Development Mode | 5 users per app; the owner needs active Premium; since July 2026 the quota is **per developer account**, shared by every client ID, so matching and polling draw on one budget; `429` with body `reason: "QUOTA_EXCEEDED"`; rate limit on a rolling 30 s window with `Retry-After`. Cooldown length is not documented. |
| Playlist size | No documented cap per playlist. Runout applies its own (§4). |
| Refresh tokens | No change documented in 2026; the existing refresh and `needs_reauth` behaviour stands. |

Sources: Spotify's [February 2026 migration guide](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide),
[February 2026 changelog](https://developer.spotify.com/documentation/web-api/references/changes/february-2026),
[July 2026 quota post](https://developer.spotify.com/blog/2026-07-23-web-api-quota-updates),
[Create Playlist](https://developer.spotify.com/documentation/web-api/reference/create-playlist),
[Add Items to Playlist](https://developer.spotify.com/documentation/web-api/reference/add-items-to-playlist),
[Scopes](https://developer.spotify.com/documentation/web-api/concepts/scopes),
[Quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes),
[Rate limits](https://developer.spotify.com/documentation/web-api/concepts/rate-limits).

**Repository.** Since 2026-11-04: Phase 1 is complete (passkeys on, decoupling merged 2026-11-05, so
`GET /api/connection` answers `signed_out` or an account with `displayName`); Settings is tabbed;
the account menu and themes exist; Time Machine has an On This Day panel
(`src/pages/time-machine/OnThisDayPanel.tsx`, an aside on desktop and a collapsible on phones) and
a day hover card. Everything Phase 2 needs is in place:

- `Analytics::OnThisDay` already computes the local day range per year in the reporting timezone
  (leap days included, future days excluded): the selection reuses those ranges.
- `Analytics::Identity.ctes` gives every play an identity key: `t<track id>` after merge
  resolution, or `m<hash>` (artist key + normalised title) for a variant no catalogue track claims.
  "Unique songs" means one row per identity key. Unresolved variants stay unresolved: the playlist
  never writes to the catalogue.
- `listening_observations` already hold `provider_track_id` and `isrc` for Spotify-recorded plays:
  the "verified" tier needs no new data.
- `Spotify::Client` is GET-only, behind the shared pacer (`api_request_slots`, key `spotify`) with
  429 and `QUOTA_EXCEEDED` handling. It gains JSON `POST` and four calls (§5).
- `Spotify::Account#connect!` requires the polling scope and stores the granted set, so the scope
  upgrade is the same flow with more scopes requested (§6). `Spotify::OAuthState` carries the user;
  it will also carry which scope set was requested.
- `review_decisions` is polymorphic (`subject_type`, `subject_id`): a manual match is one row.
- `loved_tracks` are keyed by `name_variant_id`; "loved only" filters by identity key through the
  same CTEs, so a loved variant covers its sibling variants.
- Solid Queue runs in production (one worker); the resolver and creation jobs ride on it.

## 2. Architecture

```
On This Day panel ── Create Spotify playlist ──► POST /api/playlists {kind: on_this_day, date}
                                                      │ draft + items (Playlists::Selection)
                                                      ▼
                               Playlists::ResolveJob (Spotify matching, item by item)
                                                      │
Playlist page (preview) ◄── GET /api/playlists/:id ◄──┘   PATCH: options, name, exclude, manual match
        │ Create
        ▼
POST /api/playlists/:id/create ──► Playlists::CreateJob ──► Spotify (create, add in batches, verify)
```

Backend modules, all new, nothing existing changed in behaviour:

- `Playlists::Selection` (pure SQL over `scrobbles` + identity CTEs): takes day ranges, year
  subset, `unique`, `lovedOnly`, `sort`, `seed`; returns ordered rows.
- `Playlists::Resolver`: the matching ladder (§5), one Spotify request at most per song.
- `Playlists::Creator`: the resumable creation (§7).
- `Spotify::Client`: `search_tracks`, `track`, `create_playlist`, `add_items`, `playlist_items`,
  `my_playlists`.
- Controllers: `Api::PlaylistsController` (`index`, `show`, `create`, `update`, `create_on_spotify`,
  `search` for manual matching), all `require_authentication`, every lookup scoped to
  `Current.user` (another user's id is 404), writes CSRF-protected like every other POST.
- Flag: `RUNOUT_PLAYLISTS_ENABLED`. Routes answer 404 and the UI hides the entry while it is off,
  exactly like `RUNOUT_PASSKEYS_ENABLED`, so the backend can deploy early and idle.

## 3. Database (additive; rollback tested on the test database, one version at a time)

```
playlists              id uuid, user_id, kind ('on_this_day'; later 'period', 'loved', 'diary'),
                       selection jsonb {date, years[], unique, lovedOnly, sort, seed, excluded[]},
                       name, description, state ('draft'|'resolving'|'ready'|'creating'|'created'|'failed'),
                       spotify_playlist_id, spotify_url, matched_count, added_count, error, attempt_token,
                       resolved_at, created_on_spotify_at, created_at, updated_at
                       index (user_id, created_at)
playlist_items         id, playlist_id, position, identity_key, track_id (nullable, tracks.id),
                       artist_name, track_name, album_name, first_played_at, last_played_at, plays_in_selection,
                       spotify_track_id, match ('pending'|'verified'|'matched'|'ambiguous'|'unavailable'|'unmatched'|'manual'),
                       candidates jsonb, excluded boolean, added boolean
                       unique (playlist_id, position); index (playlist_id, match)
spotify_track_matches  id, user_id, identity_key, track_id (nullable), spotify_track_id, isrc,
                       kind ('observed'|'isrc'|'search'|'manual'), state ('confirmed'|'candidate'|'rejected'),
                       evidence jsonb, created_at, updated_at
                       unique (user_id, identity_key, spotify_track_id); index (user_id, identity_key, state)
```

Deviation from §3.2, for the owner's rule that one user's unverified choice must never reach
another user's library: the mapping table is **per user** and keyed by identity key, not the global
`catalogue_external_ids` keyed by `tracks.id`. A confirmed mapping is reused by that user's later
playlists only. When a cross-user catalogue mapping is wanted later (artist pages, Apple Music), a
promotion step can copy agreed rows into `catalogue_external_ids`; nothing here blocks it.
Spotify IDs never touch `tracks`, `name_variants`, `scrobbles` or `loved_tracks`.

## 4. Selection and sorting (`Playlists::Selection`)

Input: the day ranges `Analytics::OnThisDay` computes for the date (one per year with plays),
optionally a subset of years, `unique` (default true), `lovedOnly` (default false), `sort`, `seed`.

- **Unique songs:** one row per identity key; `first_played_at`, `last_played_at`,
  `plays_in_selection` are computed inside the selected days only. Names shown are the catalogue
  names when resolved, otherwise the most common variant names, with the album for telling
  recordings apart.
- **Every listen:** one row per play (`played_at`, `seq`), the same song as often as it was played.
- **Chronological (default):** `first_played_at, seq, identity_key` ascending (every listen:
  `played_at, seq`).
- **Most played:** `plays_in_selection` descending, then chronological, then `identity_key`.
- **Recently played:** `last_played_at` descending, then `seq` descending, then `identity_key`.
- **Shuffle:** a seeded Fisher–Yates over the chronological order; the seed is stored in
  `selection`, so the preview and the created playlist agree, and "Reshuffle" stores a new seed.
  Tie-breaks are total orders (the identity key is unique per row in unique mode; `played_at, seq`
  is unique per play), so the same selection always yields the same list.
- **Cap:** Runout refuses to create more than **1,000 items** per playlist (Spotify documents no
  cap; its apps cap at 10,000). A larger "every listen" selection is cut at 1,000 in the chosen
  order and the preview says so.

Excluding a track removes its identity key from the selection (`excluded[]`); restoring puts it
back. Changing years, mode or sort rebuilds the items from the same stored match results, never
re-searching (§5).

## 5. Matching (`Playlists::Resolver`, a Solid Queue job per draft)

For each item in order, stop at the first success. At most one Spotify request per song, and the
result is kept on the item and in `spotify_track_matches`, so a day revisited next month costs
nothing.

1. **Verified** (no request): a confirmed `spotify_track_matches` row for this user and identity
   key; or a `listening_observations` row of any variant with the same identity key carrying a
   `provider_track_id` (Spotify itself reported that ID for a play of this song). Stored as `observed`.
2. **ISRC** (one search): an observation with an ISRC → `search?q=isrc:<ISRC>&type=track&limit=10`,
   accepted only if the artist matches after `CatalogName.normalize`.
3. **Search** (one search): `q=track:"<title>" artist:"<artist>"&type=track&limit=10&market=from_token`.
   Accept a result only when the normalised artist equals and the normalised title equals once
   *release annotations* are stripped (remaster, remastered, reissue, anniversary, deluxe, expanded,
   explicit, bonus track, in brackets or after a dash). **Version words are never stripped:** remix,
   live, acoustic, demo, edit, version, instrumental, cover, radio edit, unplugged, session must
   appear in both titles or in neither, so a live play never gets the studio recording and vice versa.
   Exactly one acceptable result → `matched` (the evidence records any annotation, so a remaster is a
   playlist alternative and nothing more). Several acceptable results on different albums →
   `ambiguous` with the candidates; results that agree only on the title → `ambiguous`; none →
   `unmatched`; not playable in the user's market → `unavailable`. Nothing is chosen for the user.
4. **Manual:** the preview offers the candidates, a search box (one request per query, the user's
   own words), or a pasted Spotify track link (`GET /tracks/{id}`, one request). The choice is
   stored `confirmed`, `kind: manual`, plus a `review_decisions` row (`subject: playlist_item`).
   "Not on Spotify" is also a choice: the item stays listed as unmatched and is skipped at creation.

MusicBrainz IDs are never treated as Spotify IDs. Only `verified`, `matched` and `manual` items are
added. Everything else stays visible in the preview with its reason.

**Quota.** Because the Development Mode quota is shared with polling, the resolver works in
budgeted rounds: **120 searches per round**, then the draft is `ready` with the rest `pending` and
the page offers "Find more matches". Rate limits (`Retry-After`) pause the job through the shared
pacer; `QUOTA_EXCEEDED` stops the round, marks the draft `ready` with what it has, and the page says
Spotify's daily allowance is used up. Polling is never starved: the pacer serialises both.

## 6. Scope upgrade (first playlist use only)

Settings → Sources → Spotify gains "Allow playlist creation". It starts the existing three-step
OAuth flow with `scopes=playlists` in the signed `state`; the authorize URL then requests
`user-read-recently-played playlist-modify-private playlist-read-private` together (a token carries
only the scopes of the request that made it, so requesting the playlist scopes alone would stop
polling). `connect!` keeps refusing a token without the polling scope and writes nothing until a
good token is in hand: declining, cancelling, or a Spotify error leaves the current credentials and
polling untouched, and Settings says the permission was not granted. The first "Create Spotify
playlist" click on a source without the scopes shows that link instead of failing.

Verification around the consent: `bin/rails spotify:verify` (read-only) before; after, the stored
`scopes` contain all three and the next scheduled poll succeeds ("polls ok" in the logs).

## 7. Creating the playlist (`Playlists::CreateJob`, resumable)

1. Lock the row; refuse unless `state` is `ready` or `failed`; set `creating`, a fresh
   `attempt_token`, and append `runout:<playlist id>` to the description Runout sends.
2. If `spotify_playlist_id` is empty, page `GET /me/playlists` (50 per page) for an owned playlist
   whose description carries the token: an earlier attempt whose response was lost. Adopt it.
3. Otherwise `POST /me/playlists` with `public: false`; store the ID and URL at once.
4. `GET /playlists/{id}/items` (50 per page) to learn what is there; add only the missing URIs in
   batches of 100, in order, marking `added` per batch. A failure mid-way leaves `failed` with the
   counts; a retry resumes from the same playlist and never re-adds a batch.
5. Read the playlist back once more and compare count and order to the intended list; only then
   `created` with `added_count`. The page shows "N of M added", lists the omitted songs and why,
   and offers "Open in Spotify".

Errors: 401 → the existing refresh then one retry; 403 → "needs the playlist permission" with the
upgrade link; 429 → wait `Retry-After`; `QUOTA_EXCEEDED` → `failed` with a plain message, resumable
later; 5xx and timeouts → three retries with backoff, then `failed`. Double submission: the
`create` endpoint is idempotent per `attempt_token`, and the row lock refuses a second concurrent
job. The playlist row keeps everything needed to revisit it: Spotify ID and URL, name, dates,
selection, sort, seed, state and counts.

## 8. Frontend

- **On This Day panel:** one button, "Create Spotify playlist". It creates the draft and opens
  `/time-machine/playlist/:id`. Hidden while the flag is off or the connection is signed out.
- **Playlist page** (desktop two columns, phone one): name and description fields; the summary line
  (songs selected, years, matches found, needs attention); the compact option row (Unique songs /
  Every listen, sort, Loved only, years as toggles under "Years"); the song list with a small
  match mark per row (matched, needs a choice, not found, excluded), the remove and restore
  controls, the candidate picker and search for a row that needs a choice; then one deliberate
  "Create private playlist" button, the progress line while creating, and the result with "Open in
  Spotify". Rendered from the same tokens as the rest of Runout; the page surface uses `--panel`
  so it stays readable over the candy skies; `prefers-reduced-motion` already holds the sky still.
- **Playlists made:** a short list on the Settings → Sources Spotify panel (name, date, open in
  Spotify, open the day), and the On This Day panel says "Playlist made on 5 November" with a link
  when one exists for that date.
- Polling of `GET /api/playlists/:id` every 2 s while `resolving` or `creating`.

## 9. PRs, tests and the verification plan

| PR | Contents | Deploy effect |
|---|---|---|
| A. Spotify writes and scope upgrade (backend + the Settings toggle) | `Spotify::Client` POST/JSON and the six calls, `scopes=playlists` state, `connect!` superset handling, Settings "Allow playlist creation", `spotify:verify` reports the scopes | nothing changes until the owner clicks the toggle |
| B. Playlist engine (backend, flag off) | the three tables, `Selection`, `Resolver`, `Creator`, jobs, `Api::PlaylistsController`, 404 while `RUNOUT_PLAYLISTS_ENABLED` is off | migrations only; routes 404 |
| C. Playlist page (frontend) | On This Day button, playlist page, playlists made list, mobile | hidden while the flag is off |
| D. Rehearsal and first playlist | fake-Spotify end-to-end in the production smoke test; rehearsal on the disposable copy; flag on in production; the owner's supervised first private playlist | owner's go at each step |

Tests (backend): selection per mode and sort with tie-break tables, years subset, leap day, timezone
day edges, loved only, exclusion; resolver ladder with a title-normalisation table (remaster
accepted, remix/live/acoustic refused, artist mismatch refused, several albums → candidates, none →
unmatched, unavailable), observed ID wins, manual pick and "not on Spotify", search budget and
`QUOTA_EXCEEDED`, 429 pacing; creation: create then batches, lost-response adoption, resume after a
partial failure without re-adding, readback mismatch stays `failed`, 401 refresh, 403 scope, double
submit; scope upgrade keeps the polling scope and a declined consent changes nothing; two-user
isolation on every endpoint (404). Frontend: preview states, options, exclude and restore, manual
pick, create progress and result, upgrade prompt, phone layout, keyboard and labels. Captures on
desktop and phone in the five themes, as for the Settings tabs. The usual checks before every
commit (`npm run lint`, `typecheck`, `test`, `build`; `bin/rails test`, `rubocop`, `brakeman`,
`bundler-audit`).

Estimates: A one day, B one and a half, C one and a half, D half a day with the owner.

## 10. Decisions for the owner

1. **Per-user mappings** (§3) instead of the global `catalogue_external_ids` for now. Proposed: yes.
2. **Search budget** of 120 per round with "Find more matches" (§5), to protect polling's shared
   quota. Proposed: yes; the number is a constant to tune.
3. **Cap of 1,000 items** per created playlist (§4). Proposed: yes.
4. **Default name** "November 14 — Through the Years" (month first, as the owner wrote it), with the
   description "Songs I listened to on 14 November, 2006–2026, from my Runout archive."
5. **Where made playlists are listed:** Settings → Sources Spotify panel plus a note on the day's
   On This Day panel (§8), no new navigation item.

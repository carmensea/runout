# Milestone 5 plan: Runout's own identity, playlists from the past, and the music diary

Status: plan approved by the owner on 2026-11-04 (decisions in §6). Nothing here is built; the
owner approves each implementation phase separately. Each phase has its own PRs, tests and
production verification, and nothing merges or deploys without the owner's approval.

One principle runs through all of it: **authorization is built on user ownership from the start.**
Every diary entry is private by default, every query starts from the signed-in user, and a later
sharing feature can never expose an existing entry because exposure needs an explicit per-entry
choice that does not exist yet.

The three features share one direction (`docs/long-term-architecture.md` §1): Runout is where the
history becomes the owner's, with the meanings attached. Spotify stays the place to listen; Last.fm
is where most of the history came from; neither is needed to open Runout.

Order: **Phase 1** independent sign-in, **Phase 2** On This Day playlists, **Phase 3** the private
diary, **Phase 4** the friends and offline designs on paper only.

## 1. What exists and what each phase reuses

| Area | Today | Reused by |
|---|---|---|
| Users | `users` with Runout UUIDs, `display_name`, `reporting_timezone`; every history row hangs off `user_id`, never off a Last.fm name | all |
| Identities | `identities` (`provider`, `uid`, encrypted `credentials`, `revoked_at`), one Last.fm row; `Lastfm::SignIn` verifies and links, `Lastfm::AccountPolicy` is the allowlist | Phase 1 keeps Last.fm as a *connection* with the same row |
| Sessions | `sessions`: random token in a `__Host-` cookie, SHA-256 digest stored, 30-day sliding, 90-day absolute, `Session.start!` rotates on sign-in; `Authentication` concern; `RequestForgeryProtection` (Origin + `X-Requested-With`, SameSite=Lax) | Phase 1 unchanged: passkeys only add a second way to call `start_session_for` |
| One-time state | encrypted short-lived cookies for OAuth nonces (`cookies.encrypted`, `Spotify::OAuthState`) | Phase 1 WebAuthn challenges use the same pattern, no table |
| Rate limiting | Rails `rate_limit` on the auth controllers | Phase 1 sign-in and recovery endpoints |
| Spotify | `Spotify::Client` (paced, 429 and `QUOTA_EXCEEDED` aware), `Spotify::Account` (locked token refresh, `needs_reauth`), `ListeningSource` with encrypted credentials and granted `scopes`, the 3-step OAuth controller | Phase 2 adds write endpoints and a scope upgrade; polling untouched |
| Spotify IDs already stored | `listening_observations.provider_track_id` and `isrc` for every Spotify-reported play (since 2026-11-02) | Phase 2 "verified ID" source |
| Identity keys | `Analytics::Identity.ctes`: `t<id>` for catalogue tracks (merge chains followed), `m<md5>` for unmatched names; `Catalogue::Roots` | Phases 2 and 3 address songs by catalogue track id, resolved through the same roots |
| Catalogue decisions | `catalogue_reviews`, `review_decisions` (audited, never silent) | Phase 2 manual Spotify match corrections are recorded the same way |
| On This Day | `Analytics::OnThisDay` (local days per year in the reporting timezone, leap days handled), `OnThisDayPanel` | Phase 2 selection reuses its day ranges |
| Loved | `loved_tracks` + `LovedProvider` / `Heart` (session-wide set of loved keys) | Phase 2 loved-only filter; Phase 3 diary indicator copies the pattern |
| Background work | Solid Queue (poller, enrichment) | Phase 2 match resolution and playlist creation run as jobs |
| Backups | `pg_dump` of the whole database, encrypted, restore-tested daily | diary and playlist tables are included with no change |
| Frontend | React Router, `useAsync`, `useAppData` (connection + timezone), Settings sections, dark editorial design, specimen mode, Vitest | all |

**What gets in the way** (long-term architecture §9 #3 and #4): `ConnectionState.status = "none"`
means both "signed out" and "no Last.fm connected", and the history endpoints answer 409
`not_connected` without a `lastfm_connection`. Phase 1 separates these.

## 2. Phase 1: independent authentication

### 2.1 Recommendation

**Passkeys (WebAuthn) as the primary sign-in, recovery codes as the fallback, the operator's
console as the last resort. No passwords. Email verification is not needed for one user and can be
added later for friends.**

- Passkeys: the `webauthn` gem (cedarcode, 3.5.0, MIT) on the server; the browser's
  `navigator.credentials` API on the client, no library. Discoverable credentials
  (`resident_key: "required"`, `user_verification: "required"`) so sign-in needs no username: the
  passkey identifies the user.
- Recovery codes: ten single-use codes generated when the first passkey is enrolled, shown once,
  stored as SHA-256 digests like session tokens. Enrolling a passkey never replaces usable codes: a
  new set is made only when none is left; replacing a set is always a deliberate action in Settings. A code signs in normally and the page insists on
  enrolling a new passkey.
- Operator recovery: `bin/rails auth:recovery_link[user]` prints a one-time sign-in link valid 15
  minutes, run over `railway ssh`. The owner is the operator, so losing every device and every code
  still has a path that no outsider has.
- Last.fm sign-in stays as a fallback until the owner has signed in with a passkey, signed out, signed
  in again, and used a recovery code on the rehearsal copy and then in production. Only then does a
  later PR turn "Sign in with Last.fm" into "Connect Last.fm" in Settings.

Why not email: it needs a sending service (Resend's free plan gives 3,000 a month and SMTP, but it is a
new hosted dependency and a new secret), and for a single owner it adds an account-takeover surface
(mailbox) without adding a path the console doesn't already give. It becomes worth it when friends
join, as the way to invite and recover them. Why not passwords: nothing to phish, nothing to reuse,
and the owner asked for none.

### 2.2 Database (additive)

```
webauthn_credentials  id, user_id (uuid FK cascade), external_id (text, unique: the credential id),
                      public_key (text), sign_count (bigint), nickname (string), transports (text[]),
                      created_at, last_used_at, revoked_at
recovery_codes        id, user_id, code_digest (string, unique), used_at, created_at
sign_in_links         id, user_id, token_digest (unique), expires_at, used_at, created_at   # operator recovery only
users                 + webauthn_handle (binary 64, unique, null until first enrolment)
```

No change to `users.id`, `identities`, `sessions` or any history table. Nothing is backfilled. The
existing Last.fm identity row stays what it is.

### 2.3 Endpoints and authorization

| Endpoint | Who | Does |
|---|---|---|
| `GET /api/session` | anyone | `{ signedIn, user: { displayName, timezone }, methods: { passkeys: n, lastfm: bool } }`. Replaces the signed-out meaning of `ConnectionState`. |
| `POST /api/passkeys/options` | signed in | `options_for_create` with the user's handle and existing credentials excluded; challenge in an encrypted 5-minute cookie |
| `POST /api/passkeys` | signed in | verifies `from_create` against the cookie challenge; stores the credential; first enrolment also returns recovery codes once |
| `DELETE /api/passkeys/:id` | signed in | revokes; refused for the last one unless a recovery code set exists |
| `POST /api/auth/passkey/options` | anyone, rate limited | `options_for_get` without `allow`; challenge cookie |
| `POST /api/auth/passkey` | anyone, rate limited | `from_get`, looks the credential up by its id, verifies with the stored public key and sign count, updates `sign_count` and `last_used_at`, `start_session_for(user)` |
| `POST /api/auth/recovery` | anyone, rate limited (5/hour) | constant-time digest lookup, marks the code used, signs in, flags the session `needs_passkey` |
| `GET /api/auth/link/:token` | anyone | operator link: single use, 15 minutes, signs in |
| `GET /api/sessions`, `DELETE /api/sessions/:id` | signed in | list and revoke other browsers (the table already has `ip_address`, `user_agent`, `last_seen_at`) |
| `DELETE /api/session` | signed in | unchanged |

Rules: no sign-up route exists. A passkey can only be enrolled by a signed-in user. Nothing links
an identity to a user from an unauthenticated request. Sign-count regression (`SignCountVerificationError`)
refuses the sign-in and logs a warning, since the owner's authenticators are all modern.
`account` deletion's confirmation becomes the display name, not the Last.fm username.

WebAuthn relying party: `rp_id` must be the site's host, and **passkeys are bound to it**. The
owner decided (§6) to put Runout on a custom domain first: the domain is added to the Railway
service, HTTPS and the redirect from the Railway hostname are verified, `APP_ORIGIN`, the Spotify
redirect URI and the Last.fm callback are updated, and only then is the first passkey enrolled with
`rp_id` set to that domain. Moving domains later would invalidate every passkey (recovery codes
would still work).

The operator link is an emergency procedure, not a sign-in method: the task runs only over
`railway ssh` with the user's UUID and display name as arguments (both checked), prints a link that
is valid 15 minutes and single use, writes a log line naming the user, and the route refuses when the
feature flag is off. There is no web form that issues one. The procedure is written up in
`docs/railway-deployment.md` §8 beside the other recovery steps.

### 2.4 Decoupling the history from Last.fm (same phase, separate PR)

- `ConnectionState` keeps describing the Last.fm *connection*, but `"none"` is returned only to a
  signed-in user without one; signed-out callers get 401 from everything except `GET /api/session`,
  `GET /api/connection` (which then says `{ status: "signed_out" }`) and the auth routes.
- The 409 `not_connected` gate on Overview, Search, Calendar, Plays, On This Day, Genres and Loved
  becomes "has any stored play" (`scrobbles` exist for the user), so the archive opens without
  Last.fm. The Last.fm connection panel in Settings keeps its import and sync controls.
- Frontend: a signed-out screen with "Sign in with a passkey", "Use a recovery code" and, until the
  fallback is retired, "Sign in with Last.fm"; Settings gets a "Sign-in" section: passkeys (name,
  added, last used, remove), recovery codes (regenerate), other sessions.
- `Lastfm::AccountPolicy` stays for the Last.fm connection; `LASTFM_ALLOWED_USERNAME` keeps
  deciding which Last.fm account may be linked.

**Done 2026-11-05 (PR `decouple-history-from-lastfm`):** `GET /api/connection` answers `signed_out` with no
session and `none` for a signed-in account without Last.fm (with `displayName`, `timezone`, `theme`); the
data endpoints' 409 is now "no stored plays" (`require_stored_plays`); account deletion confirms by display
name (`confirm_name`); the signed-out Overview leads with "Sign in"; the sidebar and account menu show the
display name. The signed-out screen and the Settings Sign-in section landed earlier (PR #16).

### 2.5 Migration, rollback and risks

0. Custom domain live and verified (owner's step, before any passkey exists): HTTPS, redirect from
   the Railway hostname, Last.fm and Spotify callbacks working, polling unaffected.
1. Deploy PR 1 (backend) and PR 2 (frontend) with `RUNOUT_PASSKEYS_ENABLED=false`: routes answer 404.
2. Rehearse on a disposable copy of production (the post-import backup restored locally, as the
   Loved check was done): enrol, sign out, sign in with the passkey, revoke, recover with a code,
   recover with the operator link, regenerate codes.
3. Switch the flag on in production. Signed in with Last.fm, enrol the first passkey (phone and
   laptop), save the recovery codes in the password manager. Sign out; sign in with the passkey.
   Test one recovery code in production too, then regenerate the set.
4. Keep Last.fm sign-in for **at least seven days** of normal use. Before proposing the cutover,
   verify passkey sign-in, session persistence across days, recovery codes and the whole library
   opening without Last.fm. **The cutover (PR 4) needs the owner's explicit approval; it is never
   automatic.** The route stays, hidden, for one more release after that.

Rollback at any step: set the flag off and redeploy, or redeploy the previous image. Sessions,
users and history are untouched by every step; the new tables can stay or be dropped by the
down migrations tested on `RAILS_ENV=test`. Nothing in Phase 1 writes to Last.fm or Spotify.

Risks: a lost phone with a passkey (revoke it from Settings on another device; the passkey alone
cannot sign in without the device's own unlock); a browser without WebAuthn support (recovery code
or Last.fm fallback); `rp_id` lock-in to the domain (§7); the challenge cookie needs the same
`SameSite=Lax` path handling as the OAuth cookies (tested).

### 2.6 Offline access (separate milestone, not built here)

What is practical and safe, for the later milestone (§6 of this plan lists the decisions):

- A service worker (vite-plugin-pwa) caching the app shell, plus explicit "keep offline" actions
  that store chosen API responses (a year of Time Machine days, the loved library, the diary) in
  IndexedDB. Nothing is cached silently; the cache never includes other users' data.
- Private notes at rest: IndexedDB is per origin and per browser profile, not encrypted beyond
  device encryption. Either accept device encryption (phones and laptops with full-disk encryption)
  or encrypt with a key derived from the passkey's PRF extension, which not every authenticator
  supports. Decide per device when it is built.
- Session expiry offline: the cached session must expire with the cookie; the app shows cached data
  read-only after expiry and clears on explicit sign-out. A lost device is handled by revoking the
  session and passkey from another device; the local cache is then stale data the thief already
  had, which is why the choice above matters.
- Writing diary entries offline: entries carry a client id and `updated_at` version; sync sends
  changes, the server keeps both texts on a conflict (two versions, never a silent overwrite) and
  the diary shows "needs merging". No deletion syncs from offline.

## 3. Phase 2: Spotify playlists from On This Day

### 3.1 Spotify rules that shape the design (checked 2026-11-04)

- Playlist endpoints after February 2026: `POST /me/playlists` (create), `POST /playlists/{id}/items`
  (add, `uris`, 100 per request), `GET /playlists/{id}/items`, `GET /me/playlists`. The old
  `/users/{id}/playlists` and `/playlists/{id}/tracks` are gone; playlist item rows now use `item`,
  not `track`.
- Scopes: `playlist-modify-private` for a private playlist (Spotify creates public by default, so
  Runout always sends `public: false`), `playlist-read-private` to find a playlist Runout created
  when a response was lost. Nothing else. The upgrade re-consent must request these **together with**
  `user-read-recently-played`: a Spotify token carries only the scopes of the request that made it,
  so requesting the playlist scopes alone would stop polling.
- Search: `GET /search?type=track&q=...` with `isrc:` and `track:`/`artist:` filters, at most 10
  results per request (February 2026), paced by the existing 0.5 s pacer.
- Development Mode: the app owner needs active Premium, at most 5 users, quota counted per
  developer account with `429 QUOTA_EXCEEDED` when used up. The quota is shared with polling, so
  matching must be frugal: one search per song, results remembered.
- Batch `GET /tracks` is gone: verifying an ID is `GET /tracks/{id}`, one at a time, only when needed.

### 3.2 Database (additive)

```
catalogue_external_ids   id, entity_type ('track'), entity_id (tracks.id), provider ('spotify'),
                         external_id (text), isrc (text), kind ('observed' | 'isrc' | 'search' | 'manual'),
                         state ('confirmed' | 'candidate' | 'rejected'), evidence (jsonb: titles compared, query, score),
                         decided_by_id (users), created_at, updated_at
                         unique (provider, entity_type, entity_id, external_id); index (entity_type, entity_id, state)
playlists                id (uuid), user_id, kind ('on_this_day' now; 'period', 'loved', 'diary' later),
                         selection (jsonb: date, years, unique, lovedOnly, sort, excludedKeys, includedKeys),
                         name, description, public (false), state ('draft' | 'resolving' | 'ready' | 'creating' | 'created' | 'failed'),
                         spotify_playlist_id, spotify_url, matched_count, added_count, error, attempt_token,
                         created_at, updated_at
playlist_items           id, playlist_id, position, track_id (nullable), identity_key (text),
                         artist_name, track_name, first_played_at, plays_in_selection,
                         spotify_track_id, match ('verified' | 'matched' | 'ambiguous' | 'unavailable' | 'unmatched' | 'manual' | 'excluded'),
                         candidates (jsonb), added (boolean)
```

The Spotify mapping lives beside the catalogue (`catalogue_external_ids`, the table the long-term
architecture §5 already planned), never on `name_variants` or `tracks`. A confirmed mapping is
reused by later playlists; a manual correction is a `review_decisions` row too. Nothing about
scrobbles, variants or catalogue links changes.

### 3.3 Selection and sorting (`Playlists::Selection`)

Input: the same calendar day across the years `Analytics::OnThisDay` computes (local day ranges in
the reporting timezone), optionally a subset of years, optionally loved only. Output: one row per
identity key (`t<id>`/`m<hash>`) with `first_played_at` (earliest event in the selection),
`last_played_at`, `plays_in_selection`, and the play count for "every listen" mode.

- **Unique songs (default):** one row per identity key, so two variants of the same catalogue
  track ("The Pixies"/"Pixies") are one song; two different catalogue tracks with the same title
  (different recordings) are two rows, shown with their album for telling apart.
- **Every listen:** one row per play, in event order; the same song may appear many times, which is
  what Spotify will also show.
- **Chronological:** by the event timestamp (`played_at, seq`), oldest first; in unique mode, by each
  song's first event in the selection. Same-second plays keep their `seq` order.
- **Most played:** by `plays_in_selection`, which is the count inside the chosen days and years
  only, then chronological.
- **Most recently listened:** by `last_played_at` within the selection, newest first.
- **Shuffle:** server-side with a stored seed, so the preview and the created playlist agree.

The generator takes a list of day ranges, so "a month", "a summer", "a year" and "songs from a
memory" are the same code with different ranges later.

### 3.4 Matching (`Playlists::Resolver`, a Solid Queue job per draft)

For each item, in order, stopping at the first success:

1. **Verified:** a `catalogue_external_ids` row `confirmed` for the track, or any `listening_observation`
   of a variant of the same identity with a `provider_track_id` (Spotify told us that ID for a play of
   this song). Recorded as `observed`.
2. **ISRC:** an observation with an ISRC → `search?q=isrc:<ISRC>&type=track`; accepted only if the
   artist matches after normalisation.
3. **Search:** `q=track:"<title>" artist:"<artist>"`, up to 10 results. A result is accepted only
   when, after `CatalogName.normalize` on both sides, the artist equals and the title equals once
   *release annotations* are stripped (remaster/remastered/reissue/anniversary/deluxe/explicit, in
   brackets or after a dash). A remaster is an acceptable **playlist alternative** only: the
   mapping says `kind: search`, `evidence` records the annotation, and nothing in the catalogue
   calls the two recordings the same. **Version words are never stripped:** remix, live, acoustic,
   demo, edit, version, instrumental, cover, radio edit, unplugged, session must appear in both
   titles or in neither, so a live or remixed play never gets the studio version and vice versa.
   Exactly one acceptable result → `matched`. Several plausible results (different albums or
   editions) → `ambiguous` with the candidates listed, **nothing chosen: the owner picks.** Results
   that agree only on the title → `ambiguous` too; no results → `unmatched`; not playable in the
   user's market → `unavailable`.
4. **Manual:** the preview lets the user pick a candidate, paste a Spotify track link, or search
   again with a different query. A manual choice is stored as `confirmed`, `kind: manual`, with a
   `review_decisions` row.

MusicBrainz IDs are never treated as Spotify IDs. Nothing is substituted silently: only `verified`,
`matched` and `manual` items are added; the rest are listed in the preview with their reason.
Results are cached on the item (`candidates`) so re-sorting or excluding does not search again.

### 3.5 Creating the playlist

Deliberate action: the user edits the name (default "14 November — Through the Years") and the
description, sees matched / ambiguous / unmatched counts, and presses Create. Then
`Playlists::CreateJob`:

1. Lock the playlist row; refuse unless `state` is `ready` or `failed`; set `creating` with a fresh
   `attempt_token` and put `runout:<playlist id>` at the end of the description.
2. If `spotify_playlist_id` is empty, first `GET /me/playlists` (paged) and look for an owned
   playlist whose description carries the token: an earlier attempt whose response was lost. Adopt
   it instead of creating another.
3. Otherwise `POST /me/playlists` with `public: false`; store the ID and URL immediately.
4. `GET /playlists/{id}/items` to learn what is already there, then add the missing URIs in batches
   of 100, in order, marking `added` per batch. A failure mid-way leaves `failed` with the counts;
   retrying resumes from the same playlist and adds only what is missing.
5. `created` with `added_count`; the UI links to Spotify.

Errors: 401 → the existing token refresh then one retry; 403 → "needs the playlist permission",
with the upgrade link; 429 → wait `Retry-After` (the pacer already pauses everything), `QUOTA_EXCEEDED`
→ stop and say so; 5xx → retry three times with backoff, then `failed`. Every request goes through
the shared pacer, so polling and playlists never exceed Spotify's limits together.

### 3.6 Scope upgrade

Settings → Listening sources shows "Allow playlist creation": the same 3-step OAuth flow with
`scopes=playlists`, requesting `user-read-recently-played playlist-modify-private playlist-read-private`.
`Spotify::Account#connect!` keeps requiring the polling scope and stores the granted set; polling
continues through the same `ListeningSource`. If the owner declines, cancels, or Spotify refuses,
the existing credentials are left exactly as they were (the upgrade writes nothing until a token
with the polling scope is in hand), so scrobbling continues unaffected; Settings just says the
playlist permission was not granted. The first playlist action, when the source lacks the scopes,
offers this link instead of failing.

### 3.7 Frontend

- On This Day panel: "Make a playlist from this day" → `/time-machine/playlist?date=YYYY-MM-DD`.
- Playlist page: options (unique / every listen, years as toggles, loved only, sort), the preview
  list with match state per row (verified, matched with album, ambiguous with the candidates to pick
  from, unavailable, unmatched, excluded), include/exclude per row, name and description fields,
  the Create button, then progress and the Spotify link. Progress is polled from `GET /api/playlists/:id`
  every 2 s while resolving or creating.
- A "Playlists" list in Settings or on the Time Machine page: what was created, when, from which
  days, linking back to the day and to Spotify.

### 3.8 API

`POST /api/playlists` (kind, selection) → draft + resolver job; `GET /api/playlists/:id` (state,
items, counts); `PATCH /api/playlists/:id` (selection, name, description, item include/exclude,
manual match); `POST /api/playlists/:id/create` (idempotent per `attempt_token`);
`GET /api/playlists`. All scoped to `Current.user`; another user's id is 404.

## 4. Phase 3: the private music diary

### 4.1 Model

```
diary_entries          id (uuid), user_id, title (string, null), body (text), body_format ('markdown'),
                       remembered_from (date, null), remembered_to (date, null), remembered_label (string, null: "summer 2010"),
                       visibility ('private' only, CHECK), created_at, updated_at
diary_entry_subjects   id, entry_id, position, track_id (FK tracks) | artist_id (FK artists) | album_id (FK albums)
                       CHECK exactly one of the three is set; unique (entry_id, track_id) etc.
diary_entry_links      id, entry_id, play_at (timestamptz, null), play_seq (smallint, null)   # optional: "that listen"
```

- One entry, many songs: the text lives once in `diary_entries`; `diary_entry_subjects` links it to
  each song. Two songs sharing an entry is a diary fact, never a catalogue fact: the catalogue
  tables are not touched.
- Three dates stay distinct and labelled everywhere: `created_at` (when written), `updated_at` (last
  edit), `remembered_from/to` (what the memory is about), and a play's `played_at` (when listened)
  comes from `scrobbles` through the optional link.
- Songs are addressed by catalogue `tracks.id`, read through `Catalogue::Roots` like every play,
  so a later merge of two recordings moves the memories with them. A song whose identity is still
  `m<hash>` (no catalogue row: an ambiguous match) can't be attached until the catalogue review
  resolves it; the UI says so. In the current archive every played variant has a track row, so
  this is a guard for future plays, not a limit today.
- `visibility` exists from day one with a database check allowing only `private`, so later values
  are a migration and an authorization change, not a data migration (§5).
- Body: a small Markdown subset from the start: paragraphs, emphasis (`*` and `**`), bullet and
  numbered lists, and links. Rendered in the browser by a small in-house parser that builds React
  elements directly, so there is no HTML string and no `dangerouslySetInnerHTML` anywhere: raw HTML
  in the text is shown as text. Links accept `http(s):` only and open with
  `rel="noopener noreferrer nofollow"`; there are no images, embeds or auto-loaded previews, so
  rendering an entry never requests anything from another server and no entry text leaks through
  a URL. The same rules hold for the server (which stores the source text and never renders it).
  The editor is a plain textarea with a short formatting hint, not a rich-text component.

### 4.2 Privacy, enforced on the server

- Every diary query starts from `Current.user.diary_entries`; a foreign id is 404, never 403, so
  nothing confirms an entry exists. Covered by tests with two users.
- `GET /api/diary/marks` (the identity keys that have entries) is per user, like loved keys.
- `config.filter_parameters` adds `body`, `title`, `remembered_label`; the API logs no entry text;
  exceptions carry ids only.
- No diary text leaves the server: never to Last.fm, Spotify, MusicBrainz or any model. Search is
  Postgres full-text (`tsvector` on title and body, per user) inside the diary endpoint, not the
  history search.
- Backups: the tables are in the same encrypted dump; nothing to add. Account deletion cascades.
- No dormant sharing routes. Friends, comments and public pages do not exist in code until Phase 5
  builds their authorization and tests.

### 4.3 API

| Endpoint | Does |
|---|---|
| `GET /api/diary/entries?cursor&q&track&artist&from&to` | journal, newest written first; `q` searches title and body; filters by subject and remembered period |
| `POST /api/diary/entries` | title, body, remembered dates/label, subjects (track keys), optional play link |
| `GET /api/diary/entries/:id`, `PATCH`, `DELETE` | one entry; `PATCH` keeps `created_at`, sets `updated_at` |
| `GET /api/diary/subjects/:key` | the entries about one song, and the other songs that share entries with it ("connected songs") |
| `GET /api/diary/marks` | identity keys with entries, for the indicators |

### 4.4 Frontend

- `/diary` (06 in the nav; Lyrics, Mood and Settings shift): the journal, one column, generous
  measure and type size for reading; each entry shows title, the remembered period, the songs
  (with hearts where loved), the written date in small type, and expands in place. Search and
  filters at the top, like the loved library.
- Entry editor: a page, not a modal, so long writing is comfortable; a plain textarea that grows,
  title, "about when" (a date, a range or a free label such as "the winter I moved"), the song list
  with search to add more; save, delete with confirmation; an unsent draft kept in `localStorage`
  only (never the saved text).
- From the music: an "Add a memory" action in the Search results, the Time Machine play log, the
  Loved library and (when the track page exists) the track view, opening the editor with that song
  attached; a small mark (a pen or quill glyph, like the heart) beside songs with entries, with a
  popover listing their titles.
- Connected songs: on an entry, the other songs it links; on a song, the entries and the songs that
  share them.

### 4.5 Built (2026-11-07): Memories, the first version

Phase 3 shipped as **Memories**, narrower than §4.1 where the first version could be simpler and
unchanged where the model mattered:

- **One memory, one song.** `memories` (user_id, track_id, body, remembered_on, remembered_label,
  visibility = `private` by database check, timestamps). Plain text, no Markdown yet; the
  subjects table and the play link of §4.1 are not built, and can be added without touching
  these rows.
- **Identity through the merge chain.** A memory is written against the catalogue track at the end
  of its merge chain at the time of writing (`Memories::Songs.resolve`). Reading goes the other
  way: a song's memories are those attached to any track whose chain now ends at it
  (`Catalogue::Roots`), so a later merge moves them, a correction that re-links a variant leaves
  them with the recording they were written about, and nothing is copied or lost. A song the
  catalogue could not place (`m<hash>`) cannot carry a memory yet; the API says `song_not_identified`.
  **Known limitation: a merge later reversed.** A memory written while two recordings were merged is
  stored against the merged-into track, because that is where the chain ended. If that merge is ever
  undone (the catalogue has no operation for this today; it would mean clearing `merged_into_id` by
  hand), the memory stays with the track it was stored against, which may not be the recording the
  person was listening to. Nothing is lost: the row still exists under their account and can be
  reattached by updating `memories.track_id`. The fix, if reversal is ever built, is to record the
  variant or the exact track the person wrote from, so a memory can follow a split.
- **Privacy as in §4.2:** every query starts from `Current.user.memories`; a foreign id is 404;
  `body` and `rememberedLabel` are filtered from logs; no text leaves the server; the Overview cache
  never sees memories (they are not part of its answer); account deletion cascades; the encrypted
  backup carries the table like any other and the restore check compares it with the rest.
- **Pages:** `/tracks/:key` (the song: cover, listening in all, first and last, by year, the
  memories, "Add a memory") and `/memories` (06 in the nav; songs with memories, or a journal in
  time order; search over words, songs and artists). Search results, the Overview's top tracks and
  the Time Machine's play log open the song page.
- **The operator never reads the words.** A session opened through `auth:sign_in_as` (an operator
  session, `sessions.operator`, read-only everywhere and over in 60 minutes: `docs/operator-access.md`)
  gets every memory with its text and label replaced by placeholder words of the same shape
  (`Memories::Placeholder`), and its search looks only at songs and artists. Dates stay, so the page
  reads as the person's does. The person sees the session in Settings → Account → Sessions as
  "Operator sign-in". The owner asked for this on 2026-11-08: the song with a memory may be seen,
  the diary itself not.
- **Rollout behind a per-account flag.** `users.features` lists the features an account can see
  before everyone does; `memories` is the first. Without it the Memories page, the song pages and
  the play-log links are absent and the API answers 404, as if the routes did not exist. The
  connection payload carries `features`, the navigation numbers close up around hidden items.
  Granted by hand: `bin/rails features:grant[user_id,display_name,memories]`, `features:revoke`,
  `features:list`. Nobody has it until the owner grants it.
- **Not built, by decision:** sharing of any kind, tags, moods, AI text, playlists from memories.

## 5. Phase 4 (paper only): friends and shared journals, offline

**Friends model, to build only with its authorization and tests:**

```
users                 + handle (citext, unique, null): the name friends find you by
friendships           id, requester_id, addressee_id, state ('requested' | 'accepted' | 'blocked'), created_at, decided_at; unique pair
diary_entries         visibility ('private' | 'friends' | 'public' | 'selected')
diary_entry_audience  entry_id, user_id            # 'selected' only
diary_comments        id, entry_id, author_id, body, created_at, updated_at   # on shared entries only
```

Reading rule, one place (`Diary::Visible.for(viewer)`): own entries; `friends` entries of accepted
friends; `selected` entries naming the viewer; `public` entries. A shared entry exposes its text, its
songs and its remembered period, nothing else: not the author's plays, loved songs, sources or other
entries. Friends never see listening activity unless a later feature adds an explicit per-user
choice. No counts, rankings or feed ordering by engagement: a friends page lists new shared entries
by date. Blocking hides both ways. Email (Resend or similar) becomes useful here: invitations and
recovery for people who are not the operator.

**Offline:** §2.6. Build order when it comes: shell caching, then read-only "keep offline" for a
chosen range and the diary, then offline diary writing with version-based sync.

## 6. Owner decisions (2026-11-04)

1. **Domain: custom domain before the first passkey.** Long-term authentication is not tied to a
   Railway hostname. HTTPS, the relying-party id and the redirects are verified first; the existing
   sign-in stays until the new domain and authentication are verified.
2. **Recovery: recovery codes plus the operator-run emergency link.** No passwords, no email
   service. Codes are single use, stored as digests, regenerable after signing in. The operator
   link is a documented emergency procedure with a short-lived single-use token and identity
   checks, never a public bypass (§2.3). Recovery is tested before passkeys are relied on.
3. **Last.fm sign-in stays at least seven days** after the first successful passkey use, and is
   removed only with the owner's explicit approval after the §2.5 verification. Never automatically.
4. **Spotify re-consent on first playlist use, from Settings.** Polling permissions preserved; a
   declined or failed authorization leaves scrobbling unaffected (§3.6).
5. **Remasters are acceptable playlist alternatives, not catalogue equivalence.** Several plausible
   versions, or a history recording that was itself live, remixed or acoustic, is the owner's
   choice (§3.4).
6. **Diary body: a small Markdown subset from the start** (paragraphs, emphasis, lists, links), no
   raw HTML, no embeds, no rich-text editor, rendered safely with nothing fetched from outside (§4.1).
7. **Memory dates: optional date or range plus a free label** ("Summer 2010", "When I lived in New
   Jersey"); imprecise memories are never forced into exact dates; the remembered time stays
   separate from when the entry was written.
8. **Navigation: Diary is 06; playlist creation lives inside Time Machine.** Existing hierarchy
   and design kept.
9. **Order confirmed: Phases 1, 2, 3, then 4 on paper.** Separate, tested, reviewable phases; no
   social layer or offline sync before its time.

## 7. Hard to change later

- The passkey `rp_id` (domain): changing it invalidates passkeys.
- Diary subjects keyed by catalogue `tracks.id` rather than name strings: moving later would mean
  re-attaching memories by hand.
- `catalogue_external_ids` as the home of provider IDs: later features (artist pages, Apple Music)
  will build on it.
- `visibility` as a per-entry column with a check: the friends model assumes it.
- `users.handle` uniqueness and case rules once friends exist: pick `citext` then.
- Sessions stay opaque random tokens (no JWT): revocation and the sessions list depend on it.

## 8. Test coverage

- Phase 1: `WebAuthn::FakeClient` registration and sign-in, challenge replay refused, wrong origin
  refused, sign-count regression refused, recovery code single use and rate limit, operator link
  single use and expiry, no sign-up route (404), CSRF on every POST, 401 when signed out for every
  history endpoint, the Last.fm sign-in suite unchanged, account deletion by display name;
  frontend: signed-out screen, Settings sign-in section with mocked `navigator.credentials`,
  recovery code flow, sessions list.
- Phase 2: selection (unique vs every listen, each sort, loved only, years subset, leap day,
  timezone day edges), matching (observed ID wins, ISRC, title normalisation table of cases:
  remaster accepted, remix/live/acoustic refused, artist mismatch refused, several albums →
  candidates, none → unmatched), creation (create then add in batches, lost-response adoption by
  description token, resume after partial failure, 401 refresh, 403 scope, 429 and `QUOTA_EXCEEDED`,
  no duplicate playlist on retry), scope upgrade keeps the polling scope; the production smoke test
  (fake Spotify) gains a playlist flow; frontend: preview states, include/exclude, manual pick,
  create progress, upgrade prompt.
- Phase 3: two-user isolation on every endpoint (404), filters and search, remembered-date
  validation (from ≤ to), subjects exactly-one check, deletion cascades, logs contain no body text,
  marks per user; frontend: journal, editor save/edit/delete, attach from Search/Time Machine/Loved,
  indicator, draft kept locally and cleared on save.

## 9. PRs and deployment order

| # | PR | Phase | Deploy note |
|---|---|---|---|
| 0 | Custom domain runout.idlewinny.com: `APP_ORIGINS` code (two hostnames, strict same-origin writes, sign-in on the canonical host), then DNS, certificate, `APP_ORIGIN`, callbacks (`docs/railway-deployment.md` §10) | 1 | **done 2026-11-04** (PR #13, variables switched 22:56 UTC); Railway address kept as fallback, no redirect |
| 1 | Passkeys, recovery codes, operator link, `GET /api/session`, sessions list (backend, flag off) | 1 | migration only; routes 404. **Built 2026-11-04** (PR 15): `users.webauthn_handle` is a string (the gem's base64url user id) rather than binary; the recovery sign-in's \"needs a passkey\" is the `methods.passkeys` count in the response, not a session flag; `GET /api/session` and `GET /api/passkeys` are behind the flag too. |
| 2 | Signed-out screen, Settings sign-in section (frontend) | 1 | hidden while flag off. **Built 2026-11-04** (PR 16): the choices appear only when `GET /api/session` answers (flag on); with the flag off the Last.fm button stands alone as before. The browser's own JSON WebAuthn calls are used (Chrome 128, Firefox 119, Safari 18.4 and later); older browsers get a plain message and the recovery code or Last.fm. |
| 3 | History without Last.fm: 401/409 split, gates on stored plays, deletion by display name | 1 | behaviour change, tested on the copy first |
| — | Rehearsal on the restored copy, then flag on, enrol, verify, one week | 1 | owner's go at each step |
| 4 | "Sign in with Last.fm" becomes "Connect Last.fm" | 1 | after at least seven days, only with the owner's approval |
| 5 | `catalogue_external_ids`, Spotify write client, scope upgrade flow | 2 | no behaviour change until used |
| 6 | Selection, resolver, playlists tables, creation job, API | 2 | jobs idle until a draft exists |
| 7 | Playlist page and On This Day action | 2 | first real playlist created by the owner, private |
| 8 | Diary tables, API, privacy tests | 3 | |
| 9 | Diary page and editor | 3 | |
| 10 | Attach points and indicators in Search, Time Machine, Loved | 3 | |
| 11 | Friends and offline designs (docs only) | 4 | |

Estimates for the owner's planning: Phase 1 about three working days plus the week of fallback;
Phase 2 about three days; Phase 3 about three days; Phase 4 half a day.

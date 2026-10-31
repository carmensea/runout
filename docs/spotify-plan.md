# Direct Spotify scrobbling: plan and record

Runout becomes the authoritative record of new listening: **Spotify → Runout → PostgreSQL →
Overview, Time Machine, Search**, with no Last.fm in between. Spotify comes first. The model is built
so a second provider adds a client and a mapping, not a new pipeline. The 209,383 Last.fm plays
imported on 2026-10-30 stay exactly as they are.

Builds on `docs/long-term-architecture.md` §4–6 and §9, which this implements in a reduced form.
MusicBrainz and artwork enrichment are paused (`docs/milestone-4-plan.md` §13 has the scope that
was waiting).

## 1. Spotify's rules today (checked 2026-10-31)

| Topic | What applies | Source |
|---|---|---|
| Development Mode | The app owner needs **active Premium**, or the app stops working until it resumes. At most **5 users** per app. Up to 25 apps per developer (raised from 1 in July 2026). Quota is counted **per developer account**, shared by all its apps. A quota 429 carries `"reason": "QUOTA_EXCEEDED"`. | [Feb 2026 migration guide](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide), [July 2026 changelog](https://developer.spotify.com/documentation/web-api/references/changes/july-2026), [TechCrunch](https://techcrunch.com/2026/02/06/spotify-changes-developer-mode-api-to-require-premium-accounts-limits-test-users/) |
| What Runout needs still works | `GET /me` keeps `id` and `display_name` (`email`, `country`, `product` were removed). Recently Played isn't listed as changed. Track and album `external_ids` (ISRC) were removed in February and restored in March. | same, and [March 2026 changelog](https://developer.spotify.com/documentation/web-api/references/changes/march-2026) |
| Redirect URIs | Must match exactly. HTTPS, except loopback. **`localhost` is not allowed**; use `http://127.0.0.1:PORT` or `http://[::1]:PORT`. Enforced for all apps since November 2025. | [Redirect URIs](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri) |
| OAuth flow | Authorization Code flow with the client secret held by the Rails server (a confidential client), plus `state`. Access tokens last 1 hour. A refresh may or may not return a new refresh token: store it when it does, keep the old one otherwise. `invalid_grant` means the connection must be made again. Refreshing doesn't extend the refresh token's lifetime. | [Refreshing tokens](https://developer.spotify.com/documentation/web-api/tutorials/refreshing-tokens) |
| Recently Played | `GET /v1/me/player/recently-played`, scope `user-read-recently-played`. `limit` up to 50; `after` or `before` (Unix ms, mutually exclusive); `cursors` and `next`. Each item has a `track`, `played_at` and `context`. Tracks only: podcast episodes aren't returned. **How far back it reaches isn't documented.** Widely reported: only the 50 most recent plays, with paging beyond them returning nothing. Measured in stage 2 (§4). | [Get Recently Played Tracks](https://developer.spotify.com/documentation/web-api/reference/get-recently-played) |
| No push | No webhooks or event stream for plays: polling only. Currently Playing isn't a completed play and is never stored. | |

**Scopes Runout requests:** `user-read-recently-played` only. `GET /me` needs no scope for `id` and
`display_name`.

## 2. Model (stage 1)

- **`scrobbles` stays the canonical listening event**: every analytic, Time Machine and Search
  already read it, so new plays appear everywhere without changing them.
  - It gains `source` (`lastfm`, `spotify`): the provider whose report created the play.
  - Existing rows are all `lastfm`. The default is a catalogue-only change in PostgreSQL, so no
    existing row was rewritten.
  - `played_at` stays the canonical time at second precision, with `seq` slots for plays in the same
    second.
- **`listening_sources`**: one per connected provider account:
  - provider, the provider's account ID and display name;
  - state (`connected`, `needs_reauth`, `disconnected`) and pause;
  - credentials encrypted with Active Record encryption, never serialised;
  - its polling status (stage 3).
  - One account belongs to one Runout user. Last.fm keeps `identities` and `lastfm_connections`.
- **`listening_observations`**: one provider report of one play:

| Field | Meaning |
|---|---|
| `source_event_id` | Unique per source. Spotify sends no event ID, so it's the exact `played_at` in milliseconds. The track ID is deliberately excluded (see below). |
| `reported_at`, `reported_at_raw`, `timestamp_kind` | The provider's timestamp at full precision, as sent, and what it means (`Listening::KINDS`). |
| `name_variant_id` | The exact strings, in the shared, immutable name-variant table. No MusicBrainz IDs: Spotify sends none. |
| `provider_track_id`, `provider_album_id`, `provider_artist_ids`, `isrc` | Spotify's own IDs, kept apart from MusicBrainz IDs. An ISRC is never treated as a recording ID. |
| `duration_ms`, `context` | Track length, and what the play came from (playlist, album…). |
| `scrobble_id`, `link_state`, `linked_by`, `match_evidence` | The play it attests:<br>- `created`: this report created it;<br>- `linked`: it matched another provider's play, by `rule` or `person`;<br>- `pending_review`: no play yet, and not counted, until a person decides. |
| `received_at`, `last_seen_at`, `times_seen`, `later_values` | Provenance. A later report of the same event is never applied; anything it says differently is noted. |

- **Why not the track ID in the event identity:** two plays can't finish in the same millisecond on
  one account, while a repeat of a track, even in the same second, has a different `played_at`. If
  Spotify later reports the same play with a relinked track ID, it's still one event.
- **Per-source storage switch** (`ListeningStorage`):
  - Last.fm history is still gated by `LASTFM_HISTORY_STORAGE_ENABLED`, which stays off.
  - Spotify plays are gated by `SPOTIFY_INGESTION_ENABLED`, and only inside a Spotify write.
  - Turning Spotify on never lets Last.fm history in. Spotify doesn't depend on Last.fm's terms.
- **The Last.fm importer sees only Last.fm plays.** Reconciliation, window commits, count checks
  and the weekly comparison read `source = 'lastfm'` only. A Spotify play can't be proposed for
  removal, disputed, renumbered or overwritten by Last.fm. New Last.fm plays take the slots after
  other sources' plays in the same second. (`docs/long-term-architecture.md` §9 #2, fixed.)

## 3. Recording a play

`Listening::Recorder` handles each event in its own transaction, under the user's history lock (the
same lock Last.fm commits take). Concurrent workers and Last.fm commits therefore never interleave,
and a crash mid-event leaves no play without its observation. For each event:

1. Same source and same event ID already stored: nothing new.
2. Otherwise:
   - store the exact strings as a name variant;
   - link it to the catalogue by the existing conservative rules (`Catalogue::Matcher`): exact
     normalised names, no fuzzy matching, no MusicBrainz lookup needed;
   - decide whether it's a cross-source duplicate (§5);
   - then create the play, link it to an existing one, or hold it for review.

New artists and tracks enter the catalogue as name-only entities, as unidentified Last.fm plays do.
A play never waits for metadata.

## 4. Timestamps

- **Last.fm** `played_at`: when the track started, to the second (`lastfm_start`).
- **Spotify** `played_at` (`spotify_played_at`):
  - documented only as "the date and time the track was played", to the millisecond;
  - believed to mark the **end** of playback;
  - the stored play keeps Spotify's own timestamp (truncated to the second), never the time Runout
    found it, and never an estimate;
  - the observation keeps the full value and its meaning.
- **To measure before ingestion is switched on (stage 2):** compare Spotify's recent plays with the
  same plays as Last.fm reported them (read-only), and record the offset distribution here.

## 5. Duplicates

**Within Spotify:**
- The same report fetched again is idempotent: unique `(source, source_event_id)`.
- Repeats and same-second plays stay separate: different `played_at`, and new slots.

**Between providers** (`Listening::CrossSource`; read-only, it decides and the recorder writes):
- **Candidates:** the user's present plays from other sources that no other Spotify report attests,
  whose start time lies where a play counted by Last.fm can start relative to Spotify's end time:
  - from a full `duration_ms` before it (minus 30 s of slack);
  - to the scrobble threshold before it (half the track, at most 4 minutes; plus 30 s);
  - so a track played twice in a row gives each report one candidate, not two.
- **Identity:**
  - *same*: the same catalogue track, or the same artist and title once normalised;
  - *similar*: the same artist, and the same title once a trailing " - …" and bracketed parts are
    removed ("Song - 2011 Remaster", "Song (Live)").
  - The album is ignored. Timestamps alone never link plays.
- **Decision:**
  - exactly one *same* candidate: linked; the play is counted once, and both reports are kept;
  - several *same* candidates, or only *similar* ones: `pending_review`, with the evidence, and
    nothing counted until a person decides (`Listening::Review`, audited in `review_decisions`);
  - otherwise a new play.
- **Last.fm never deletes or overwrites a Spotify play:** reconciliation can't see them (§2).
- **Before Last.fm sync is ever switched on again**, it needs the reverse rule: a Last.fm play that
  matches a stored Spotify play must be linked as a Last.fm observation, not inserted. Until then
  Last.fm sync stays off. That was already the case, and it is now a precondition.
- The 30 s slack is provisional, to be checked against the stage 2 measurement.

## 6. Stages

1. **Multi-source events and cross-source deduplication** (this commit): schema, gate, recorder,
   matching, review, Last.fm isolation, synthetic tests.
2. **Spotify OAuth** and read-only verification: connect from Settings, refresh, disconnect. A
   read-only comparison of recent Spotify plays with the archive (no writes), and the measurements
   in §1 and §4.
3. **Ingestion:**
   - polling through Solid Queue (about every 5 minutes, configurable), idempotent and with backoff;
   - `Retry-After`, refresh and pause handled;
   - a single worker per account;
   - offline catch-up and explicit gaps.
   - Off until approved.
4. **Settings and the frontend:** Listening Sources, Sync now, pause, disconnect, errors and gaps;
   coverage per source; end-to-end checks.

## 7. Future providers (not built)

The pattern for each: a `listening_sources.provider` value, a client that turns the provider's
reports into `Listening::Event`s with an honest `timestamp_kind`, and a candidate window for that
kind in `Listening::CrossSource`. Everything after the event (recording, matching, review,
analytics) is shared.

- **Apple Music:**
  - MusicKit's recently played resources are by item (albums, playlists, stations, and a recent
    tracks list), with no per-play timestamps documented for the web API;
  - the account's privacy data export has play activity with timestamps.
  - Likely an export importer first, then on-device capture through a companion (below).
- **Other streaming services:** the same shape when they offer a play history with timestamps
  (Deezer, Tidal and YouTube Music to check). Bulk exports go in as one-off imports with their own
  `source_event_id`s, so re-importing them is idempotent.
- **Local desktop players:** most can scrobble to a configurable ListenBrainz-compatible server. A
  ListenBrainz-compatible submission endpoint with per-device API tokens covers foobar2000,
  MusicBee, Navidrome, Jellyfin and multi-scrobbler without writing one integration per player. The
  submission's `listened_at` is a start time (`listenbrainz_start`).
- **A Runout companion (desktop or mobile):** submits plays to the same endpoint with its own
  stable event IDs, and can queue them offline. That is the only route to capturing plays that
  happen while the Mac is off.
- **Last.fm optional:**
  1. Independent sign-in first (`docs/long-term-architecture.md` §7).
  2. Then the reverse matching rule (§5).
  3. Then Last.fm can be disconnected without touching history.

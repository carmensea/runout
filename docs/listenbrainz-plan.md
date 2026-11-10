# Multi-user beta: collecting a tester's YouTube Music listens through ListenBrainz

Feasibility assessment and MVP sequence, 2026-11-05. **Approved by the owner 2026-11-05 (§11); no
production deployment and no real invitation without the owner's separate approval.** The tester never needs Last.fm or Spotify; Runout uses ListenBrainz's
official API only, with a token the tester issues and can revoke.

## 1. Verdict

Feasible with the existing ingestion pipeline. Runout already records provider plays through
`Listening::Recorder` (observations, cross-source dedup, review queue, per-source storage flag);
ListenBrainz becomes a second provider beside Spotify, polled instead of pushed. Two things are not
proven yet and must be checked on the tester's devices before any code: that Pano Scrobbler captures
the YouTube Music app on their phone, and that the two scrobblers' listens arrive in ListenBrainz
with the metadata Runout needs (§2, step 0).

## 2. The capture chain (what is confirmed, what is not)

| Link | Status | Evidence |
|---|---|---|
| PC: Web Scrobbler → YouTube Music | **Confirmed.** A dedicated connector exists (`label: 'YouTube Music', matches: ['*://music.youtube.com/*']`), separate from the plain YouTube one. | Web Scrobbler `src/core/connectors.ts` |
| PC: Web Scrobbler → ListenBrainz | **Confirmed.** ListenBrainz is a built-in service; a custom API URL and token are supported since 2020 (the "Properties" button), which matters for §8. | Web Scrobbler README, issue 1986 (closed, implemented) |
| Android: Pano Scrobbler → ListenBrainz | **Confirmed.** "Scrobbles to Lastfm, Librefm, ListenBrainz, Pleroma and other compatible services"; up to three "ListenBrainz-like" server accounts (release 4.41). | Pano README, releases |
| Android: Pano Scrobbler → YouTube Music app | **Likely, not documented.** Pano reads whatever an app reports to Android's media controls; the FAQ says to "use the dedicated YouTube Music app for music" and warns that non-music YouTube videos get scrobbled too. No page states YouTube Music app support outright. | Pano FAQ, site |
| ListenBrainz → Runout | **Confirmed.** `GET /1/user/{name}/listens` is readable without a token; `min_ts` (exclusive) pages forward; `count` up to 1,000 (default 25); newest first; one request per second; `User-Agent` required; rate-limit headers `X-RateLimit-Limit`, `-Remaining`, `-Reset-In`. | ListenBrainz API docs (core, usage, index) |

**Step 0, before any Runout code (the tester, 30 minutes):** install both scrobblers pointed at the
tester's ListenBrainz account; play three songs in the YouTube Music app on the phone and three in
the browser on the PC; check on listenbrainz.org that all six appear with artist, title and
`music_service` `music.youtube.com` (or `youtube.com`), and that a non-music YouTube video on the
phone does **not** appear (Pano's YouTube blocklist or "turn off YouTube scrobbling" setting). If
the phone leg fails, the fallback is the browser on the phone, or waiting for Pano to confirm the
app; Runout's design does not change either way, since it only ever reads ListenBrainz.

## 3. What ListenBrainz gives Runout

Each listen: `listened_at` (Unix seconds, the scrobbler's start time), `recording_msid`
(ListenBrainz's stable ID for the submitted artist and title strings), `track_metadata`
(`artist_name`, `track_name`, `release_name`), `additional_info` as the scrobbler sent it
(`submission_client`, `media_player`, `music_service`, `origin_url`, `duration_ms`, sometimes
`isrc`) and `mbid_mapping`, ListenBrainz's own guess at the MusicBrainz recording. Playing-now
reports are separate and never stored.

Provenance kept in Runout: the observation row keeps `provider: listenbrainz`, the raw timestamp,
`recording_msid`, `origin_url`, `music_service`, `media_player` and `submission_client` (so a play
is traceable to the phone or the PC), and the scrobble carries `source: listenbrainz`. The
`mbid_mapping` is stored as ListenBrainz's opinion in the observation's `context`, never written
into `name_variants` as a MusicBrainz ID: Runout's catalogue keeps its own conservative matching.

## 4. Secure association and incremental retrieval

- **Association by token, not by name.** The tester pastes their ListenBrainz user token (from
  ListenBrainz settings) into Runout → Settings → Sources. Runout calls `GET /1/validate-token`
  with `Authorization: Token …`; the answer carries `valid` and `user_name`. Only then is a
  `ListeningSource` (`provider: listenbrainz`, `external_account_id: user_name`) created, bound to
  the signed-in Runout user, token encrypted at rest exactly as the Spotify credentials are. A
  typed username alone would let anyone attach a public account to themselves; the token proves it
  is theirs. One ListenBrainz account per Runout user; a second Runout user cannot attach the same
  account (the existing unique index on `provider, external_account_id`).
- **Incremental polling.** A Solid Queue job per source, every 10 minutes (ListenBrainz asks for
  one request per second; Runout's pacer gets a `listenbrainz` key at 1 s): `GET
  /1/user/{name}/listens?min_ts=<cursor>&count=100`, paging forward until a short page, with the
  token sent for the relaxed limit. The **cursor** is durable: `listening_sources.high_water_at`
  (the column Spotify already uses) advances only after a page is fully recorded, so a poll that
  fails or a worker that dies leaves it where the last success put it, and the next poll resumes
  from there whether the outage lasted ten minutes or ten days. The 24-hour **overlap** is
  separate: each poll starts its read 24 hours before the cursor, so a listen a scrobbler submitted
  late with an earlier timestamp (an offline phone) is still picked up; dedup (§5) makes the
  re-read harmless. The overlap never limits recovery; the cursor does the recovery.
- **Backfill at connect.** The listens endpoint is documented as not for crawling full history.
  First connect reads the last 30 days through it; anything older comes from the export API
  (`POST /1/export/`, then poll and download a ZIP of `listens/<year>/<month>.jsonl`), which needs
  the user's own token (we have it) and is kept by ListenBrainz for 30 days. That import is a later
  PR (§9).
- **Token loss.** A 401 marks the source `needs_reauth` and pauses polling, like Spotify; the
  tester pastes a new token. Revoking the token at ListenBrainz is the tester's off-switch.

## 5. Duplicates

- **Same listen fetched twice** (overlap window, retries): `source_event_id` =
  `listened_at:recording_msid`; the existing recorder treats a repeat as "seen", never a new play.
- **Phone and PC both scrobbling:** they are two clients of one ListenBrainz account, so Runout
  sees one stream. ListenBrainz's own duplicate handling is not documented, so Runout does not
  rely on it: two listens of the same track with the same `listened_at` are one event (same
  `source_event_id`); the same track within a minute from two clients is caught by the existing
  cross-source rule's time window when it runs within a provider too (one new rule: same-provider
  candidates within 60 s with the same identity are `pending_review`, not counted twice).
- **Takeout import later overlapping live listens:** the existing `Listening::CrossSource` rule
  (same artist and title, start time within the play window → linked, not inserted; similar → review).
- **Repeats are real:** the same song twice in a row stays two plays, as with Spotify.

## 6. Missed events, limits and gaps

- `GET /1/user/{name}/listen-count` after each poll: when ListenBrainz's total minus Runout's
  stored count for that source grows, the panel shows "N listens on ListenBrainz not in Runout
  yet" and the next poll widens its overlap window to 7 days; the export import closes larger gaps.
- Rate limits: honour `X-RateLimit-Remaining` and `-Reset-In`; a 429 pauses the pacer for the
  reset time, the poll retries later; failures back off like Spotify's (`consecutive_failures`).
- The Settings panel shows last poll, last new listen, listens added, and the drift above; the
  shell banner uses the existing "attention" count for a source that needs re-auth.

## 7. Google Takeout merge (later PR)

The tester's YouTube Music history before scrobbling exists only in Google Takeout
(`watch-history` from "YouTube and YouTube Music", JSON or HTML; the JSON has been reported to
cover a shorter span than the HTML). An importer reads the entries headed "YouTube Music"
("Watched <title>", channel "<Artist> - Topic", `time`), turns each into an event with
`provider: youtube_takeout`, `source_event_id` = time + video URL, and runs it through the same
recorder, so overlaps with ListenBrainz listens are linked by the cross-source rule and the rest
become plays with `source: youtube_takeout`. Takeout records a view, not a completed listen, so
the panel labels these plays "from YouTube history" and the import is explicit, per file, with a
preview of counts before anything is written. ListenBrainz itself has a YouTube importer in a
feature branch, not released; Runout does not depend on it.

## 8. Direct-to-Runout scrobbling (later)

Both scrobblers can target a "ListenBrainz-like" server. Runout would expose the two calls they
need, `GET /api/lb/1/validate-token` and `POST /api/lb/1/submit-listens` (`listen_type` single,
import, playing_now), authenticated by a per-user token Runout issues in Settings, rate-limited
per token, feeding the same recorder with `provider: runout_scrobble`. That removes the ListenBrainz
hop with no change to the tester's apps beyond a URL and token. It needs the per-user token model
and request limits first; not in the MVP.

## 9. Runout changes and the MVP sequence

**Multi-user first.** Isolation already holds: every endpoint requires a session and scopes to
`Current.user`, the archive gate is per user, deletion is per user, backups cover all users. What
is missing is a way in without Last.fm: today the only sign-ups are a Last.fm account on the
allowlist or the operator's recovery link for an existing user.

| PR | Contents | Deploy effect |
|---|---|---|
| 0. Step 0 above | the tester's capture check, no code | none |
| 1. Invitations | `bin/rails auth:invite_link[display_name]` creates the user and a single-use 15-minute link (reusing `sign_in_links`); first visit forces passkey enrolment and shows recovery codes; two-user isolation tests on every endpoint; Settings and sidebar copy for an account with no Last.fm (mostly done by the decoupling) | nothing until a link is issued |
| 2. ListenBrainz source | `listening_sources.provider` and `scrobbles.source` gain `listenbrainz` (constraint changes, additive); `Listenbrainz::Client` (validate-token, listens, listen-count; pacer key `listenbrainz` 1 s; `User-Agent` "Runout/<version> (contact)"); connect by token in Settings → Sources; poll job every 10 minutes with the overlap window; flag `LISTENBRAINZ_INGESTION_ENABLED` gating writes exactly like `SPOTIFY_INGESTION_ENABLED`; source panel with status and drift | flag off: connect works, nothing stored |
| 3. Backfill | export API import for history before connect, and the 30-day initial read | tester's go |
| 4. Takeout import | §7 | tester's go |
| 5. Direct scrobbling | §8 | later |

Tests: validate-token success and failure, token encrypted and never logged, one account per user
and cross-user refusal, incremental paging with exclusive `min_ts` and the overlap window, repeat
fetch idempotent, same-provider near-duplicate review, rate-limit headers and 429 backoff, 401 →
`needs_reauth`, listen-count drift, provenance fields stored, the flag refusing writes, two-user
isolation, the production smoke test with a fake ListenBrainz. The usual checks before every commit.

**Production safeguards:** the owner's archive, Spotify polling, Last.fm rules and the storage
flags are untouched; the new flag starts off; the tester's source is connected only after PR 2 is
deployed and the owner switches the flag on for the beta.

Estimates: PR 1 one day, PR 2 one and a half days, PR 3 half a day, PR 4 one day.

## 10. Decisions for the owner (approved 2026-11-05, see §11)

1. Run step 0 with the tester before PR 1, so the phone leg is proven. Proposed: yes.
2. Invitations by operator link (no self-service sign-up) for the beta. Proposed: yes.
3. Store ListenBrainz's `mbid_mapping` as an opinion only, never as a catalogue MBID. Proposed: yes.
4. Initial backfill: 30 days through the listens endpoint at connect, full history through the
   export API in PR 3. Proposed: yes.
5. Poll every 10 minutes with a 24-hour overlap window. Proposed: yes; both are constants.

## 11. Owner's approval (2026-11-05)

All five decisions in §10 approved as proposed, with one clarification and six safeguards:

- **Clarification:** the 24-hour overlap must not limit outage recovery. A durable cursor is
  persisted and catch-up resumes from the last successful position after outages of any length
  (§4, "Incremental polling").
- ListenBrainz tokens are encrypted at rest and never appear in logs or exceptions (the Spotify
  credential rules and the client's redaction apply).
- Strict isolation between users: every endpoint, job and task scoped to one user; two-user tests.
- Onboarding explains that ListenBrainz listening history is public by default, before the tester
  connects.
- Genuine repeated plays are preserved, including same-second listens (the `seq` slot).
- Overlapping Spotify, Last.fm, Takeout and ListenBrainz observations are never counted twice
  (`Listening::CrossSource`, extended to same-provider near-duplicates).
- The owner's production archive and Spotify polling stay unchanged; the new flag starts off.

Order: step 0 first. If either device fails to capture YouTube Music reliably, the findings are
reported before anything is built. If both work: the multi-user architecture and security audit,
then the first implementation PR is proposed. Registration stays invitation-only. No production
deployment or real invitation without the owner's approval. PR #26 (playlists) remains parked.

## 12. Step 0 checklist (the tester, about 30 minutes; nothing in Runout changes)

Before starting: the tester creates a ListenBrainz account (a MusicBrainz login) and reads the
note that ListenBrainz listening history is public by default. Their user token is at
listenbrainz.org → Settings.

**Phone (Android, YouTube Music app):**
1. Install Pano Scrobbler (Play Store or GitHub release), grant notification access when asked.
2. Add an account: ListenBrainz, paste the token.
3. In Pano's app list, make sure YouTube Music is enabled; set YouTube (the video app) to blocked
   or disabled, so videos are not scrobbled.
4. Play three full songs in the YouTube Music app, one of them twice in a row.
5. Play one non-music YouTube video in the YouTube app.

**PC (browser, music.youtube.com):**
6. Install Web Scrobbler (Chrome, Edge or Firefox), open its settings → Accounts → ListenBrainz,
   sign in or use Properties to enter the token.
7. Play three full songs on music.youtube.com, one of them twice in a row.

**Check (owner or tester, in a browser, no login needed):**
8. Open `https://api.listenbrainz.org/1/user/<listenbrainz name>/listens?count=20`.
9. Expected: the six songs, each with `artist_name`, `track_name`, a `listened_at`, and in
   `additional_info` a `music_service` of `music.youtube.com` (PC) or the phone's equivalent, and a
   `submission_client` naming Pano or Web Scrobbler. The repeated songs appear twice. The video
   from step 5 does not appear.
10. Send the owner that page's JSON (or the listenbrainz.org listens page) and a note of anything
    that did not appear or appeared wrong (artist as a channel name, title with "(Official Video)",
    duplicates).

Pass: all six listens present and correct on both legs. Partial: one leg missing or wrong → report
before building. Either way the JSON tells Runout exactly which fields each scrobbler sends.

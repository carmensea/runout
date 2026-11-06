# ListenBrainz as a universal listening source: feasibility, experiment, architecture, PRs

Written 2026-11-06 from ListenBrainz's source and documentation and Spotify's documentation, before
any implementation. **Approved by the owner 2026-11-06 with the refinements in §8. No code until the
experiment in §3 has run and the owner authorises the implementation.** The
earlier plan (`docs/listenbrainz-plan.md`) still describes the ListenBrainz source itself; this
file settles the Spotify-through-ListenBrainz path and the parts the owner reprioritised:
YouTube Music device testing no longer blocks ListenBrainz development.

## 1. Verdict

**Feasible, with two caveats the user must be told about.** A Spotify listener who is not on
Runout's developer allowlist can connect Spotify to ListenBrainz through ListenBrainz's own Spotify
application, and Runout can read the resulting listens through ListenBrainz's documented, public
API with no Runout Spotify credentials involved. The caveats: ListenBrainz's Spotify import misses
plays the way Runout's own does (Spotify's Recently Played limits), and since 20 July 2026 every
Spotify connection, ListenBrainz's included, must be renewed every six months.

The connection to Runout is a pasted ListenBrainz user token, verified with ListenBrainz. There is
no OAuth scope today that would let Runout obtain that token or the listens on a user's behalf; the
listens themselves are public and need no token to read.

## 2. What the sources say

| Question | Answer | Source |
|---|---|---|
| Can a new ListenBrainz user connect Spotify today? | Yes. Settings → Music services offers Spotify with an "import" permission set (`user-read-recently-played`, `user-read-currently-playing`), a "listen" set (playback and playlists) or both. Listens are recorded only when the import scopes are granted. | `listenbrainz/domain/spotify.py` (`SPOTIFY_IMPORT_PERMISSIONS`, `record_listens`), `listenbrainz/webserver/views/settings.py` |
| Does it need Runout's allowlist? | No. The authorisation is between the user and ListenBrainz's Spotify application; Runout's client id, secret and dashboard never take part. | the same files; nothing in the flow references a third party |
| Which Spotify app, which quota mode? | ListenBrainz's own. Its quota mode is not published. It is an established app that predates Spotify's 2025 extended-quota criteria, and its import has run continuously through the February 2026 changes (MetaBrainz's July 2026 post discusses reconnection, not loss of access). Unverified beyond that. | MetaBrainz blog 2026-07-19; Spotify quota-modes page |
| Any cap on ListenBrainz users connecting Spotify? | None stated anywhere. A five-user cap would be a Development Mode property; ListenBrainz's import serves its whole user base. | MetaBrainz blog, docs |
| Current limitation on new connections | Spotify refresh tokens now expire six months after the user's authorisation (new apps from 18 June 2026, existing apps from 20 July 2026); refreshing does not extend it; the token endpoint then answers `invalid_grant`. ListenBrainz tells its users to reconnect every six months (`SPOTIFY_REFRESH_TOKEN_TTL = 6 months`; reminder emails a month and a week ahead). **This also applies to Runout's own Spotify polling:** the owner's connection, authorised 2026-11-01, will need re-authorising by about 2027-05-01; Runout already turns `invalid_grant` into `needs_reauth` and the shell banner. | Spotify blog 2026-06-18; MetaBrainz blog 2026-07-19; `domain/spotify.py` |
| How ListenBrainz retrieves Spotify plays | A continuous loop over connected users: `current_user_recently_played(limit=50, after=<latest listened_at in ms>)`, one page, plus `currently_playing` for "playing now" only. `listened_at` is Spotify's `played_at` taken verbatim (an end-of-play time, as Runout measured). | `listenbrainz/listens_importer/spotify.py` lines 46, 191–197, 204–262; `base.py` (10 s loop) |
| What may be missed | More than 50 plays between two of ListenBrainz's polls of that user (their loop is continuous, so rare); plays Spotify itself leaves out of Recently Played (Runout measured about one in five, `docs/spotify-plan.md` §9, [[spotify-feed-gaps]]); offline plays until Spotify reports them. | the importer; Runout's measurements |
| What each listen carries | `track_name`, `artist_name`, `release_name`; `additional_info`: `spotify_id` and `origin_url` (the track URL), `spotify_artist_ids`, `spotify_album_id`, `spotify_album_artist_ids`, `release_artist_name`, `duration_ms`, `isrc` when Spotify has one, `music_service: "spotify.com"`, `submission_client: "listenbrainz"`; plus ListenBrainz's `recording_msid` and its `mbid_mapping` guess. Enough for Runout's `Listening::Event` (names, provider ids, ISRC, duration, timestamp) and for provenance. | `spotify.py` lines 54–104; `docs/listenbrainz-plan.md` §3 |
| Repeats distinguishable? | Yes: each play has its own `listened_at` (Spotify's millisecond `played_at`, stored to the second). Two plays of the same recording ending in the same second would collapse in ListenBrainz; practically impossible for real listening. | ListenBrainz JSON docs; importer |
| Third-party OAuth to a user's ListenBrainz? | Not today. The ListenBrainz API authenticates with the user's own token (`Authorization: Token …`). MetaBrainz OAuth2 (moving from musicbrainz.org to metabrainz.org in July 2026, PKCE mandatory, apps self-registered at metabrainz.org/profile/applications) documents the scopes profile, email, tag, rating, collection, submit_isrc, submit_barcode: none for listens or tokens, and ListenBrainz's `validate-token` does not accept OAuth bearer tokens (community reports). So Runout cannot initiate a connection flow; the user pastes their token. A listens scope would be a request to MetaBrainz. | ListenBrainz API docs; MusicBrainz OAuth2 doc; MetaBrainz blog 2026-06-25 |
| ListenBrainz data terms | Listens are public and published as CC0 data dumps ("Creative Commons Zero (CC0)"; commercial use allowed, support urged). API use: one request a second, honour the rate-limit headers, send a `User-Agent` naming the app and a contact. | metabrainz.org/datasets/postgres-dumps; ListenBrainz API docs |
| Spotify Developer Terms | They bind the SDA that accesses Spotify: ListenBrainz. The clauses that matter there are "do not transfer Spotify Content to third parties … even if a user consents" (IV.2.5) and the storage and caching limits (IV.3.1–3.2). ListenBrainz's documented purpose is to publish users' listens as open data, and MetaBrainz has done so for years. Runout accesses no Spotify platform for these users; it reads ListenBrainz's public CC0 data under ListenBrainz's terms. Runout's own direct Spotify integration stays bound by Spotify's terms, as now. This is a reading of the published texts, not legal advice; the owner can ask MetaBrainz to confirm their position. | developer.spotify.com/terms v10 (15 May 2025) |
| Account creation | A ListenBrainz account is a MetaBrainz account (sign-up moved to metabrainz.org on 27 July 2026). Runout never creates one; it links to the sign-up page. | MetaBrainz blog 2026-06-25 |

## 3. The experiment (needs a real person; stop at the boundary)

Needs a Spotify account that is **not** on Runout's developer allowlist (not the owner's). The
YouTube Music tester has one if they also use Spotify; otherwise any willing friend. No Runout
credentials, no production change, nothing stored by Runout.

1. The person creates a ListenBrainz account at listenbrainz.org (MetaBrainz sign-up). They read
   that ListenBrainz listening history is public.
2. listenbrainz.org → Settings → Music services → Spotify → choose **Record listening history**
   (the import permission) → Spotify's own consent screen → approve.
3. They play three full songs on Spotify (phone or desktop, any app), one of them twice in a row.
4. After ten minutes, anyone opens
   `https://api.listenbrainz.org/1/user/<their listenbrainz name>/listens?count=10` (no token).
5. Expected, and what each proves:
   - the four listens are there, newest first, each with `listened_at`, `track_name`,
     `artist_name`, `release_name` → ListenBrainz's Spotify import works for a non-allowlisted account;
   - `additional_info.music_service` is `spotify.com`, `submission_client` is `listenbrainz`,
     `spotify_id` holds a Spotify track URL, `duration_ms` is set, `isrc` is present → enough for
     Runout's event mapping and provenance;
   - the repeated song appears twice with different `listened_at` → repeats stay distinct;
   - the URL above is a plain public GET → Runout can retrieve them with the documented API;
   - nothing in Runout's dashboard or logs took part → no Runout Spotify credentials involved.
6. They send the owner that JSON (or the listens page). The owner shares it here. If a song is
   missing, that is Spotify's Recently Played gap, expected and documented, not a failure of the path.

Also worth noting from the JSON: whether `listened_at` equals Spotify's end-of-play time (it does
in the importer's code), which fixes the dedup rule in §4.3.

## 4. Architecture review: what Runout reuses

**Reused as is:** `listening_sources` (the `listenbrainz` provider value exists since PR 1, with
encrypted `credentials`, `scopes`, `high_water_at`, status and error columns), `ListeningObservation`
and `Scrobble` (provider and source values exist), `Listening::Event` and `Listening::Recorder`
(idempotent on `source_event_id`, same-second slots, per-user history lock), the shared pacer
(`api_request_slots`, a `listenbrainz` key at one second), the poll-job pattern with the staggered
tick and per-source concurrency key (PR 3), `ListeningStorage` with a per-provider flag,
`HistoryImport::Attention` and the shell banner for `needs_reauth`, Settings → Sources and its
source status shape (`Listening::SourceStatus`), the History "Stored plays" panel (it already names
ListenBrainz), the two-user isolation and journey tests as templates, the production smoke test
with its fake services (a fake ListenBrainz is one more `when` branch in `stub.rb`).

**New, small:** `Listenbrainz::Client` (validate-token, listens, listen-count, export; `User-Agent`),
`Listenbrainz::Mapping` (a listen → `Event`), `Listenbrainz::Poller` (cursor, overlap, paging),
`ListenbrainzPollJob` and `ListenbrainzPollSourceJob` (copies of the Spotify pair), the connect and
disconnect endpoints (`POST /api/listening-sources/listenbrainz` with the token,
`POST …/disconnect`), the Sources panel entry and the onboarding guidance.

### 4.1 Mapping a listen to an event

- `provider: "listenbrainz"`, `source_event_id: "#{listened_at}:#{recording_msid}"`.
- `reported_at`: `listened_at`; `timestamp_kind` depends on who submitted it:
  `spotify_played_at` when `music_service` is `spotify.com` and `submission_client` is
  `listenbrainz` (an end-of-play time, exactly what Runout's own Spotify observations carry), else
  `listen_started_at` (scrobblers submit the start time). The kind drives the dedup window (§4.3).
- Names from `track_metadata`; `provider_track_id` from `spotify_id` (the track id in the URL),
  `provider_album_id` from `spotify_album_id`, `provider_artist_ids` from `spotify_artist_ids`,
  `isrc`, `duration_ms`; `context` keeps `music_service`, `submission_client`, `media_player`,
  `origin_url`, `recording_msid` and the `mbid_mapping` as ListenBrainz's opinion, never written into
  `name_variants`.

### 4.2 Cursor and overlap

`high_water_at` is the durable cursor: advanced only after a whole page is recorded. Each poll
reads from 24 hours before the cursor (`min_ts`, exclusive), pages forward at `count=100` until a
short page, and never bounds recovery by the overlap: a source silent for a month resumes from its
cursor and pages through everything since. `listen-count` after each poll measures drift.

### 4.3 Cross-provider dedup: the one change the existing rule needs

`Listening::CrossSource` already does the cautious thing: a new provider's report is linked to an
existing play of *another* source only when exactly one candidate has the same identity (catalogue
track, or normalised artist and title) and sits in the time window where that play's start must
be; several candidates or only similar titles go to review; timestamps alone never link.

Two gaps for ListenBrainz, and the smallest changes:

1. **Only end-of-play reports have a window.** `window(event)` raises for any `timestamp_kind`
   other than `spotify_played_at`. Scrobbler listens are start times. Change: give every kind a
   window by comparing *start times*: an end-of-play report's start is `reported_at − duration`
   (a skip can only make the real start later, which the existing NEAR window already covers); a
   start-of-play report's start is `reported_at`. The usual window becomes "the candidate's start
   within SLACK of this start"; identity rules and the review paths stay as they are.
2. **The same Spotify play seen twice, through Runout's Spotify and through ListenBrainz's.** Both
   carry Spotify's `played_at` to the second and the same Spotify track id, so an exact rule is
   safe and explainable: same user, same `provider_track_id`, `reported_at` within one second, from
   another provider → `same`, linked. Genuine repeats never share a timestamp. This rule runs before
   the window rule and is recorded in the evidence (`rule: "same_external_event"`).

Everything stays per observation: both providers' reports are kept, one play is counted, and the
linked observation carries `linked_by: "rule"` with the evidence for review. Takeout imports later
fit the start-time window the same way.

### 4.4 Backfill

At connect: the last 30 days through the listens endpoint (paged). Full history: `POST /1/export/`
with the user's token, poll `GET /1/export/{id}`, download the ZIP, record `listens/<year>/<month>.jsonl`
month by month under the same recorder, with the export id and the last finished month stored on
the source so a retry resumes and never re-adds (the recorder is idempotent anyway).

## 5. PR sequence (each on the owner's approval; flag `LISTENBRAINZ_INGESTION_ENABLED` off until the last)

| PR | Contents | Tests |
|---|---|---|
| A. Connect | `Listenbrainz::Client` (validate-token, listens, listen-count), connect by token in Settings → Sources with the public-history notice, disconnect and reconnect keeping history, one ListenBrainz account per Runout user (unique index), tokens encrypted and redacted | two users; a wrong or another user's token cannot claim an account; token never in logs or responses |
| B. Poll | mapping, poller with cursor and overlap, the job pair with the stagger, `needs_reauth` on 401, rate-limit headers and 429 backoff, `listen-count` drift | repeat fetch idempotent; failed page leaves the cursor; outage of 40 days resumes; same-second repeats kept; one source's failure leaves the other's polling; Spotify polling untouched |
| C. Dedup | start-time windows for every timestamp kind, the exact external-event rule, evidence | Spotify-direct and ListenBrainz-via-Spotify observations of one play → one play, two observations; genuine repeats stay two plays; scrobbler start times vs Spotify end times |
| D. Backfill | 30 days at connect; export-API full history, resumable | export flow with a stubbed ZIP; retry adds nothing twice |
| E. Experience | Sources panel wording (Direct Spotify vs ListenBrainz vs Historical import), onboarding guidance for a Spotify listener (create a ListenBrainz account, connect Spotify there, paste the token here) and, after step 0, for a YouTube Music listener | frontend states; captures in the five themes |
| F. Real-world check and go-live | the §3 account connected to a disposable copy, then production with the flag on | the smoke test gains a fake ListenBrainz |

Estimates: A one day, B one and a half, C one, D one, E one, F half a day with the owner.

## 6. Blockers and risks, plainly

- **No OAuth path to a user's ListenBrainz token.** The paste-a-token step is the connection for
  now. A listens scope would be a request to MetaBrainz; nothing in Runout depends on it.
- **Six-month Spotify reconnection** on ListenBrainz's side: when a user's ListenBrainz import
  stops, Runout sees no new listens; the drift check (`listen-count` against stored) cannot tell
  "stopped listening" from "stopped importing". Runout will say "no new listens from ListenBrainz
  for N days; check Spotify is still connected there". The same six-month rule reaches Runout's own
  Spotify connection (owner's by about 2027-05-01); the existing `needs_reauth` handling covers it.
- **Missed plays** are inherited from Spotify's Recently Played and said so in onboarding.
- **Public listens** are the price of the bridge; the onboarding says so before the token is pasted.
- **Terms**: the published texts support the design (§2); MetaBrainz can be asked to confirm.
- **ListenBrainz availability**: a 5xx or timeout backs the source off; nothing is lost because the
  cursor only moves on success.

## 7. Decisions for the owner

1. Run the §3 experiment with a non-allowlisted Spotify account before any code. Proposed: yes.
2. Connection by pasted token for now, OAuth later if MetaBrainz offers a scope. Proposed: yes.
3. The dedup change in §4.3 (start-time windows plus the exact external-event rule) as its own PR
   with the two-provider tests. Proposed: yes.
4. Onboarding offers both paths side by side: "Direct Spotify (needs the owner's allowlist)" and
   "ListenBrainz (any Spotify or YouTube Music listener)". Proposed: yes, ListenBrainz listed first
   for invited users.
5. Ask MetaBrainz, by email, two things: whether a listens-read OAuth scope is planned, and that
   their position on Spotify-imported listens being open data covers third-party readers. Proposed:
   yes, in parallel, not blocking A–E.

## 8. Owner's approval (2026-11-06) and refinements

All five decisions in §7 approved. Two refinements that bind PRs A–D:

- **Token minimisation.** The ListenBrainz token is used once, to verify ownership
  (`validate-token` → `user_name`), and is then discarded: incremental polling reads public listens
  without a token. The source stores the verified username and the ownership binding only. The
  token is kept, encrypted, solely for a feature that needs it (the export-API backfill, §4.4),
  and that feature asks for it in its own step; Runout will say what it keeps and why. Polling
  without a token is subject to the lower anonymous rate limit, which one request a second
  respects anyway.
- **Deduplication.** ListenBrainz stores `listened_at` to the second; Runout's Spotify observations
  carry milliseconds. The exact rule in §4.3 therefore compares the Spotify track id and the
  timestamps *truncated to the second*, one-to-one (an observation links to at most one play, and
  a play gains at most one observation per provider), with the provenance kept on both sides.
  Anything short of that evidence goes through the existing name-and-window rule, and anything
  ambiguous goes to review. Nothing ambiguous and no genuine same-second repeat is ever removed.

Also from the owner: ListenBrainz's Spotify capacity is not to be assumed unlimited because no cap
is documented; the MetaBrainz outreach asks about it. The outreach (in parallel, not blocking):
approval for the `listenbrainz:connect-services` OAuth scope if it exists for third parties, any
supported read-only account-linking authorisation, the use of Spotify-derived listens in Runout's
private analytics and independent history store, and any restrictions or planned changes.

## 9. Experiment checklist (for a Spotify user not on Runout's allowlist)

About twenty minutes. Nothing from Runout is involved; the owner only looks at a public page.

1. Go to listenbrainz.org and create an account (it signs you up at metabrainz.org). Note: your
   ListenBrainz listening history is public.
2. On listenbrainz.org open **Settings → Music services**. Under Spotify choose **Record
   listening history** and approve on Spotify's consent screen.
3. On Spotify, play three songs all the way through. Play one of them twice in a row.
4. Wait ten minutes.
5. Send the owner your ListenBrainz username. The owner opens
   `https://api.listenbrainz.org/1/user/<username>/listens?count=10` and checks: four listens,
   each with `track_name`, `artist_name`, `listened_at`, `additional_info.music_service` equal to
   `spotify.com`, `submission_client` equal to `listenbrainz`, a `spotify_id`, a `duration_ms`;
   the repeated song listed twice with different `listened_at`.
6. Optional: disconnect Spotify from ListenBrainz afterwards if you do not want it kept.

A missing song is Spotify's Recently Played gap, expected. Anything else missing, or no listens
at all after twenty minutes, is the result to report.

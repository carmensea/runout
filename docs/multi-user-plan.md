# Multi-user Runout: audit and PR sequence (Spotify first, ListenBrainz ready)

Written 2026-11-05 at the owner's request, before any implementation. **Stop point: the owner
approves this plan before code is written.** No production registration settings change and no
real user is invited without the owner's approval. PR #26 (playlists) stays parked. The owner's
account, archive and Spotify polling are preserved exactly.

## 1. Audit: single-user assumptions in the code today

Method: every API controller, job, rake task, table and the frontend copy were read for anything
that assumes one user or leaks across users. Severity: **blocker** (must change before a second
user), **fix** (wrong or confusing for a second user, not a leak), **ok** (already multi-user).

### 1.1 Authentication and registration

| Finding | Severity | Plan |
|---|---|---|
| No way in without Last.fm: users are created only by `Lastfm::SignIn` for an allowlisted username, or exist already for the operator's recovery link. There is no sign-up route (by design, 404). | blocker | PR 2: `bin/rails auth:invite_link[display_name,timezone]` creates the user and a single-use 15-minute link through the existing `SignInLink`; redeeming it signs the new user in and sends them to enrol a passkey. No public registration. |
| Sessions, passkeys, recovery codes, sign-in links are per user with cascading deletes; every passkey and recovery-code action uses `Current.user`; the recovery sign-in is rate-limited per IP. | ok | two-user tests in PR 1 |
| A new user has no passkey and no Last.fm identity. If the invitation link expires before enrolment, the account has no way in. | fix | PR 2: the operator re-issues a link (same task, by display name); the first visit lands on Settings → Account → Sign-in with "Add a passkey" first, and the session stays until a passkey exists. |
| `GET /api/session` reports `methods.lastfm`; the signed-out screen still offers "Sign in with Last.fm", which a tester cannot use (allowlist). | fix | PR 2: keep the button (the owner needs it until the cutover), add one line under it: "Last.fm sign-in is for the archive's owner; invited users sign in with a passkey." |
| The operator link lands on `/overview`, where a user with no plays sees "No listening history is stored yet". | fix | PR 2: land invited users on Settings → Sources after enrolment, with the onboarding steps (§3). |

### 1.2 User scoping on data

| Finding | Severity | Plan |
|---|---|---|
| Every data controller requires a session; every lookup is through `Current.user` (reviews, listening sources, passkeys, browser sessions, sync and import). No unscoped `find(params[:id])` exists. The archive gate is "this user's stored plays". Search joins the user's own scrobbles ("never anything only another user played"). | ok | PR 1 adds the two-user test matrix (every endpoint, both directions: 404 or empty, never the other user's data) |
| The catalogue is global by design: `artists`, `albums`, `tracks`, `name_variants`, genres, metadata, catalogue reviews and inferences carry no `user_id`. Plays, loved tracks, observations, sources, corrections, removals and decisions are per user. A second user's plays can create variants and catalogue rows that the first user never played; analytics only ever join through the user's own scrobbles, so nothing of another user's listening is visible. What *is* shared: catalogue merges and manual corrections (`catalogue_reviews`, `metadata_overrides`) apply to everyone's charts. | ok for the pilot | note in the plan; a per-user override layer is a later milestone if a tester's correction ever conflicts with the owner's |
| `review_decisions`, `scrobble_corrections`, `scrobble_removals`, `reconciliation_disputes` have `user_id` with cascade and `decided_by_id` with nullify: deleting a user removes their rows and keeps others' audit trails. | ok | |
| `listening_gaps` and `listening_polls` have no direct user FK but cascade through `listening_sources`. | ok | |
| Account deletion: `DELETE /api/account` destroys the user; every per-user table cascades (verified in the schema, §1.2 rows above); `Identity` holds the encrypted Last.fm key. Deletion confirms by display name (decoupling PR). | ok | PR 1 test: delete user B, assert user A's counts unchanged and B's rows gone from every table |

### 1.3 Background jobs

| Finding | Severity | Plan |
|---|---|---|
| Spotify: `SpotifyPollJob` enqueues one `SpotifyPollSourceJob` per active source; each runs under its own concurrency key and the poller's advisory lock; a failure backs off that source only (`consecutive_failures`, `next_poll_at`). One user's 401, `needs_reauth` or 429 never stops another's job, but a **429 or `QUOTA_EXCEEDED` pauses the shared pacer for everyone**, which is correct: the quota is per developer account. | ok | PR 3 test: source B failing (401, 429, invalid grant) while source A polls normally |
| Last.fm sync tick is per eligible user; off while history storage is off. | ok | |
| `CatalogueMatchJob`, `MetadataEnrichJob`, `CountCheckJob` work on the global catalogue, not per user. | ok | |
| Poll schedule: `SPOTIFY_POLL_SCHEDULE` every 5 minutes for every source → with N sources, N requests per 5 minutes, plus refreshes. Five users: 1,440 requests a day, well inside what a single source already does today times five. Rate limit is a 30-second rolling window; the pacer's 0.5 s spacing holds. | ok | PR 3: per-source stagger (sources spread across the 5 minutes) so five polls never land in the same second |

### 1.4 Source connections

| Finding | Severity | Plan |
|---|---|---|
| `Spotify::Account#connect!` binds the source to the user named in the signed OAuth `state`; the same Spotify account reconnecting keeps its source; a Spotify account already connected to another Runout user is refused (`AccountTaken`, unique index on provider + external account). Tokens are encrypted at rest; the client redacts them. Cursor and status live on the source (`high_water_at`, `next_poll_at`, `last_error`, `scopes`). | ok | PR 3 test: user B cannot connect user A's Spotify account; B's callback never touches A's source |
| The Spotify redirect URI and client are one app: fine, Development Mode allows 5 users on the dashboard's User Management list. The owner adds each tester's Spotify email there before they connect. | ok | PR 4 runbook step |
| `SPOTIFY_INGESTION_ENABLED` is global: on in production for the owner. A new user's polling is therefore on as soon as they connect. | fix | PR 3: a per-source `ingestion_enabled` is unnecessary for the pilot; instead the connect step tells the user collection starts now, and the source can be paused per user (exists). The global flag stays the kill switch. |
| `ListeningSource` and `ListeningObservation` providers are constrained to `spotify`; `scrobbles.source` to `lastfm`/`spotify`. | fix | PR 3: constraints gain `listenbrainz` now (additive), so the ListenBrainz PR later adds no migration to live tables |
| Last.fm: `LASTFM_ALLOWED_USERNAME` single-account mode refuses any second Last.fm account. Testers do not use Last.fm. | ok | unchanged |

### 1.5 Settings and pages for a user with no Last.fm

| Finding | Severity | Plan |
|---|---|---|
| Settings → History (import and sync) is Last.fm's. For a user with no connection the endpoints answer (`SyncHealth` tolerates a missing connection; `ImportStatus` to be verified in PR 1's two-user test) but the panel talks about "your Last.fm history". | fix | PR 2: hide the History tab for an account with no Last.fm connection; Sources says "Runout keeps the plays Spotify reports; nothing is imported from Last.fm." |
| Sources → Last.fm panel shows "Historical archive / account". | fix | PR 2: for `none`, the panel says "Not connected" with no button (the owner's archive is the only Last.fm import; connecting Last.fm for others is a later decision). |
| Overview intro: "Every scrobble in your Last.fm history". Time Machine loading copy "Checking your Last.fm connection". Delete-account copy mentions the Last.fm key. `/connect` placeholder route says "Connect Last.fm". | fix | PR 2: copy becomes source-neutral ("your listening history"); `/connect` becomes the onboarding page |
| Empty archive: every chart and page already has an empty state ("No listening history is stored yet", "There are no scrobbles in your history yet"); the 409 gate makes the Overview show the connect prompt until the first play lands. | ok | PR 1 test with an account of 0, 1 and 3 plays |
| The shell banner's "attention" counts Last.fm review items and a failed Last.fm connection only; Spotify's "plays to check" show in Sources. A Spotify `needs_reauth` source is not in the banner. | fix | PR 3: `attention` gains sources in `needs_reauth`, so a revoked Spotify permission is visible on every page |
| Theme follows the account (`users.theme`); loved tracks, preferences and sessions are per user. | ok | |

### 1.6 Operations

| Finding | Severity | Plan |
|---|---|---|
| Rake tasks: `auth:recovery_link` takes a user id; `loved:import`, `spotify:verify` and the archive tasks act on the owner's account by configuration (single Last.fm user). | ok | tasks that need a user take an explicit id; documented in PR 2 |
| Backups dump the whole database (all users) and the restore test compares table checksums; the encryption keys are shared. A tester's data is in the owner's backups, which the beta terms state. | ok | PR 4 verifies a backup and restore after the first tester's data exists |
| Production smoke test signs in one fake Last.fm user. | fix | PR 4: the smoke test gains a second, invited, Spotify-only user and the isolation assertions |

### 1.7 Spotify API limits (checked 2026-11-05, see `docs/playlists-plan.md` §1 for sources)

Development Mode: the owner needs active Premium; **5 users per app**, allowlisted by email in the
dashboard; the quota is per developer account and shared by all its apps; `429` with
`reason: QUOTA_EXCEEDED` when used up; rate limit on a rolling 30 s window. Recently Played returns
the 50 most recent plays and is known to omit some events (`docs/spotify-plan.md` §9 and the
measured gaps): onboarding says so plainly. Polling does no metadata lookups: a play is stored from
the Recently Played item itself.

Pilot size: the owner plus at most four testers. The fifth slot is reserved for the owner's second
account if ever needed. Each connected source costs 12 requests an hour; five sources are 60 an hour.

## 2. Target design

- **Accounts:** a `User` with a display name, timezone and theme; sign-in by passkey or recovery
  code; Last.fm identity optional (the owner only); any number of `listening_sources` per user,
  one per provider account. Sources are independent: a user may have Spotify, ListenBrainz, both
  or none; each has its own credentials, cursor, status, schedule and errors.
- **Providers:** `Listening::Recorder` and `Listening::CrossSource` already take the provider from
  the source. A `Listening::Provider` registry (`spotify` now, `listenbrainz` after step 0) maps a
  provider name to its client, poller and settings panel, so adding ListenBrainz touches no
  Spotify code. Cross-provider dedup for a user with both runs through the existing rule (same
  artist and title within the play window → linked, never counted twice; similar → review).
- **Isolation rules, enforced and tested:** every endpoint scoped to `Current.user`; another
  user's id is 404 or an empty list; provider callbacks bind to the user in the signed `state`;
  jobs take a source id and re-check ownership on load; the catalogue stays shared, listening data
  never is.

## 3. Onboarding (the invited user, five screens, nothing else)

1. **Invitation:** the operator runs `bin/rails auth:invite_link["Dana",America/Los_Angeles]`
   over `railway ssh`, which prints a single-use link (15 minutes) and the beta note to send with it.
2. **Passkey:** the link signs them in and opens "Welcome to Runout. Add a passkey to sign in from
   now on." The existing enrolment runs; the recovery codes appear once with "Save these now".
3. **Connect Spotify:** one panel: what Runout stores (plays Spotify reports, in their own archive),
   the known limitation ("Spotify reports your 50 most recent plays and sometimes misses one; Runout
   records what it gets and never invents the rest"), the beta note (the owner can see the database
   and backups contain it), and the Connect button, which runs the existing OAuth flow.
4. **Collecting:** "Spotify is connected. Runout checks every five minutes; your first plays
   appear within ten minutes of listening." with the source status.
5. **Overview:** empty until the first play, then it grows. The sidebar shows their name.

Same tokens, same five themes, no new components beyond the onboarding page.

## 4. PRs

| PR | Contents | Deploy effect |
|---|---|---|
| **1. Multi-user security and account readiness** | the two-user test matrix (every endpoint both ways, deletion boundaries, empty and small archives, `ImportStatus` without a connection); `attention` includes `needs_reauth` sources; provider constraints gain `listenbrainz` (additive migration); source-neutral copy; the History tab hidden without Last.fm; the `/connect` placeholder removed | copy changes only for the owner |
| **2. Invitation-only registration and onboarding** | `auth:invite_link`, redeem → passkey-first landing, onboarding page, "invited users sign in with a passkey" note, landing on Settings → Sources, operator runbook | nothing until a link is issued |
| **3. Multi-user Spotify connections and polling** | poll stagger per source, per-user failure tests (401, 429, invalid grant, revoked permission), `AccountTaken` and callback-ownership tests, onboarding limitation copy, dashboard allowlist step in the runbook | no change for the owner's source |
| **4. Pilot verification** | smoke test with two users (one Last.fm, one invited Spotify-only); rehearsal on the disposable copy with two synthetic accounts; backup and restore check; the owner's go-live checklist: allowlist the tester's Spotify email, issue the link, watch the first poll | owner's go at each step |

Estimates: PR 1 one day, PR 2 one day, PR 3 one day, PR 4 half a day with the owner.

## 5. Verification before any real invitation (§6 of the owner's brief)

On the disposable copy with two synthetic accounts: no cross-user API access (the matrix), no
cross-user token or source access (connect B, read A's sources: empty), no cross-user job work
(poll B while A is paused; A's cursor unchanged), independent passkeys and recovery, independent
Spotify callbacks (the `state` names the user), empty and small archives, deletion boundaries, the
owner's data checksums unchanged before and after, the owner's polling unchanged ("polls ok"),
backup and restore valid. Only after all of that, and the owner's go: production deploy with no
invitation issued, then one tester.

## 6. Decisions for the owner

1. Invitations as operator-run links with a display name and timezone, no email service. Proposed: yes.
2. Hide Settings → History for accounts without Last.fm, rather than offering Last.fm connection to testers. Proposed: yes.
3. The shared catalogue stays shared for the pilot (a tester's plays can add catalogue rows; corrections apply to all). Proposed: yes.
4. Add the `listenbrainz` provider values to the constraints now, in PR 1, so step 0's outcome needs no live-table migration later. Proposed: yes.
5. Pilot size: owner plus up to four testers on the current Spotify app. Proposed: yes.

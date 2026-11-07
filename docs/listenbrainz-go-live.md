# ListenBrainz go-live checklist (PR F)

State on 2026-11-07: PRs A–E are merged and deployed (connect, polling, cross-provider dedup,
backfill, onboarding and Sources). `LISTENBRAINZ_INGESTION_ENABLED` is not set on Railway, so it is
off; the ListenBrainz panel and welcome-page form are hidden, the tick does nothing, and the
connect and backfill endpoints answer 409. No ListenBrainz source exists anywhere.

Every numbered step below needs the owner's explicit go before it runs. Nothing here authorises
inviting anyone beyond the first YouTube Music tester, enabling the flag anywhere but Railway
production, opening registration, the MetaBrainz OAuth flow (PR G), or the playlist generator
(parked).

## 0. The tester's privacy (binding for every step)

The first YouTube Music tester is referred to only as that. Their name, ListenBrainz username,
token, listens and screenshots never enter this repository: not in docs, fixtures, tests, commit
messages, pull requests, issues or CI logs. Operator notes with their details stay outside Git.
Command output quoted below is read over `railway ssh` and not pasted anywhere public. Their
public ListenBrainz page is not consent to name them here. Before committing anything from the
pilot, read the diff for identifiers.

## 1. Decide the first tester

The first YouTube Music tester (their ListenBrainz account was checked read-only on 2026-11-06:
Pano Scrobbler on Android and Web Scrobbler on a PC both report their plays with track, artist
and time, four listens each, repeats kept). The owner says, privately: the tester's display name
and timezone, and that they may be invited and may connect ListenBrainz. The tester needs their
ListenBrainz user token (listenbrainz.org → Settings).

Tell them, in the invitation message: their ListenBrainz history is public with or without Runout;
the person running Runout can read the database; encrypted backups keep plays 30 days daily and 12
months monthly; they can delete the account in Settings → Account, which removes everything at once.

## 2. Pre-flight (read-only)

```
railway ssh -s runout -- bin/rails runner 'puts({ lb_flag: ListeningStorage.enabled?("listenbrainz"), users: User.count, sources: ListeningSource.pluck(:provider, :state), scrobbles: Scrobble.group(:source).count, loved: LovedTrack.count, lb_polls: ListeningPoll.joins(:listening_source).where(listening_sources: { provider: "listenbrainz" }).count, spotify_polls: ListeningPoll.joins(:listening_source).where(listening_sources: { provider: "spotify" }).order(:id).last(3).map(&:outcome) }.to_json)'
```

Expected: flag false, 1 user, one Spotify source connected, 209,383 Last.fm plays, 859 loved,
0 ListenBrainz polls, Spotify's last three polls `ok`. Also: the last daily backup succeeded.

## 3. Switch the flag on (Railway production only)

The flag is one switch for the whole server, not per account: while it is on, every signed-in
account sees the ListenBrainz panel and may connect one ListenBrainz account. That is safe for the
pilot because registration is invitation-only, so the only accounts are the owner's and the
tester's, and a ListenBrainz account can be bound to one Runout account only (the second attempt
answers `account_taken`). Nothing is read until an account is connected. A per-account control is
not needed for one tester; revisit before a second.

```
railway variables -s runout --set LISTENBRAINZ_INGESTION_ENABLED=true
```

Railway redeploys. Then confirm: `/up` 200; signed out, `/api/overview` 401; the Sources panel
shows ListenBrainz for the owner's account (leave it unconnected); the recurring
`listenbrainz_poll` tick runs every 10 minutes and finds no source; Spotify polling unchanged.

## 4. Invite the tester

```
railway ssh -s runout -- bin/rails "auth:invite_link[<Name>,<Timezone>]"
```

Send the link privately with the notes from step 1. Valid 24 hours, single use. Expired unopened:
run again with the same name (the empty account is reused). Not opened and no longer wanted:
`bin/rails "auth:revoke_invitation[<uuid>,<Name>]"`, which also says whether the account is empty
and may be removed.

## 5. The tester connects

Opening the link signs them in and lands on `/welcome`: passkey, recovery codes (shown once), then
the ListenBrainz token on the same page, or later in Settings → Sources. The page says that the
token is checked once and not kept, and that their ListenBrainz history is public. Confirm
server-side, read-only:

```
railway ssh -s runout -- bin/rails runner 'puts ListeningSource.where(provider: "listenbrainz").map { |s| [s.user_id, s.state, s.credentials.nil?, s.high_water_at] }.to_json'
```

Expected: one row, the tester's user id (from step 4), `connected`, credentials nil. Do not print
or copy the username.

## 6. First import (the last 30 days)

Within 10 minutes the tick polls, or the tester presses "Import your full history" (which reads
now and starts the backfill). Confirm, with the owner's account being the one with a Last.fm identity:

```
railway ssh -s runout -- bin/rails runner 'owner = User.joins(:identities).find_by(identities: { provider: "lastfm" }); puts({ polls: ListeningPoll.joins(:listening_source).where(listening_sources: { provider: "listenbrainz" }).order(:started_at).map { |p| [p.trigger, p.outcome, p.items, p.recorded] }, by_user: Scrobble.group(:user_id).count, owner: Scrobble.where(user: owner).group(:source).count, loved: LovedTrack.count, review: ListeningObservation.where(link_state: "pending_review").count, spotify: ListeningSource.spotify.pluck(:state, :consecutive_failures) }.to_json)'
```

Expected: polls `ok`; plays grow for the tester's user only; the owner's counts unchanged
(209,383 Last.fm, the Spotify count still growing); nothing pending review (the tester has no
other source); Spotify connected with 0 failures.

## 7. What the pilot must show (first-user verification)

Over the first days, each point checked read-only, results kept in private notes:

- **Ownership**: the one ListenBrainz source belongs to the tester's user id; new plays appear
  under that user id only (`Scrobble.group(:user_id).count`).
- **Metadata**: artist, title, timestamp and `source = listenbrainz` on the plays; observations
  carry `listen_started_at`, `duration_ms` in milliseconds from both scrobblers, and the submitting
  client in the context.
- **Repeats**: one track played twice at different times is two plays; two different tracks in
  the same second are both present.
- **Idempotence**: a manual second poll right after a scheduled one records `{}` (nothing new);
  `source_event_id` is unique per source.
- **Late submissions**: a listen scrobbled from a phone that was offline (an earlier `listened_at`
  than the cursor) is picked up by the 24-hour overlap on the next poll.
- **Outages**: a failed poll leaves `high_water_at` where it was and sets `next_poll_at` with
  backoff; the next successful poll pages back to the cursor, however long the gap.
- **Backfill**: `backfill_fetched` approaches `backfill_total`; plays already present from the
  30-day poll are not created again (the recorder's `created` count stays below the page size for
  the overlap pages); `backfill_before` moves only after each page is recorded.
- **Isolation**: a failure on the tester's source (for instance a renamed ListenBrainz account →
  `needs_reauth`) changes nothing for the owner's Spotify polls, and the reverse.
- **The owner's archive**: Last.fm count and loved count identical before and after.
- **Experience**, with the tester, on their phone and a desktop: they can find the token, read
  that it is checked and discarded, see when Runout last imported and whether collection is on,
  start the full import, disconnect, and delete the account; Overview, Time Machine and Search show
  their plays and nobody else's. Internal cursors and ids are not shown there.

Compare one day of listening against their ListenBrainz page: same plays, same order, same times
(ListenBrainz shows their local time, Runout the account's timezone). Ask them to play one ordinary
YouTube video with Web Scrobbler on, to learn whether non-music videos arrive (Web Scrobbler has a
per-site toggle; Pano scrobbles the YouTube Music app only). Outcome, in private notes and as a
one-line sanitised summary under "Findings" below (counts and pass/fail, no identifiers).

## 8. Full history

The tester presses "Import your full history" in Settings → Sources (or the operator runs it to
completion in one go):

```
railway ssh -s runout -- bin/rails "listenbrainz:backfill" SOURCE=<listening_sources.id>
```

Watch `backfill_fetched` against `backfill_total` on the source and the `backfill` polls; one
request a second through the shared pacer; Spotify polling must stay `ok` throughout. Done when
`backfill_state` is `done`.

## 9. Spotify through ListenBrainz (still unverified)

Not part of this go-live. Needs its own approval and a real account connected both ways
(docs/listenbrainz-spotify-feasibility.md §9): confirm that a play seen through Runout's Spotify
and through ListenBrainz's import is linked once (`same_external_event`). Until then the UI says
"not yet checked".

## 10. Rollback and recovery

Identify accounts by their immutable id plus the display name, never by name alone; the tasks
refuse a mismatch. None of these touches the owner's archive: ListenBrainz writes rows for the
tester's user only, and the linker only ever links a report to a play of the same user.

- **Unused invitation**: `bin/rails "auth:revoke_invitation[<uuid>,<Name>]"`; the empty account may
  then be removed as below.
- **Stop ListenBrainz for everyone**: `railway variables -s runout --set LISTENBRAINZ_INGESTION_ENABLED=false`
  (redeploys; polls and backfill stop, panels hide, stored plays stay).
- **One account only**: the tester disconnects in Settings → Sources, or the operator runs
  `Listenbrainz::Account.new.disconnect!(ListeningSource.find(<id>))` over `railway ssh` (polls
  stop, plays and observations stay, the binding stays so nobody else can claim that account).
- **Wrong ownership** (the ListenBrainz account was connected from the wrong Runout account): a
  ListenBrainz account stays bound to the first Runout account that verified it, even after a
  disconnect, and a source with observations cannot be deleted on its own. If the wrong account is
  an empty or mistaken second account, remove it (below) and connect again from the right one.
  If both accounts must stay, that needs a focused PR; stop and report.
- **Duplicate or misattributed plays**: within one source, duplicates cannot arise (one play per
  `source_event_id`); across users, attribution follows the source's user id and cannot cross.
  Cross-provider doubts go to the Review tab (only with two sources on one account).
- **Remove the tester entirely**, their plays, observations, polls and sign-in with them, only on
  the owner's word, after the tester has been told:
  `bin/rails "auth:remove_account[<uuid>,<Name>,DELETE <uuid>]"`. Backups made before then keep a
  copy until they age out (30 days daily, 12 months monthly).
- **Verify the owner's archive** after any of these: the pre-flight query of step 2 shows the same
  Last.fm and loved counts and Spotify polls `ok`.

## Findings

(sanitised, one line per check, after step 7 runs)

# ListenBrainz go-live checklist (PR F)

State on 2026-11-06: PRs A–E are merged and deployed (#35 connect, #37 polling, #38 cross-provider
dedup, #39 backfill, #40 onboarding and Sources). `LISTENBRAINZ_INGESTION_ENABLED` is not set on
Railway, so it is off; the ListenBrainz panel and welcome-page form are hidden, the tick does
nothing, and the connect and backfill endpoints answer 409. No ListenBrainz source exists anywhere.

Every numbered step below needs the owner's explicit go before it runs. Nothing here authorises
inviting anyone beyond the one tester named in step 1, enabling the flag anywhere but Railway
production, the MetaBrainz OAuth flow (PR G), or the playlist generator (PR #26, parked).

## 1. Decide the first tester

The YouTube Music tester (their ListenBrainz account was checked read-only on 2026-11-06: Pano
Scrobbler and Web Scrobbler both report their plays with track, artist and time). The owner says,
privately: the tester's display name and timezone, and that they may be invited and may connect
ListenBrainz. Their username is not recorded in this repository. The tester needs their ListenBrainz user token (listenbrainz.org → Settings).

Tell them, in the invitation message: their ListenBrainz history is public with or without Runout;
the person running Runout can read the database; encrypted backups keep plays 30 days daily and 12
months monthly; they can delete the account in Settings → Account.

## 2. Pre-flight (read-only)

```
railway ssh -s runout -- bin/rails runner 'puts({ lb_flag: ListeningStorage.enabled?("listenbrainz"), users: User.count, sources: ListeningSource.pluck(:provider, :state), scrobbles: Scrobble.group(:source).count, loved: LovedTrack.count, lb_polls: ListeningPoll.joins(:listening_source).where(listening_sources: { provider: "listenbrainz" }).count }.to_json)'
```

Expected: flag false, 1 user, one Spotify source connected, 209,383 Last.fm plays, 859 loved,
0 ListenBrainz polls. Spotify's last three polls `ok`.

## 3. Switch the flag on (Railway production only)

```
railway variables -s runout --set LISTENBRAINZ_INGESTION_ENABLED=true
```

Railway redeploys. Then confirm: `/up` 200; the Sources panel shows ListenBrainz for the owner's
account; the recurring `listenbrainz_poll` tick runs every 10 minutes and finds no source (nothing
happens); Spotify polling unchanged. The flag changes nothing until a source is connected.

## 4. Invite the tester

```
railway ssh -s runout -- bin/rails "auth:invite_link[<Name>,<Timezone>]"
```

Send the link privately with the notes from step 1. Valid 24 hours, single use. Expired unopened:
run again with the same name.

## 5. The tester connects

On `/welcome`: passkey, recovery codes, then the ListenBrainz token on the page (or later in
Settings → Sources). Confirm server-side, read-only:

```
railway ssh -s runout -- bin/rails runner 'puts ListeningSource.where(provider: "listenbrainz").map { |s| [s.user.display_name, s.external_account_id, s.state, s.credentials.nil?, s.high_water_at] }.to_json'
```

Expected: one row, the tester's user, their ListenBrainz username, `connected`, credentials nil.

## 6. First import (the last 30 days)

Within 10 minutes the tick polls, or the tester presses "Import your full history" (which reads
now and starts the backfill). Confirm:

```
railway ssh -s runout -- bin/rails runner 'puts({ polls: ListeningPoll.joins(:listening_source).where(listening_sources: { provider: "listenbrainz" }).order(:started_at).map { |p| [p.trigger, p.outcome, p.items, p.recorded] }, by_user: Scrobble.group(:user_id).count, owner: Scrobble.where(user: User.find_by(display_name: "thecuremusic")).group(:source).count, loved: LovedTrack.count, review: ListeningObservation.where(link_state: "pending_review").count }.to_json)'
```

Expected: polls `ok`; plays grow for the tester's user only; the owner's counts unchanged;
nothing pending review (the tester has no other source). Spotify polls still `ok`.

## 7. Real-world check (plan §9, PR F proper)

With the tester, for one day of listening, compare their public page
`https://listenbrainz.org/user/<name>/` with Runout's Time Machine for that day:

- the same number of plays, in the same order, with the same times (ListenBrainz shows the
  listener's local time; Runout the account's timezone);
- repeats of one track at different times present as separate plays; same-second plays of
  different tracks both present;
- observations carry `listen_started_at`, `duration_ms` in milliseconds for both scrobblers,
  `inserted_at` in the context (Settings → Sources → Recent imports counts them);
- the open question from step 0: whether non-music YouTube videos show up through Web Scrobbler
  (it has a per-site toggle; Pano scrobbles the YouTube Music app only). Ask the tester to watch
  one ordinary video and check the next import.

Record the result in this file under "Findings".

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

## 10. Rollback

- Stop everything: `railway variables -s runout --set LISTENBRAINZ_INGESTION_ENABLED=false`
  (redeploys; polls stop, panels hide, stored plays stay).
- One account only: the tester disconnects in Settings → Sources, or
  `Listenbrainz::Account.new.disconnect!(source)` over `railway ssh` (polls stop, plays stay).
- Remove the tester entirely (their plays and observations with them), only on the owner's word:
  `bin/rails "auth:remove_account[<uuid>,<name>,DELETE <uuid>]"`.
- The owner's archive is never touched by any of these: ListenBrainz writes rows for the tester's
  user only, and the linker only ever links a report to a play of the same user.

## Findings

(empty until step 7 runs)

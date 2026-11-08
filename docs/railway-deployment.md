# Deploying Runout to Railway

Status: **live, one archive** (cutover 2026-11-03, 04:14 UTC; archive merged 2026-11-04, 02:00 UTC).
Railway polls Spotify every 5 minutes and holds the full Last.fm archive merged with the Spotify plays
(§6). Local polling is stopped. The local archive on this Mac is unchanged, as a fallback.
Known limit: Spotify's feed omits some plays (§4).

## 1. What runs

One Railway project of its own, with two services:

| Service | What it is |
|---|---|
| `runout` | One container built from the root `Dockerfile`. Puma serves `/api` and the built React app from one origin. Solid Queue runs as threads inside Puma. |
| `Postgres` | Railway's PostgreSQL. Reached over the private network. Holds the primary database and a `runout_queue` database. |

- **Same origin:** no CORS and no proxy, so the `__Host-` session cookie, the `Origin` plus
  `X-Requested-With` CSRF check and the Spotify callback all work unchanged.
- **Cache:** sign-in rate limits are the only cache use, so they use 8 MB of process memory. Solid
  Cache and its database are gone. A deploy resets the limits.
- **Config format:** no `railway.toml`. Railway has deprecated it, new services can't opt in, and
  existing files stop being read on 2026-12-01. Railway finds the root `Dockerfile` by itself. Two
  service variables set shutdown behaviour, and the health check path is one dashboard setting.

### Solid Queue: inside Puma, async

Measured on this Mac with a production build and a copy of the real archive: memory after requests,
macOS physical footprint.

| Mode | Processes | Idle | After requests | Idle CPU |
|---|---|---:|---:|---:|
| **Async in Puma (chosen)** | 1 | 98 MB | **119 MB** | 0.18% |
| Forked by Puma | 5 | 197 MB | 267 MB | 0.32% |
| Separate `bin/jobs` | 5 | 258 MB | 300 MB | 0.25% |
| No jobs (baseline) | 1 | 93 MB | 114 MB | 0.02% |

- Async costs about 5 MB over no jobs at all. Forking costs about 150 MB more than async.
- Turning YJIT off saved nothing measurable at this traffic, so the Rails default stays.
- **These are Rosetta and macOS figures: trust the ratios, not the absolutes.** In CI's Linux
  container the image used 125 to 137 MB (cgroup, page cache included) after requests and polls, and
  A similar Rails deployment on Railway runs at 189 MB. Expect 140 to 220 MB. Check
  `railway metrics` after deploying.
- **The trade-off:** Solid Queue's README recommends fork mode, because a job shares memory and the
  Ruby lock with web requests. A job here is one short HTTP call every 5 minutes, and web traffic is
  one person.

## 2. What was tested

`server/test/smoke/production/run.sh` is the repeatable test. It builds the image and runs it beside
PostgreSQL and a fake Spotify and Last.fm on a Docker network with no internet route. CI runs it on
every pull request.

**Verified in CI on 2026-11-03** (pull request #1): the image built from this branch, booted in a
container against PostgreSQL 18, passed every check below, twice: with ingestion off (the tick stored
nothing) and on. Docker can't start on this Mac (§9), so the same driver also ran natively here.

| Area | Checked |
|---|---|
| One origin | Shell at `/` and deep links, uncached and `noindex`; hashed assets cached; frontend calls `/api`; missing assets and unknown API paths are real 404s |
| Hosts and HTTPS | Other `Host` refused; `/up` answers Railway's health check; HSTS on; cookies `Secure` |
| Sign-in | Another Last.fm account refused, no user created; `__Host-` cookie, `HttpOnly`, `SameSite=Lax` |
| Private data | Overview, Search, Plays, Calendar and Listening sources return 401 without a session |
| CSRF | POST refused with no `Origin`, a wrong `Origin`, or no `X-Requested-With` |
| Spotify OAuth | Full flow with an `https://` callback; forged state refused; tokens and the Last.fm key encrypted at rest |
| Queue | One process; async supervisor; `spotify_poll` registered; no Solid Cache tables |
| Database | All 25 migrations applied through `DATABASE_URL`; queue database derived; genres seeded; second release does nothing |
| Polling | Recurring schedule to stored plays; resumed after SIGTERM, SIGKILL, dropped connections and (natively, as dropped connections) a database restart |
| Deduplication | 65 reported events, 65 observations, 65 plays, no gaps, source identity on every play |
| Quiet by default | Only the 4 sign-in calls to Last.fm; no MusicBrainz or artwork activity; no errors logged |

**Other checks on this branch:** 537 Rails tests, RuboCop, Brakeman and bundler-audit clean; frontend
lint, type-check and build pass; 111 frontend tests pass when run serially. In parallel, 2 or 3 of them
time out when the Mac is heavily loaded, on `main` too (load average 22 at the time).

**Solid Cache removal, reviewed:** intentional. Only sign-in rate limits use the cache, and nothing else
refers to `solid_cache`, `cache.yml`, `cache_schema.rb` or `CACHE_DATABASE_URL`.

## 3. Last.fm licence review

Read from `last.fm/api/tos` on 2026-11-02 (the page has no date; check the live text before relying
on this). This is not legal advice.

**What the terms say**
- §2.3 allows storing Last.fm Data subject to local data law. Outside the EEA, it needs users'
  express permission given when they registered.
- §1 defines "Data storage" to include a server or network, "whether created or distributed by You
  or otherwise". **No clause restricts where data is hosted.**
- §2.5 limits sending data to another country without required consents. §4.3.3 bars sub-licensing.
- §4.3.4 calls the licence "temporary and restricted to a small portion of Last.fm Data", capped at
  100 MB, and prohibits "use, storage, publication..." above it without written consent.
- §2.7 allows public access only to pages Last.fm approved in writing. §3.1 is non-commercial only.
- §9.3 requires deleting Last.fm Data as soon as reasonably possible after termination.

**What remains uncertain**
1. **How the 100 MB is measured.** Figures below.
2. **Whether a complete personal history can be a "small portion"**, or "temporary", at any size.
3. **Whether a user's own scrobbles count the same way.** "Last.fm Data" is anything made available
   through the API, with no exception for your own plays.
4. **Whether a host is a sub-licensee.** Railway holding an encrypted-at-rest copy for you looks like
   a service provider, not a licensee, but the terms don't say. §2.8 also requires privacy standards
   at least as strict as Last.fm's.
5. **Whether a sign-in-gated site is "public access"** under §2.7.
6. **Whether derived data counts:** the catalogue, matches and genre results built from it.

**Where the data sits doesn't change items 1, 2, 3 or 6.** They applied to the archive on this Mac and
apply to the Railway copy since 2026-11-04. Cloud hosting adds items 4 and 5.

**The data, measured separately** (read-only, 209,383 Last.fm plays):

| Measure | Size | vs 100 MB |
|---|---:|---|
| One copy of each distinct name and ID, plus timestamps | 6.9 MB | under |
| Each play's fields as text | 26 MB | under |
| The same as minimal JSON | 56 MB | under |
| On disk: `scrobbles` and `name_variants`, of which 47 MB is indexes | 77 MB | under |
| On disk: all Last.fm-derived tables (`runout:storage_report`) | about 104 MB | **over** |
| Whole database, including app, Spotify and MusicBrainz rows | 122 MB | not the right measure |
| Full API responses as delivered, with image URLs Runout never stored | not stored; perhaps 150 MB or more (estimate) | **probably over** |

So the 104 MB figure is disk space including indexes and derived tables, not an amount of licensed
data. The answer is under or over depending on an undefined measure. **These figures don't establish
compliance.** Not Last.fm's: 1,308 MusicBrainz tags (CC-BY-NC-SA) and Spotify's plays.

**The draft email:** `docs/lastfm-permission-email.md` still says "Nothing has been imported yet",
which stopped being true on 2026-10-30. Correct it before sending. It isn't a prerequisite for
Path B.

## 4. Chosen path: Spotify-first

At cutover the Last.fm archive stayed on this Mac, and the cloud app showed only plays from cutover plus
Spotify's last 50. The owner approved the merge on 2026-11-04, so the cloud app now shows the full history
(§6). The licence questions in §3 apply to the Railway copy as they did to the local one.

**Known limit: Spotify's feed omits some plays.** On 2026-11-03, 12 of the 62 plays Last.fm held since
22:10 UTC the day before weren't in Spotify's Recently Played. Polling succeeded throughout, and local
polling missed the same older plays, so it isn't Runout or Railway. The cause is unknown; some are quick
repeats, but not all. It's one day's sample, matched by name and time. Spotify can also date a play much
later than Last.fm does (one play: Last.fm 03:16, Spotify 04:16), which matters for matching in §6.

The owner chose to leave this as it is for now. Last.fm still records these plays, so a later Last.fm sync
could add them, which means Runout isn't yet independent of Last.fm. The 2026-11-04 merge didn't add them:
the archive's Last.fm history ends on 2026-10-31. Alternatives if that changes: poll
Spotify's currently-playing endpoint (new scope, unproven), or add recent Last.fm plays to Railway (needs
the approval and matching rule in `CLAUDE.md`).

## 5. Go-live checklist

Each step is safe to stop after. Steps 7 and 8 need your explicit approval at the time.

**Before starting:** merge `railway-deployment` to `main` and confirm CI's `image` job passes.

**1. Create the Runout Railway project** (from `server/`; a project of its own)
```sh
railway init --name runout
railway add --database postgres
railway add --service runout --repo carmensea/runout --branch main
railway domain --service runout    # note the https address
```

**2. Deploy Rails and PostgreSQL with Spotify ingestion disabled**
```sh
R="railway variable set --service runout --skip-deploys"
ORIGIN=https://<the address from step 1>
$R APP_ORIGIN=$ORIGIN SPOTIFY_REDIRECT_URI=$ORIGIN/api/auth/spotify/callback \
   'DATABASE_URL=${{Postgres.DATABASE_URL}}' SPOTIFY_INGESTION_ENABLED=false \
   RAILWAY_DEPLOYMENT_DRAINING_SECONDS=30 RAILWAY_DEPLOYMENT_OVERLAP_SECONDS=0
for k in SECRET_KEY_BASE ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY \
         ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT; do
  openssl rand -hex 32 | tr -d '\n' | $R "$k" --stdin
done
(set -a; . ./.env; set +a
 for k in LASTFM_API_KEY LASTFM_SHARED_SECRET LASTFM_ALLOWED_USERNAME SPOTIFY_CLIENT_ID SPOTIFY_CLIENT_SECRET; do
   printenv "$k" | tr -d '\n' | $R "$k" --stdin
 done)
```
- Never set `LASTFM_HISTORY_STORAGE_ENABLED` or `METADATA_ENRICHMENT_ENABLED`: both stay off.
- In the dashboard: `runout` → Settings → Healthcheck Path = `/up`.
- Deploy: `railway redeploy --service runout`.
- Copy the encryption keys into your password manager from the dashboard.

**3. Verify the application and authentication**
- `curl -s -o /dev/null -w '%{http_code}\n' $ORIGIN/up` returns 200; `$ORIGIN/api/overview` returns 401.
- `railway logs --service runout` shows `Supervisor(async)` and no errors.
- Sign in with Last.fm in the browser. Sign out and in again.

**4. Configure the production Spotify callback**
- In Spotify's developer dashboard, add `<ORIGIN>/api/auth/spotify/callback`. Keep the local one.

**5. Connect Spotify**
- Settings → Listening sources → connect. It stores tokens and records no plays.
- Read-only check: `railway ssh --service runout -- bin/rails spotify:verify`.
- Wait 10 minutes: Time Machine stays empty and Settings shows no checks.

**6. Verify backups** (§7): one real run reaches the backups repository, a restore passes, and the watchdog's alert arrives.

**7. Stop local Spotify polling** (approval needed)
- Take a local backup into `~/runout-backups/`.
- Pause in local Settings, set `SPOTIFY_INGESTION_ENABLED=false` in `server/.env`, restart local Rails.
- Confirm no new local `listening_polls` rows for 10 minutes. Keep the local app for your archive.

**8. Enable cloud Spotify polling** (approval needed)
```sh
railway variable set --service runout SPOTIFY_INGESTION_ENABLED=true
```
Then record the approval in `CLAUDE.md`, replacing the local-only record.

**9. Verify new plays are recorded exactly once**
- Within 5 minutes Settings shows a successful check. Play a few songs, and they appear after they finish. Spotify omits some (§4), so one missing song isn't a failure.
- `railway connect Postgres`, then each must return 0:
  ```sql
  select count(*) from (select listening_source_id, source_event_id from listening_observations group by 1,2 having count(*)>1) x;
  select count(*) from (select user_id, played_at, seq from scrobbles group by 1,2,3 having count(*)>1) x;
  ```

**10. Monitor and confirm recovery behaviour**
- `railway redeploy --service runout`: polling resumes within 5 minutes, and the step 9 queries still return 0.
- With the Mac asleep overnight, play something on your phone. Confirm it's there in the morning.
- After a day: `railway metrics --service runout --memory --cpu`, and Settings' recent checks.

## 6. The merge: one archive (done 2026-11-04)

**The tools:** `archive:export_spotify`, `archive:merge_spotify` and `script/verify_archive_merge.rb`.

**What's preserved, and how:**

| Requirement | How |
|---|---|
| All Last.fm scrobbles | The merge target is the archive. Verified by fingerprint and row comparison. |
| All cloud Spotify plays | Each goes through `Listening::Recorder`. Each ends up new, linked, already there, or visibly held for you. |
| Several reports of one play | A Spotify report of a Last.fm play is linked: one play, two sources. Unique indexes forbid duplicates. |
| Catalogue and genre metadata | Target rows aren't edited. New name variants match by the usual rules. |
| Matching decisions, audit | Evidence, first-received times, seen counts, later values, polls, gaps and review decisions carry over, with original dates. |
| Integrity guarantees | Same code and database constraints as a live poll. |

**What goes to you, never guessed:**
- A "same play" decision made in the cloud: IDs differ, and the archive holds evidence you didn't see then.
- Reports the archive finds ambiguous: held for review, not counted.
- Catalogue and metadata decisions made in the cloud: carried in the file and listed.
  To keep these few, leave cloud catalogue reviews until after a merge.

**Procedure** (needs your approval when the time comes):
1. Pause cloud polling. Back up the cloud and local databases.
2. Export: `railway ssh --service runout -- bin/rails archive:export_spotify FILE=/tmp/spotify.ndjson`, and copy it out over the same connection.
3. Restore the local backup into a **new** database, `runout_merge`. Never merge into `runout_development`: the task refuses it.
4. Snapshot: `script/verify_archive_merge.rb snapshot <url> > before.json`.
5. Merge: `SPOTIFY_INGESTION_ENABLED=true CONFIRM_DATABASE=runout_merge bin/rails archive:merge_spotify FILE=...`, with `DATABASE_URL` set to `runout_merge`.
6. Verify: `script/verify_archive_merge.rb verify <url> before.json spotify.ndjson`. It must print `VERIFIED`.
7. Merge again, verify again: nothing may change.
8. Check Time Machine and Overview on the copy. Decide separately whether it goes to Railway.

**Moving a merged archive to Railway** (separate approval; Last.fm data leaves the Mac):
- Restore into a **new database** on the existing Postgres service, or a new service, with
  `pg_restore --no-owner --no-privileges --exit-on-error`. Never over the current database.
  The dump can be streamed in over `railway ssh --service Postgres`, which forwards stdin.
- Repeat the verifier against it (over SSH, with a `psql` shim that forwards each query).
- Give production the local encryption keys, so restored tokens decrypt:
  ```sh
  for pair in ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY:primary_key ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY:deterministic_key \
              ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT:key_derivation_salt; do
    bin/rails runner "print ActiveRecord::Encryption.config.${pair#*:}" 2>/dev/null \
      | railway variable set --service runout --skip-deploys "${pair%%:*}" --stdin
  done
  ```
- That replaces the production keys. The restored archive's own Last.fm and Spotify credentials then decrypt, so
  nothing needs reconnecting. Save the old keys first (`ROLLBACK_ACTIVE_RECORD_ENCRYPTION_*`) for the old database.
- Then point `DATABASE_URL` at the new database and redeploy. The start-up release marks it as production and adds
  any new migrations. Also set the backup job's `BACKUP_DATABASE_URL` and **redeploy the backup service**: a cron
  service picks up variable changes only on its next deployment.
- Sessions don't carry: sign in again.

**Rehearsed 2026-11-03** on scratch copies, with the local archive as the target:

| Check | Result |
|---|---|
| 65 new plays from the production test | 65 created |
| Reports of 20 real, isolated Last.fm plays, as Spotify would send them | 20 linked, no new plays |
| Verifier | `VERIFIED`; every existing row in 30 tables unchanged; Last.fm fingerprint unchanged |
| Merged again | 85 already present, nothing changed, `VERIFIED` |
| Deliberate damage: renamed artist, moved Last.fm play, changed genre, deleted observation | All 4 caught |

The verifier shares no code with the merge and doesn't load Rails.

**Done 2026-11-04, 01:46 to 02:03 UTC**, with the owner's written approval of the procedure and of two choices:
a new database `runout` on the existing Postgres service rather than a new service, and the local encryption
keys rather than reconnecting Spotify.

| Step | Result |
|---|---|
| Polling paused and drained | 01:46:05 to 01:58:06 UTC; no poll ran in between, the old database received nothing after |
| Final export from Railway | 102 observations, 258 polls |
| Merge into a fresh restore of the local backup | 53 created, 49 already present (locally polled while both pollers overlapped), 0 linked, 0 held, 0 conflicts |
| Verifier | `VERIFIED` twice; merged again, nothing changed |
| Restore into `runout` | all 38 tables checksum-identical to the merged copy; Last.fm fingerprint unchanged |
| First poll after resume | 02:00:03 UTC, 3 plays, no duplicates; Spotify's window reached back 8 hours, so nothing was lost |
| Verifier against production | 44 of 45; the one difference was the owner's own sign-in at 02:02 UTC |
| Post-migration backup | `backup/20261104T020227Z`, 209,558 plays, decrypted and restored on this Mac |

0 linked is expected: the archive's Last.fm history ends on 2026-10-31 02:40 UTC and Railway's plays start on
2026-11-02. The old database `railway` (102 plays) and the local archive are untouched. The first post-migration
backup run had to be repeated: the backup service's new URL applied only after a redeploy.

**Plays that can't be recovered:** anything older than Spotify's last 50 when polling starts, or lost during an
outage long enough for 50 newer plays to push it out. Those periods show as gaps, never as made-up plays.

## 7. Backups

Railway's own backups need a Pro workspace, so this is the only layer on Hobby. No public database port
and no Railway SSH key is involved.

**The job:** a Railway Cron service, `backup`, built from `deploy/backup/`. Daily at 10:00 UTC, it exits when
finished, and can't run longer than 30 minutes. Each run, over the private network:
1. Opens one read-only snapshot as `runout_backup` (`pg_read_all_data`; it can't write).
2. Dumps at that snapshot with PostgreSQL 18 tools.
3. Restores into a disposable PostgreSQL server **inside the job's container**, never on the production
   server. Compares the schema, every table's row count and the Last.fm fingerprint against the same
   snapshot, and runs `pg_amcheck`. Plays arriving meanwhile can't cause a false difference.
4. Encrypts to your certificate. The private key isn't on Railway or GitHub.
5. Pushes only ciphertext to a private backups repository (`BACKUP_REPO`), as one branch per backup,
   with a deploy key that can reach only that repository. Clones it back to confirm the checksum.
6. Applies retention, only after that succeeds.

If any step fails, nothing further is kept. Tool errors aren't logged, because they can quote rows: a
failure logs the step name only. `deploy/backup/test.sh` runs all of this in CI, including every failure.

**Schema gotcha:** a check constraint written `column IN ('a', 'b')` on a string column is deparsed
differently after `pg_restore`, so the job's schema comparison fails on the first backup after such a
migration (it did on 2026-11-04 for `loved_tracks`). Write `column::text IN ('a', 'b')` instead; that form
survives a restore unchanged.

**Retention:** the newest 30 backups, plus the newest of each older month for 12 months.

**Why a repository for now:** it's free, already private, and needs no new account or paid service. Deleted
branches free space only when GitHub cleans up, and a file can't exceed 100 MB (the job refuses at 95 MB).
Each backup of the full archive is about 11 MB, so 42 backups are about 460 MB, near GitHub's suggested 1 GB. **If it outgrows that,** move to object storage such as Cloudflare
R2, at about $0.015 per GB a month with a free allowance: check current prices, and it needs a new account.
The deploy key could also delete backups if it leaked, while object storage can make them immutable.

**Alerts:** a watchdog workflow in the backups repository checks at 12:17 and 20:17 UTC that the newest
backup is under 26 hours old. Failing emails you through GitHub's normal Actions notifications. One check
covers a failed run, a missed run and a stopped schedule. A failed run alerts the same day, within about 2 hours.
To test: `gh workflow run watchdog.yml -R <owner>/<backups repository> -f max_age_hours=0`.

**Another project can reuse the job** from a pinned branch (`backups/<project>`) rather than `main`, so a
change to `deploy/backup/` on `main` reaches Runout's job only, until that branch is moved on purpose after
CI's backup test passes. Each project has its own read-only role, destination repository, key and watchdog.

**Your private key** lives on your own machine, never on Railway or GitHub. **Keep it in your password
manager.** Without it no backup can be read. Keep the app's `ACTIVE_RECORD_ENCRYPTION_*` values there too:
without them a restored database can't decrypt tokens, though you could sign in and connect Spotify again.

**Restore drill** (every 3 months; PostgreSQL 18 tools needed, so a throwaway Railway database or a CI job is
the easy way, since this Mac has 17):
```sh
git clone --depth 1 --branch backup/<stamp> git@github.com:<owner>/<backups repository>.git drill
openssl cms -decrypt -binary -inform DER -inkey runout-backup.key -in drill/db.dump.cms -out db.dump
openssl dgst -sha256 db.dump      # must match dump_sha256 in drill/manifest.txt
createdb runout_restore_drill && pg_restore --no-owner --no-privileges --exit-on-error -d runout_restore_drill db.dump
```
Compare with `rows=` in the manifest, then drop only `runout_restore_drill`.

**Restoring production** replaces data, so it's always your decision: add a new Postgres service, restore
into it, compare, then point `DATABASE_URL` at it. Keep the old service until you've checked the new one.

**Your local archive and `~/runout-backups/` aren't touched by any of this.**

## 8. Rollback

| Situation | Do this |
|---|---|
| Stop polling now | Pause in Settings, or `SPOTIFY_INGESTION_ENABLED=false` |
| A bad deploy | Dashboard → Deployments → redeploy the previous one. A failed release never takes over, because the health check doesn't pass. |
| A bad migration | Fix forward, as `CLAUDE.md` says. Restore a backup only with your approval. |
| Undo the archive move | Export the new plays first (`archive:export_spotify` on `runout`). Set `DATABASE_URL` back to `/railway`, restore the three keys from `ROLLBACK_ACTIVE_RECORD_ENCRYPTION_*`, redeploy. Then merge the export where it belongs. |
| Abandon the cloud | Set the flag off, confirm no new cloud polls, set the local flag on, Resume, restart. Local catches up on the last 50 plays. Merge cloud-only plays by §6 before deleting the project. |
| Undo the custom domain | §10 "Rollback": point `APP_ORIGIN` and `SPOTIFY_REDIRECT_URI` back at the Railway address, one redeploy. |
| Locked out of Runout's own sign-in (no passkey, no recovery code) | The operator link, from `server/`: `railway ssh --service runout -- bin/rails 'auth:recovery_link[<user UUID>,<display name>]'`. It prints a link valid 15 minutes, single use, and logs that it was issued; the route answers 404 while `RUNOUT_PASSKEYS_ENABLED` is off. Open it, enrol a passkey, regenerate the recovery codes. No request can issue one. |
| See what a person sees (troubleshooting their account) | The same operator link, for their account: `railway ssh --service runout -- bin/rails 'auth:recovery_link[<user UUID>,<display name>]'` (ids and names: `bin/rails features:list` shows accounts with features; otherwise the console). Open it in a private window, so your own session stays in your browser; it signs that window in as the person for the normal session length. The display name must be their current one (people can change it in Settings → Account). The sign-in is logged, and the person sees it under Settings → Account → Sessions, where they can end it; end it yourself there when you are done. Their memories and listening are private data: look only for what the troubleshooting needs. |
| Switch Runout's own sign-in off | `RUNOUT_PASSKEYS_ENABLED=false` (or delete the variable): the passkey, recovery, link and session routes answer 404; Last.fm sign-in and every session are unaffected. The tables stay; their one migration is reversible on a disposable database. |

Cutover never writes to the local database, so it's always there to return to.

## 9. Cost and open items

**Rates** (`railway.com/pricing`): $10 per GB of RAM a month, $20 per vCPU a month, $0.15 per GB of
volume a month. Hobby is $5 including $5 of usage, and you pay the larger of $5 or your usage.

**Runout, estimated** (from CI's container and a similar Rails deployment on Railway):

| Service | RAM | CPU | Monthly |
|---|---:|---:|---:|
| `runout` (137 MB in CI's container; a similar deployment runs at 189 MB) | 140 to 220 MB | 0.002 to 0.005 vCPU | $1.45 to $2.30 |
| `Postgres`, small while Spotify-only (65 MB for a similar database) | 60 to 100 MB | about 0.001 vCPU | $0.65 to $1.05 |
| Volume, plus Railway backups | | | under $0.10 |
| **Total** | | | **about $2.20 to $3.45** |

**The bill** is the larger of Hobby's $5 and the usage above, shared with anything else in the workspace.

## 10. Custom domain: runout.idlewinny.com

Passkeys (`docs/milestone-5-plan.md` §2) are bound to the site's hostname, so Runout moves to
**runout.idlewinny.com** before the first passkey exists. The Railway address keeps working
throughout and is not redirected until the owner approves that separately.

**Done 2026-11-04.** Runout runs at <https://runout.idlewinny.com> since 22:56 UTC. Each step below
was approved separately and verified as written: code merged and deployed 22:19 (PR #13); domain
added and `APP_ORIGINS` set 22:25; Namecheap CNAME `runout` → `h7iz1z3j.up.railway.app` and TXT
`_railway-verify.runout` entered by the owner; Railway verified the domain and issued the Let's
Encrypt certificate (valid to 2027-02-02) by 22:40; the three variables switched 22:56 (one redeploy).
After each redeploy `/up` answered 200 on both hostnames, the scheduled Spotify poll ran `ok` on the
new container, and the row counts (209,605 scrobbles, 859 loved, 2 sessions) were unchanged. The
owner signed in on the new domain and confirmed Overview, Time Machine and Loved Songs.

**Now:** `APP_ORIGIN=https://runout.idlewinny.com`, `APP_ORIGINS=https://runout-production.up.railway.app`,
`SPOTIFY_REDIRECT_URI=https://runout.idlewinny.com/api/auth/spotify/callback`. The Railway address stays
as the fallback: it answers with its own session, and sign-in started there moves to the domain. It is
not redirected; removing it from `APP_ORIGINS`, redirecting it, or dropping the old Spotify redirect
URI each need the owner's approval.

### How the app handles hostnames

- `APP_ORIGIN` is the canonical origin: the Last.fm callback, the Spotify Settings redirect and the
  host authorization list come from it. Unchanged.
- `APP_ORIGINS` (optional, comma-separated) adds other hostnames the app answers on while the domain
  changes; `Runout::Origins` in `config/application.rb` always keeps the canonical one in the list.
  Unset, nothing differs from before.
- Writes stay strictly same-origin per request: the `Origin` header must equal the origin the
  request arrived on, and that origin must be configured. The other configured hostname is refused
  like any foreign site (`RequestForgeryProtection`, `test/integration/origins_test.rb`, the smoke
  test's `old.runout.test` checks).
- Cookies are per host (`__Host-` in production): a session exists on one hostname only, so you sign
  in once on the new domain and the old one's session goes on working until it expires or you sign
  out there. No session rows change.
- Last.fm sign-in started on a non-canonical hostname redirects to the canonical `/api/auth/lastfm`
  before any state cookie is written, so start and callback share a host. Spotify's begin and
  callback already run on the redirect URI's origin and return to Settings on the canonical origin.
- DNS for idlewinny.com is Namecheap BasicDNS. The apex and `www` point at Vercel; only the new
  `runout` records are added. Last.fm's web auth takes the callback per request (`cb`), so nothing
  changes on Last.fm's side. Spotify checks the redirect URI against the app's allowlist, so the new
  one is added in the developer dashboard first; polling is unaffected either way, because token
  refresh never sends a redirect URI.

### Procedure

1. **Deploy the code** (PR #13). No behaviour change while `APP_ORIGINS` is unset.
2. **Add the domain and the second origin** (from `server/`):
   ```sh
   railway domain runout.idlewinny.com --service runout      # prints the CNAME and TXT to create
   railway variable set --service runout APP_ORIGINS=https://runout.idlewinny.com   # redeploys
   railway domain list --service runout                     # both domains listed
   ```
3. **Owner, in Namecheap** (Domain List → idlewinny.com → Advanced DNS → Add New Record): the CNAME
   with host `runout` and the target Railway printed, and the TXT exactly as printed. Both are
   required; without the TXT Railway answers 404. Leave `@` and `www` alone.
   **Owner, in the Spotify dashboard** (the Runout app → Settings → Redirect URIs): add
   `https://runout.idlewinny.com/api/auth/spotify/callback`, keep the existing ones.
4. **Verify the new hostname** (certificate within about an hour of the records resolving):
   ```sh
   dig +short CNAME runout.idlewinny.com
   railway domain status runout.idlewinny.com --service runout
   curl -s -o /dev/null -w '%{http_code}\n' https://runout.idlewinny.com/up          # 200
   curl -s https://runout.idlewinny.com/api/connection                             # {"status":"none"}
   curl -s -o /dev/null -w '%{http_code}\n' https://runout-production.up.railway.app/up   # still 200
   ```
   Open https://runout.idlewinny.com in a browser: the app loads, signed out.
5. **Make it canonical:**
   ```sh
   railway variable set --service runout APP_ORIGIN=https://runout.idlewinny.com \
     APP_ORIGINS=https://runout-production.up.railway.app \
     SPOTIFY_REDIRECT_URI=https://runout.idlewinny.com/api/auth/spotify/callback
   ```
   Then: sign in with Last.fm on the new domain and sign out and in again; the Railway address
   still shows the library with its own session; `/api/auth/lastfm` on the Railway address answers
   302 to the new domain; Settings → connect Spotify reaches Spotify's consent page with the new
   `redirect_uri` (cancel there, the account is already connected); Overview, Loved, Search and
   Time Machine load; `listening_polls` keeps gaining rows every 5 minutes.
6. Later, each with its own approval: redirect the Railway address to the domain; passkeys (`rp_id`
   = `runout.idlewinny.com`).

### Rollback

Validated by the tests above and by the fact that the switch is variables only; production is not
flipped back and forth to demonstrate it.

| Situation | Do this |
|---|---|
| The new domain misbehaves after step 5 | `railway variable set --service runout APP_ORIGIN=https://runout-production.up.railway.app SPOTIFY_REDIRECT_URI=https://runout-production.up.railway.app/api/auth/spotify/callback` (one redeploy, about 2 minutes). Keep `APP_ORIGINS` so the domain still answers. Sessions and polling are untouched. |
| Drop the domain entirely | After the above: `railway domain delete runout.idlewinny.com --service runout`, `railway variable delete APP_ORIGINS --service runout`, remove the two Namecheap records and the Spotify redirect URI. |
| Undo the code | Reverting the PR restores single-origin behaviour; with `APP_ORIGINS` unset the code already behaves that way, so a revert is not needed for a rollback. |

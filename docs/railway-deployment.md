# Deploying Runout to Railway

Status: **prepared, not deployed** (2026-11-03). No Railway project exists for Runout, no data has
left this Mac, and production Spotify polling is off. Chosen path: **Spotify-first**. Enabling cloud
polling, and later copying the Last.fm archive, each need the owner's approval (`CLAUDE.md`).

## 1. What runs

One Railway project, separate from NoRentGrets, with two services:

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
  NoRentGrets runs the same setup on Railway at 189 MB. Expect 140 to 220 MB. Check
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

**Where the data sits doesn't change items 1, 2, 3 or 6.** They apply to the archive on this Mac
today. Cloud hosting adds items 4 and 5.

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

The Last.fm archive stays on this Mac. The cloud app shows plays from cutover, plus Spotify's last 50,
and Time Machine shows only those until a merge. Your older history stays in the local app.

The alternative, copying the archive first, stays available (§6) but needs your approval and carries
the added licence questions in §3.

## 5. Go-live checklist

Each step is safe to stop after. Steps 7 and 8 need your explicit approval at the time.

**Before starting:** merge `railway-deployment` to `main` and confirm CI's `image` job passes.

**1. Create the Runout Railway project** (from `server/`; a project of its own, separate from NoRentGrets)
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

**6. Verify backups** (§7): turn on Railway's and the daily job, run it once, and test a restore.

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
- Within 5 minutes Settings shows a successful check. Play a song, and it appears after it finishes.
- `railway connect Postgres`, then each must return 0:
  ```sql
  select count(*) from (select listening_source_id, source_event_id from listening_observations group by 1,2 having count(*)>1) x;
  select count(*) from (select user_id, played_at, seq from scrobbles group by 1,2,3 having count(*)>1) x;
  ```

**10. Monitor and confirm recovery behaviour**
- `railway redeploy --service runout`: polling resumes within 5 minutes, and the step 9 queries still return 0.
- With the Mac asleep overnight, play something on your phone. Confirm it's there in the morning.
- After a day: `railway metrics --service runout --memory --cpu`, and Settings' recent checks.

## 6. The future merge: one archive

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
- Restore into a **new** Railway Postgres service, with `pg_restore --no-owner --no-privileges --exit-on-error`.
- Repeat the verifier against it.
- Give production the local encryption keys, so restored tokens decrypt:
  ```sh
  for pair in ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY:primary_key ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY:deterministic_key \
              ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT:key_derivation_salt; do
    bin/rails runner "print ActiveRecord::Encryption.config.${pair#*:}" 2>/dev/null \
      | railway variable set --service runout --skip-deploys "${pair%%:*}" --stdin
  done
  ```
- That replaces the production keys, so anything encrypted with the old ones needs reconnecting: sign in and connect Spotify again.
- Then point `DATABASE_URL` at the new service. The start-up release marks it as production and adds any new migrations.

**Rehearsed 2026-11-03** on scratch copies, with the local archive as the target:

| Check | Result |
|---|---|
| 65 new plays from the production test | 65 created |
| Reports of 20 real, isolated Last.fm plays, as Spotify would send them | 20 linked, no new plays |
| Verifier | `VERIFIED`; every existing row in 30 tables unchanged; Last.fm fingerprint unchanged |
| Merged again | 85 already present, nothing changed, `VERIFIED` |
| Deliberate damage: renamed artist, moved Last.fm play, changed genre, deleted observation | All 4 caught |

The verifier shares no code with the merge and doesn't load Rails.

**Plays that can't be recovered:** anything older than Spotify's last 50 when polling starts, or lost during an
outage long enough for 50 newer plays to push it out. Those periods show as gaps, never as made-up plays.

## 7. Backups

| Layer | Schedule and retention | Needs |
|---|---|---|
| Railway volume backups | Daily (6 days) and weekly (27 days). Set in Postgres → Backups. | Check the tab offers them on Hobby: Railway's docs don't say. Restores only in the same project, and wiping the volume deletes them. |
| **Daily portable export** | GitHub Actions, 10:17 UTC. Kept 30 days; the first of each month kept 90. No laptop needed. | A read-only database role, a certificate, three settings. Free within a private repo's quotas: about 60 of 2,000 minutes a month. |
| By hand | `bin/backup-railway` from the Mac, into `~/runout-backups/railway/`. Optional extra. | |

**What each daily run does** (`.github/workflows/backup.yml`):
1. Dumps through a read-only role.
2. Restores into a disposable database. Compares play counts, users and the Last.fm fingerprint.
3. Encrypts to your certificate. Only ciphertext is stored; GitHub can't read it.
4. Fails loudly: GitHub emails you on a failed scheduled run.

**To turn it on** (your authorization needed; this creates the credentials):
```sh
# Keep runout-backup.key in your password manager, and off this repository.
openssl req -x509 -newkey rsa:4096 -nodes -keyout runout-backup.key -out runout-backup.crt -days 3650 -subj /CN=runout-backup
gh secret set RUNOUT_BACKUP_PUBLIC_CERT < runout-backup.crt
# In railway connect Postgres, with a generated password:
#   create role runout_backup login password '...'; grant pg_read_all_data to runout_backup;
# Then build its URL from DATABASE_PUBLIC_URL's host and port, and enter it at the prompt:
gh secret set RUNOUT_BACKUP_URL
gh variable set RUNOUT_PG_MAJOR --body <major version from "show server_version">
gh variable set RUNOUT_BACKUP_ENABLED --body true
gh workflow run backup.yml
```
- The role can't change data: writing as a read-only role was refused in testing.
- It needs Railway's public TCP proxy on Postgres, protected by that password.

**Restore drill** (at setup, then every 3 months):
```sh
gh run download <run id> --dir ./restore-check
openssl cms -decrypt -binary -inform DER -inkey runout-backup.key -in ./restore-check/*/FILE.dump.cms -out FILE.dump
shasum -a 256 -c ./restore-check/*/FILE.dump.sha256     # run where FILE.dump is
createdb runout_restore_drill && pg_restore --no-owner --exit-on-error -d runout_restore_drill FILE.dump
```
- Compare counts with production, then drop only `runout_restore_drill`.
- Railway's current template is PostgreSQL 18, and this Mac's tools are 17. An 18 dump needs 18 tools. Installing them changes local PostgreSQL tooling, so it needs your OK.

**If runs stop silently:** GitHub emails on failure, not if the schedule itself stops. A free uptime check can cover
that: set `RUNOUT_BACKUP_HEARTBEAT_URL`, for example from Healthchecks.io. Optional, and it needs an account you create.

**Restoring production** replaces data, so it's always your decision: add a new Postgres service, restore
into it, compare, then point `DATABASE_URL` at it. Keep the old service until you've checked the new one.

**Your local archive and `~/runout-backups/` aren't touched by any of this.**

## 8. Rollback

| Situation | Do this |
|---|---|
| Stop polling now | Pause in Settings, or `SPOTIFY_INGESTION_ENABLED=false` |
| A bad deploy | Dashboard → Deployments → redeploy the previous one. A failed release never takes over, because the health check doesn't pass. |
| A bad migration | Fix forward, as `CLAUDE.md` says. Restore a backup only with your approval. |
| Abandon the cloud | Set the flag off, confirm no new cloud polls, set the local flag on, Resume, restart. Local catches up on the last 50 plays. Merge cloud-only plays by §6 before deleting the project. |

Cutover never writes to the local database, so it's always there to return to.

## 9. Cost and open items

**Rates** (`railway.com/pricing`): $10 per GB of RAM a month, $20 per vCPU a month, $0.15 per GB of
volume a month. Hobby is $5 including $5 of usage, and you pay the larger of $5 or your usage.

**NoRentGrets now** (`dazzling-quietude`, measured over the 23 hours after its Nov 2 cleanup):

| Service | RAM | CPU | Volume | Monthly |
|---|---:|---:|---:|---:|
| production `norentgrets` (Puma with async Solid Queue) | 189 MB | 0.0015 vCPU | | $1.88 |
| production `Postgres-6L4m` | 65 MB | 0.0008 vCPU | 136 MB | $0.67 |
| staging `Postgres` | 56 MB | 0.0002 vCPU | 137 MB | $0.58 |
| **Total** | | | | **about $3.13** |

**Runout, estimated separately:**

| Service | RAM | CPU | Monthly |
|---|---:|---:|---:|
| `runout` (137 MB in CI's container; NoRentGrets' same setup runs at 189 MB) | 140 to 220 MB | 0.002 to 0.005 vCPU | $1.45 to $2.30 |
| `Postgres`, small while Spotify-only (65 MB for NoRentGrets' similar size) | 60 to 100 MB | about 0.001 vCPU | $0.65 to $1.05 |
| Volume, plus Railway backups | | | under $0.10 |
| **Total** | | | **about $2.20 to $3.45** |

**Your bill:** usage of about $5.35 to $6.60 a month, so **about $5.50 to $7**, up from $5 today: **$0.50 to $2 more**,
because NoRentGrets leaves about $1.87 of the included $5 unused. Egress is about $0.01.

**This period** (to Nov 18) is higher: $6.42 is already used, mostly before the Nov 2 cleanup. Railway's $11.98
estimate projects that earlier spending forward, so it overstates things.

**Not verified: these need a real deploy**
- Railway's private network, proxy and health check. (The image, PostgreSQL 18 and Linux memory were
  covered by CI; Docker itself can't start on this Mac, because Homebrew's Lima runs under Rosetta.)
- On teardown Puma exits 1, not 143, because PID 1 can't re-raise SIGTERM to itself; it still stops
  gracefully within the draining time. Railway ignores exit codes on a deliberate stop.
- Real Spotify and Last.fm sign-in in production (steps 3 and 5).
- The `railway` commands in §5 and §6: flags checked against CLI help, none run. `backup.yml`: parsed, never run;
  its script and encryption were tested separately.
- Rate limits behind Railway's proxy: if it isn't a trusted proxy to Rails, limits count all visitors as one.
  Harmless for one person.
- `/up` doesn't detect a stalled in-process Solid Queue. Settings shows the last successful check.

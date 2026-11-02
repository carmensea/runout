# Deploying Runout to Railway

Status: **prepared, not deployed** (2026-11-02). No Railway project exists for Runout, no data has
left this Mac, and production Spotify polling is off. Going live needs the owner's approval, and
copying the Last.fm archive needs separate approval (`CLAUDE.md`).

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
- **These are Rosetta and macOS figures: trust the ratios, not the absolutes.** Docker can't run on
  this Mac (§9). Expect 200 to 300 MB on Railway, going by NoRentGrets' 203 MB web service, and
  check `railway metrics` after deploying.
- **The trade-off:** Solid Queue's README recommends fork mode, because a job shares memory and the
  Ruby lock with web requests. A job here is one short HTTP call every 5 minutes, and web traffic is
  one person.

## 2. What was tested

Run in a production-mode scratch copy against disposable databases, with a local fake of Spotify
and Last.fm reached over real TLS. No real account or provider was contacted.

| Area | Result |
|---|---|
| Frontend | Shell served at `/` and deep links, uncached and `noindex`; digested assets cached a year; unknown `/api` paths and missing assets are real 404s |
| Hosts and HTTPS | Other `Host` headers get 403; `/up` answers any host; HSTS on; cookies `Secure` |
| Sign-in | Another Last.fm account refused and no user created; the allowed one signs in; `__Host-` cookie, `HttpOnly`, `SameSite=Lax` |
| Private data | Overview, Search, Plays, Calendar and Listening sources all return 401 without a session |
| CSRF | POST refused with no `Origin`, a wrong `Origin`, or no `X-Requested-With` |
| Spotify OAuth | Full flow with an `https://` callback; forged state refused; tokens and the Last.fm key encrypted at rest |
| Polling | Recurring tick to stored plays through the real job chain; resumed after SIGTERM, after SIGKILL and after all database connections were dropped |
| Deduplication | Across all of that: 62 observations, 62 plays, 62 reported events, no duplicates, no gaps; every play linked to its observation |
| Last.fm | Only the 4 sign-in calls; recurring jobs made none with storage off |
| Release | Creates both databases, loads schemas, seeds genres; safe to repeat; refuses tables without `schema_migrations` |
| Archive copy | Release left the Last.fm fingerprint and counts unchanged; credentials decrypt with the copied keys; Overview, Search, Calendar, Plays and On this day return 200 |
| Backup | Dump restored into a disposable database, counts and fingerprint compared, checksum valid; a bad source fails without keeping a file |

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

## 4. Choosing a path

**Recommendation: B, Spotify-first.** It meets the goal, moves no Last.fm history, needs no answer
from Last.fm, costs least and is easy to undo. Path A stays open later.

| | A: full archive | B: Spotify-first |
|---|---|---|
| Last.fm history in the cloud | Yes: needs your approval | No |
| Licensing exposure added | Items 4 and 5 above | Sign-in only (username, session key) |
| Cloud app shows | Everything | Plays from cutover, plus Spotify's last 50 |
| Old history visible at | The cloud app | The local app, as now |
| Extra steps | Restore, copy encryption keys | None |
| Undo | Delete the Railway copy; backups may need deleting too | Delete the project |

### Path B: later reconciliation

Spotify plays are identified by the exact `played_at` in milliseconds, per account, with a unique
index. The same play always gets the same identity, in any database.

To merge later, with your approval:
1. Pause cloud polling and take a backup.
2. Export the cloud observations: raw timestamp, names, provider IDs, ISRC and context.
3. Replay them through `Listening::Recorder` into **a copy** of the local archive. It decides each
   one: already seen, linked to a matching play, held for review, or new.
4. Compare counts and the Last.fm fingerprint. Then use the merged copy, by Path A if that's approved.

**Rehearsed on scratch copies of the real archive:**

| Replay | Outcome | Last.fm / Spotify plays |
|---|---|---|
| The archive's own 85 Spotify plays again (overlap) | 85 seen | 209,383 / 85 |
| 62 new "cloud" plays | 62 created | 209,383 / 147 |
| The same 62 again | 62 seen | 209,383 / 147 |

The Last.fm fingerprint didn't change. **Limits:**
- The export and replay ran from throwaway scripts, not a committed task. Allow about an hour to make
  them permanent when needed.
- Review decisions made in the cloud don't carry over, so leave reviews until after a merge.
- First-received times and seen counts restart in the merged copy.
- Plays older than Spotify's last 50 when polling starts can't be recovered.

**One poller only:** two databases can't lock each other, so §5's cutover is the guard. Stop local
polling and confirm it stopped before enabling cloud polling.

## 5. Go-live steps

Each step that sends data or starts polling is marked. Ask before running those.

**Prepare (about 30 minutes)**

1. Merge this branch and confirm CI's `image` job passes. That is the first real image build.
2. Create the project and services, from `server/`:
   ```sh
   railway init --name runout
   railway add --database postgres
   railway add --service runout --repo carmensea/runout --branch main
   railway domain --service runout   # note the https address
   ```
3. Check the Postgres version: `railway connect Postgres`, then `show server_version;`. The local
   tools are version 17 and can't dump a newer server (§7).
4. Set variables, without printing secrets:
   ```sh
   R="railway variable set --service runout --skip-deploys"
   ORIGIN=https://<the address from step 2>
   $R APP_ORIGIN=$ORIGIN SPOTIFY_REDIRECT_URI=$ORIGIN/api/auth/spotify/callback \
      'DATABASE_URL=${{Postgres.DATABASE_URL}}' SPOTIFY_INGESTION_ENABLED=false \
      RAILWAY_DEPLOYMENT_DRAINING_SECONDS=30 RAILWAY_DEPLOYMENT_OVERLAP_SECONDS=0
   for k in SECRET_KEY_BASE ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY \
            ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT; do
     openssl rand -hex 32 | tr -d '\n' | $R "$k" --stdin
   done
   set -a; . ./.env; set +a
   for k in LASTFM_API_KEY LASTFM_SHARED_SECRET LASTFM_ALLOWED_USERNAME SPOTIFY_CLIENT_ID SPOTIFY_CLIENT_SECRET; do
     printenv "$k" | tr -d '\n' | $R "$k" --stdin
   done
   ```
   Keep a copy of the encryption keys in your password manager: backups can't decrypt tokens without
   them, though you could reconnect instead.
5. In the dashboard: `runout` → Settings → Healthcheck Path = `/up`. Also set a usage limit, if you
   want one, under workspace settings.
6. In Spotify's developer dashboard, add `<ORIGIN>/api/auth/spotify/callback` as a redirect URI. Keep
   the local one.

**Deploy with polling off**

7. Deploy (`railway redeploy --service runout`, or a push to `main`). The container prepares the
   databases, then starts Puma. Check `railway logs --service runout` and `curl $ORIGIN/up`.
8. Open the address: expect the signed-out app. Check private data is closed: `curl -i
   $ORIGIN/api/overview` must return 401.
9. Sign in with Last.fm, then Settings → Listening sources → connect Spotify. **This is the real
   OAuth test.** It reads your account and stores tokens; it records no plays.
10. Read-only check: `railway ssh --service runout -- bin/rails spotify:verify`.
11. Run a first backup (§7), and restore-test it before going further.

**Path A only, with separate approval, before step 7:** see §6.

**Cut over: needs your approval**

12. Stop local polling: Pause in local Settings, set `SPOTIFY_INGESTION_ENABLED=false` in
    `server/.env`, and restart local Rails. Keep the local app for your archive.
13. Confirm it stopped: no new `listening_polls` rows locally for 10 minutes.
14. Take a local backup: `pg_dump -Fc runout_development` into `~/runout-backups/`, as usual.
15. **Start cloud polling:** `railway variable set --service runout SPOTIFY_INGESTION_ENABLED=true`.
    This redeploys.
16. Confirm: within about 5 minutes Settings shows a successful check, and Time Machine shows today's
    plays.
17. Watch for a day: `railway metrics --service runout --memory --cpu` and Settings' recent checks.
    Then install the daily backup (§7) and update `CLAUDE.md`'s approval record.

## 6. Path A: full archive (separate approval only)

Run after step 6 and **before the first deploy**, so the release finds a complete database. A partial
restore makes the release stop rather than load a schema over it.

1. Stop local polling (steps 12 and 13) so the copy is final and two pollers never hold one token.
2. Dump, and record the fingerprint:
   ```sh
   PG=~/.local/postgresql-17/bin
   $PG/pg_dump -h localhost -U postgres -Fc --no-owner --no-privileges -f ~/runout-backups/before-railway.dump runout_development
   ```
3. Restore into the empty Railway database through its public proxy:
   ```sh
   URL=$(railway variable list --service Postgres --kv | sed -n 's/^DATABASE_PUBLIC_URL=//p')
   $PG/pg_restore --no-owner --no-privileges --exit-on-error -d "$URL" ~/runout-backups/before-railway.dump
   ```
4. Compare with the local database: the same fingerprint query as `bin/backup-railway`, plus counts of
   artists, genres, tags, reviews and observations.
5. Give production the keys that encrypted these rows. Do this instead of the random keys in step 4:
   ```sh
   for pair in ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY:primary_key \
               ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY:deterministic_key \
               ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT:key_derivation_salt; do
     bin/rails runner "print ActiveRecord::Encryption.config.${pair#*:}" 2>/dev/null \
       | railway variable set --service runout --skip-deploys "${pair%%:*}" --stdin
   done
   ```
6. Continue from step 7. Keep `LASTFM_HISTORY_STORAGE_ENABLED` unset: no import or sync restarts.

## 7. Backups

| Layer | What | Limit |
|---|---|---|
| Railway | Postgres service → Backups: daily (kept 6 days) and weekly (kept 27 days) | Restores only into the same project and environment. Wiping the volume deletes them. Docs don't say whether Hobby includes this: check the tab. |
| **Off-platform** | `bin/backup-railway`: daily dump to `~/runout-backups/railway/` | Reads through Postgres' public TCP proxy. The Mac must wake to run it, but scrobbling doesn't depend on it. |

`bin/backup-railway` proves each dump restores into a disposable local `runout_restore_check`
database, compares counts and fingerprint, checksums it, keeps the newest 30, and shows a macOS
notification on failure. It doesn't touch `~/runout-backups/*` outside that folder, or
`runout_development`.

**A newer server:** if step 3 shows a version above 17, install matching client tools and set
`RUNOUT_PG_BIN`. Ask first: `CLAUDE.md` restricts local PostgreSQL changes.

**Daily schedule** (`~/Library/LaunchAgents/com.runout.backup.plist`; launchd runs a missed job at the
next wake):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.runout.backup</string>
  <key>WorkingDirectory</key><string>/Users/carmen/projects/runout/server</string>
  <key>ProgramArguments</key><array><string>bin/backup-railway</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/local/bin:/usr/bin:/bin</string></dict>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>0</integer></dict>
  <key>StandardOutPath</key><string>/Users/carmen/runout-backups/railway/backup.log</string>
  <key>StandardErrorPath</key><string>/Users/carmen/runout-backups/railway/backup.log</string>
</dict></plist>
```
Load it with `launchctl load ~/Library/LaunchAgents/com.runout.backup.plist`. The local Postgres must
be running for the restore check; it doesn't start by itself after a reboot.

**Restoring into Railway** (replaces data, so it's always your decision): add a new Postgres service,
`pg_restore` into it as in §6, compare, then point `DATABASE_URL` at it. The old service stays until
you've checked the new one.

## 8. Rollback

| Situation | Do this |
|---|---|
| Stop polling now | Pause in Settings, or `SPOTIFY_INGESTION_ENABLED=false` |
| A bad deploy | Dashboard → Deployments → redeploy the previous one. A failed release never takes over, because the health check doesn't pass. |
| A bad migration | Fix forward, as `CLAUDE.md` says. Restore a backup only with your approval. |
| Abandon the cloud | Set the flag off, confirm no new cloud polls, then set the local flag on, Resume and restart. Local catches up on the last 50 plays. Merge cloud-only plays by §4 before deleting the project. |

The local database is never written during cutover, so it's always there to return to.

## 9. Cost and open items

**Rates** (`railway.com/pricing`, 2026-11-02): $10 per GB of RAM a month, $20 per vCPU a month, $0.15
per GB of volume a month. Hobby is $5 including $5 of usage.

**The included $5 is already used.** `railway usage` shows $6.42 so far this period and an estimated
$12.02 bill, all from NoRentGrets, so Runout's usage is all extra.

| Added monthly | Path B | Path A |
|---|---:|---:|
| `runout` at 200 to 300 MB | $2.00 to $3.00 | $2.00 to $3.00 |
| Postgres at 60 to 100 MB (A: 100 to 200 MB) | $0.60 to $1.00 | $1.00 to $2.00 |
| CPU, under 0.01 vCPU | up to $0.20 | up to $0.20 |
| Volume and backups | under $0.05 | about $0.10 |
| **Total** | **about $3 to $4.50** | **about $3.50 to $5.50** |

So a bill of about $15 to $18 a month. Memory is estimated from NoRentGrets' measured web and database
services, not from Runout on Railway. A separate worker would add about $1.50 to $2 more.

**Not verified: these need a real deploy or Docker**
- The `Dockerfile` has never been built: Docker can't run on this Mac, because Homebrew's Lima runs
  under Rosetta. CI's `image` job builds and boots it on the first push.
- jemalloc, Linux memory, Railway's private network, its proxy and health check.
- Real Spotify and Last.fm sign-in in production (step 9).
- `railway` commands in §5 and §6: flags checked against CLI help, none run.
- Rate limits behind Railway's proxy: if it isn't a trusted proxy to Rails, limits count all visitors as
  one. Harmless for one person. Check `request.remote_ip` if sign-ins start being limited.
- A stalled in-process Solid Queue isn't detected by `/up`. Settings shows the last successful check.

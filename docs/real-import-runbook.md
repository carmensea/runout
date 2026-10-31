# Runbook: supervised first real import (local)

Status: **prepared, not run.** The first real import of your Last.fm history happens only when you
authorise it. Everything below runs on this Mac against `runout_development`. Whether you may
keep the history under Last.fm's terms is your decision (`docs/lastfm-permission-email.md`); this
runbook is only about doing it safely.

**What to expect** (Stage 2.9, `docs/milestone-2-plan.md` §16):
- about 2,400 Last.fm requests at one per second;
- about 45 minutes to 1¼ hours if Last.fm is healthy;
- about 55 MB of storage.

Each month is committed on its own, so stopping at any point loses nothing already imported.

All commands run in `server/`, with Ruby selected:

```sh
cd server
source /usr/local/share/chruby/chruby.sh && chruby ruby-3.4.7
```

**PostgreSQL tools.** The server is PostgreSQL 17, installed in `~/.local/postgresql-17` and started
by hand (not a launchd service, so it doesn't start by itself after a reboot). The `pg_dump` on
`PATH` is Homebrew's 14, which can't dump a 17 server, so the commands below name the 17 tools:

```sh
PG=~/.local/postgresql-17/bin
```

If the server isn't running (after a reboot, say), start it with:

```sh
$PG/pg_ctl -D ~/.local/var/postgresql-17 -l ~/.local/var/postgresql-17.log \
  -o "-p 5432 -k /tmp -c listen_addresses=localhost" start
```

## Readiness check (2026-10-30)

Run before authorising the import. Synthetic data only; nothing imported, storage left off.

| Check | Result |
|---|---|
| PostgreSQL restart | 17.11 restarted with `pg_ctl restart -m fast` in under a second, then stopped and cold-started with the command above; same options, data intact |
| Correct database | development connects to `runout_development` on 17.11, port 5432, no pending migrations; 1 user, 1 identity, 1 connection, 0 scrobbles |
| Backup and restore | dumped with the 17 tools, restored into a scratch database: 22 tables with identical row counts, same indexes, constraints, extensions and migrations; the app booted on it and decrypted the stored credentials. Scratch copy and dump removed |
| Solid Queue | `runout_development_queue` created and loaded; `bin/jobs` started supervisor, dispatcher, worker and scheduler with the three recurring tasks; a worker killed with SIGKILL was replaced in 2 s and jobs kept running; SIGTERM deregistered everything |
| Recovery under load | the real Solid Queue smoke suite: 145 of 145 checks, covering pause and resume, cancel and restart, workers killed during fetch and commit, graceful restarts, storage switched off mid-import, retries and the watchdog |
| Storage flag | off by default and not in `.env`; with it off, every job and task refuses or does nothing, and writes raise `DisabledError` |
| Monitoring | `import:status`, `sync:status` and `runout:storage_report` run against development |
| Last.fm account | one read-only `user.getInfo`: session valid, same account, registration time matches, username allowed; 209,417 plays since August 2004 |

Your reporting timezone is America/Los_Angeles. Import periods are UTC months, so Settings shows
them as local times ("2014-05-31 17:00 to 2014-06-30 17:00"), and the Overview marks a day only
partly imported with its time.

## 0. One-time preparation

1. **Back up the development database** (the restore command is in step 7):

   ```sh
   $PG/pg_dump -U postgres -Fc -f ~/runout-development-before-import.dump runout_development
   ```

   The file holds your Last.fm credentials (encrypted): keep it private.

2. **Create a separate queue database for Solid Queue.** It never touches `runout_development`.
   (Done on 2026-10-30 during the readiness check; skip it if `runout_development_queue` exists.)

   ```sh
   $PG/createdb -U postgres runout_development_queue
   QUEUE_DATABASE_URL=postgres://postgres@localhost/runout_development_queue \
     bin/rails db:schema:load:queue
   ```

   `db:schema:load:queue` loads only the queue database. Never run plain `db:schema:load` against
   development (CLAUDE.md).

3. **Check the account and that nothing is running:**

   ```sh
   set -a; . ./.env; set +a
   bin/rails import:status
   bin/rails sync:status
   ```

   You should see no active import, 0 imported scrobbles, and storage off.

## 1. Start

Storage is switched on only for the processes started here, through the environment: nothing is
written to `.env`, so closing these terminals switches it off again. Use the same three variables
in every terminal:

```sh
set -a; . ./.env; set +a
export LASTFM_HISTORY_STORAGE_ENABLED=true
export QUEUE_DATABASE_URL=postgres://postgres@localhost/runout_development_queue
```

- **Terminal 1, the job runner** (workers, the watchdog, the recurring sync):

  ```sh
  bin/jobs
  ```

- **Terminal 2, the API**, for the Settings page:

  ```sh
  bin/rails server
  ```

- **Terminal 3, the frontend:** `npm run dev` in the repository root. Then open Settings.

Start the import with **Settings → Start import**, or:

```sh
bin/rails import:start
```

## 2. Monitor

- **Settings → Listening history:**
  - what is happening;
  - scrobbles imported against Last.fm's total, and the current period;
  - periods that are missing or stopped.
- **Command line:**

  ```sh
  bin/rails import:status          # committed scrobbles, percent, periods, current period
  bin/rails sync:status            # per-period status, missing periods, attention
  bin/rails runout:storage_report  # size of everything stored
  ```

- **Terminal 1:** the job log. Requests are paced at one per second; Last.fm errors are retried with
  backoff.

## 3. Stop safely, and resume

- **Pause** (Settings, or `bin/rails import:pause`): the period being fetched finishes and commits,
  then nothing more is fetched. Resume with Settings or `bin/rails import:resume`; the account is
  checked again first.
- **Stop the processes:** pause first, wait until `import:status` shows nothing processing, then
  press Ctrl-C in terminal 1. Solid Queue releases unfinished jobs for the next start. The
  processes can take up to a minute to exit; `ps ax | grep [s]olid-queue` shows any left.
- **A crash, a killed process or a reboot is also safe.**
  - Start `bin/jobs` again with the same environment.
  - The watchdog takes over interrupted periods once their lease expires, and restarts a quiet
    import after 20 minutes.
  - Committed months are never re-imported; an interrupted month is fetched again from scratch.
- **Cancel** (Settings, or `bin/rails import:cancel`): stops for good. Imported scrobbles are kept;
  starting again continues from where it stopped.
- **Switch storage off entirely:** stop all three terminals. Without
  `LASTFM_HISTORY_STORAGE_ENABLED=true` nothing is fetched or written; what was imported stays.

## 4. If something stops

- **Settings → "Periods that are missing or stopped":**
  - "Will try again automatically": wait.
  - "Needs your attention": open Technical details, then Try again, or
    `bin/rails import:retry WINDOW=<id>`.
- **A row Last.fm can't date** is isolated to a period of an hour or two, shown as missing. Never
  guessed.
- **Rate limiting (error 29):** the client cools down and retries by itself.

## 5. Confirm the imported count

1. `bin/rails import:status` should show `complete true`, `coverage :complete`, `percent 100` and
   every window committed (`pending`, `processing`, `failed` and `review` all 0).
2. **Per period, exact:** `committed_scrobbles` should equal `expected_scrobbles`, the sum of
   Last.fm's own total for each imported period. A difference here is a real problem.
3. **Whole account, approximate:** compare `committed_scrobbles` with `reported_playcount`, your
   profile's total when the import started (209,417 on 2026-10-30). Plays after the import's
   `cutoff_at` belong to sync, not to this count. A small difference can be legitimate: Last.fm's
   total may include plays its history doesn't return (assumption A1, unverified). A large one is
   worth a look.
4. **Stored plays:** the daily count check (`CountCheckJob`, 04:15) counts the plays actually stored
   per period. To run it now, keep the same environment and:

   ```sh
   bin/rails runner 'pp HistoryImport::CountCheck.run_all!'
   ```

   Every period should show 0 mismatched.
5. `bin/rails sync:status` should list no stopped or inconsistent periods.
4. Optionally, check every month against Last.fm again (about the same number of requests as the
   import):

   ```sh
   bin/rails import:recheck
   ```

   A clean history changes nothing. Differences go to review (Settings → To review). Nothing is
   removed without your approval.

## 6. Afterwards

- Keep `bin/jobs` running, with the same environment, for ongoing sync: every 30 minutes, plus the
  daily catch-up and the weekly comparison.
- The Overview and Search then show your history.

## 7. Undo (only if you decide to)

Restoring the backup from step 0 brings `runout_development` back to before the import. This
replaces the database's contents, so it is your explicit decision, never automatic:

```sh
pg_restore -U postgres --clean --if-exists -d runout_development ~/runout-development-before-import.dump
```

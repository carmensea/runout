# Runout API (Rails)

Rails 8.1 in API-only mode. Milestone 1: Last.fm sign-in, sessions and connection state.
See `docs/backend-plan.md` for the full plan.

## Requirements

- Ruby 3.4.7 (`server/.ruby-version`)
- PostgreSQL 17, listening on `localhost:5432` with a `postgres` role.
  Override with `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_USERNAME`, `DATABASE_PASSWORD`.

## Set up

```sh
cd server
bundle install
bin/rails db:prepare
bin/rails test
```

## Sign in locally with Last.fm

1. Create a Last.fm API account at https://www.last.fm/api/account/create.
   Set the callback URL to `http://localhost:5173/api/auth/lastfm/callback`.
2. Start the API with your credentials. They stay on the server and are never sent to the browser.

   Put them in `server/.env` (git-ignored), with the account allowed to sign in:

   ```
   LASTFM_API_KEY=...
   LASTFM_SHARED_SECRET=...
   LASTFM_ALLOWED_USERNAME=your-lastfm-username
   ```

   ```sh
   cd server
   set -a; . ./.env; set +a
   bin/rails server -p 3000
   ```

3. In another terminal, start the frontend so it talks to the API through the Vite proxy:

   ```sh
   VITE_RUNOUT_API_URL=/api npm run dev
   ```

4. Open http://localhost:5173 and choose **Connect Last.fm**. Approve Runout on Last.fm; you
   are sent back to the Overview, signed in. Sign out from Settings.

Always use `http://localhost:5173`, not port 3000 directly: the sign-in callback and the
session cookie are tied to that origin (`APP_ORIGIN`).

## Database safety

Never roll back, reset, drop or recreate the development database. Migrate forward only, after
checking `bin/rails db:migrate:status`. Test reversibility only against the test database, one
named version at a time. The full rules are in `CLAUDE.md` at the repo root.

## Relinking after a username change

Last.fm does not expose a stable account ID, so this deployment is locked to one configured
username, and a rename is never detected or merged automatically. After you rename your Last.fm
account, sign-in shows "relink required". To relink:

1. Set `LASTFM_ALLOWED_USERNAME` to the new username and restart the server.
2. Run `bin/rails "lastfm:relink[old_name,new_name]"`. It checks that the new username's
   registration time matches the linked account, then re-points the link. If anything doesn't
   match, it changes nothing.
3. Sign in with Last.fm as the new username. Your Runout user and history are unchanged.

## Last.fm history (Milestone 2)

Storing listening history is off everywhere until Last.fm's storage terms are resolved
(`LASTFM_HISTORY_STORAGE_ENABLED`, see below). Until then, two read-only tools are available:

```sh
bin/rails lastfm:probe          # verifies recent-tracks behaviour against the live API; stores nothing
bin/rails runout:storage_report # on-disk size of all data derived from Last.fm
```

Findings: `docs/lastfm-api-findings.md`.

The import itself (Stage 2.6) is built but refuses to run while storage is off. When it is
allowed, these operator tasks drive it (`USERNAME=` picks the account; default: the single linked
one):

```sh
bin/rails import:start    # plan and start, newest month first; safe to repeat
bin/rails import:status   # progress from committed data only
bin/rails import:pause    # the month in progress finishes, nothing new starts
bin/rails import:resume   # verifies the account again, then continues
bin/rails import:cancel   # stops; committed history is kept
bin/rails import:retry    # retries stopped or reviewed months (WINDOW=id for one)
bin/rails catalogue:match # matches stored names to artists, albums and tracks
```

### Solid Queue smoke test

`bin/rails test` uses Rails' test queue adapter. `test/smoke/solid_queue/run.rb` runs synthetic
imports through real Solid Queue instead: separate supervisor, dispatcher, worker and scheduler
processes, a fake Last.fm installed before they fork, and a disposable database. It covers
crashes, restarts, duplicate delivery, retries, pause and cancel, and the storage flag. It never
touches the development database.

```sh
export RAILS_ENV=test DATABASE_URL="postgres://postgres@localhost/runout_smoke?gssencmode=disable"
bin/rails db:create   # once, then load the schemas into runout_smoke:
bin/rails runner 'load "db/schema.rb"; load "db/queue_schema.rb"'
SMOKE_DIR=$(mktemp -d) LASTFM_HISTORY_STORAGE_ENABLED=true bin/rails runner test/smoke/solid_queue/run.rb
```

It refuses to run against any database other than `runout_smoke`, and while other Solid Queue
processes are running. It truncates that database's tables before every scenario.

## Environment

| Variable | Purpose |
|---|---|
| `LASTFM_API_KEY`, `LASTFM_SHARED_SECRET` | Last.fm API account |
| `LASTFM_ALLOWED_USERNAME` | The one Last.fm account allowed to sign in (case-insensitive). Required: without it, sign-in is refused |
| `APP_ORIGIN` | Browser-facing origin (default `http://localhost:5173`) |
| `ACTIVE_RECORD_ENCRYPTION_*` | Required in production; derived from the local secret in development |
| `DATABASE_URL` | Production (Railway's PostgreSQL). Solid Queue uses a `runout_queue` database on the same server, or `QUEUE_DATABASE_URL` if set |
| `SECRET_KEY_BASE` | Production |
| `SOLID_QUEUE_IN_PUMA` | Production: `async` (the image's default) runs Solid Queue as threads inside Puma; any other value forks its processes |
| `JOB_THREADS` | Solid Queue worker threads (default 2): one import step and one maintenance job at a time |
| `RAILS_MAX_THREADS` | Database connections per pool (default 5). Keep it at least Puma's threads, and at least `JOB_THREADS` + 2 for the queue database |
| `SOLID_QUEUE_SHUTDOWN_TIMEOUT` | Seconds a running job gets to finish on deploy (default 25; keep below `RAILWAY_DEPLOYMENT_DRAINING_SECONDS`, 30 s grace period). Unfinished jobs are released and redelivered |
| `LASTFM_MIN_REQUEST_INTERVAL` | Seconds between Last.fm requests across all processes (default 1.0) |
| `LASTFM_HISTORY_STORAGE_ENABLED` | Off unless exactly `true` or `1`. Gates storing Last.fm listening history; keep off until Last.fm's storage terms are resolved |

In production `APP_ORIGIN` is required at boot (it sets the allowed `Host`), including for build
steps that load the app, such as `bin/rails db:prepare`.

## Endpoints

| Method | Path | Notes |
|---|---|---|
| GET | `/api/auth/lastfm?tz=` | Starts Last.fm web auth |
| GET | `/api/auth/lastfm/callback` | Completes it; redirects to `/overview` or `/overview?auth_error=` |
| GET | `/api/connection` | `ConnectionState` (`none` when signed out) |
| DELETE | `/api/session` | Signs out. Needs a same-origin `Origin` and `X-Requested-With: XMLHttpRequest` |
| DELETE | `/api/account` | Deletes the account and its data. JSON body `{ "confirm_username": "..." }` must match the Last.fm username. Same-origin headers as above |
| GET | `/up` | Health check |

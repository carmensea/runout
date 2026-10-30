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

## Environment

| Variable | Purpose |
|---|---|
| `LASTFM_API_KEY`, `LASTFM_SHARED_SECRET` | Last.fm API account |
| `LASTFM_ALLOWED_USERNAME` | The one Last.fm account allowed to sign in (case-insensitive). Required: without it, sign-in is refused |
| `APP_ORIGIN` | Browser-facing origin (default `http://localhost:5173`) |
| `ACTIVE_RECORD_ENCRYPTION_*` | Required in production; derived from the local secret in development |
| `DATABASE_URL`, `CACHE_DATABASE_URL`, `QUEUE_DATABASE_URL` | Production (Neon, direct connections) |
| `SECRET_KEY_BASE` | Production |
| `JOB_THREADS` | Solid Queue worker threads (default 2) |
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

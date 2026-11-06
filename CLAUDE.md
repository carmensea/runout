# Runout: development instructions

Personal Last.fm listening archive. React/TypeScript frontend at the repo root, Rails 8 API in
`server/`. Plans: `docs/backend-plan.md`, `docs/milestone-2-plan.md`. Deployment: `docs/railway-deployment.md`.

## Database safety (mandatory)

These rules follow an incident in Milestone 2 Stage 2.1: a step-count rollback
(`db:rollback STEP=4`) on the development database, run after a migration had failed partway,
reverted two Milestone 1 migrations and dropped real rows (a session and a Last.fm connection).

- **Never** run broad rollbacks against the development database: no `db:rollback`,
  `db:rollback STEP=n`, `db:migrate VERSION=<older>`, `db:reset`, `db:drop`, `db:setup`,
  `db:schema:load`, `db:prepare` that would load a schema, or `db:migrate:redo`.
- **Before applying migrations to development:**
  1. Run `bin/rails db:migrate:status` and confirm which migrations are up.
  2. Record the counts of existing rows that must survive (`users`, `identities`,
     `lastfm_connections`, `sessions`).
  3. Migrate forward only.
  4. Confirm the status and the counts again afterwards.
- **If a migration fails partway:** don't roll back. Inspect what was applied
  (`db:migrate:status`, `\d` in psql), fix the migration, and migrate forward again. If a
  partially created object blocks that, explain the exact objects involved and ask before removing
  anything.
- **Reversibility is tested only on disposable test databases** (`RAILS_ENV=test`), one named
  version at a time with `bin/rails db:migrate:down VERSION=<that migration>`, newest first. Never
  use step counts.
- **Never reset, drop, recreate or truncate** the development database or its tables. Never run
  destructive SQL against it.
- **Before any potentially destructive database operation** in any environment other than
  disposable test databases: explain the exact scope (database, tables, rows) and get the owner's
  approval first.
- Preserve existing user, identity, connection and session data in development.
- Tools that write synthetic data (`runout:storage_estimate`) run only with `RAILS_ENV=test`,
  inside a transaction that rolls back. They refuse production, and refuse to run where history
  tables already hold data.

## Data and licensing

- **History storage stays off.** `LASTFM_HISTORY_STORAGE_ENABLED` is off in every environment.
  Don't import or persist real listening history until Last.fm's storage terms are resolved
  (`docs/lastfm-permission-email.md`). History models refuse to create rows while it's off.
- **One authorised exception (2026-10-30):** the owner explicitly authorised a single supervised
  import of their own Last.fm history into the local `runout_development` database, with storage
  switched on only in that import's processes (`docs/real-import-runbook.md`, "Import record").
  It's done: storage is off again and the default configuration is unchanged. It authorises
  nothing else. Not another import, sync with storage on, production, Render or Neon: each needs
  the owner's explicit approval. The imported history is real data: never reset, truncate,
  restore over or rewrite it without the owner's approval.
- **Spotify ingestion needs the owner's approval.** `SPOTIFY_INGESTION_ENABLED` gates storing plays
  reported by Spotify (`docs/spotify-plan.md`). Connecting an account and read-only API checks
  don't need it. Don't switch it on for the real account, or schedule recurring real-account
  Spotify writes, without the owner's explicit approval.
- **One approved Spotify exception (2026-11-03):** the owner authorised the Railway cutover:
  continuous scrobbling of their real account into Railway production, polling through Solid Queue
  (`docs/railway-deployment.md` §5). It's on: don't switch it off or pause it without asking. This
  replaces the local approval of 2026-11-02: local polling is stopped (`SPOTIFY_INGESTION_ENABLED=false`
  in `server/.env`, source paused, no Solid Queue worker), so don't turn it back on without asking;
  two pollers would split new plays between two databases. It authorises nothing else. Enrichment
  in production, Render, Neon or another account each need the owner's explicit approval.
- **One approved archive move (2026-11-04):** the owner explicitly authorised merging the local
  Last.fm archive with Railway's Spotify plays and running production from the result
  (`docs/railway-deployment.md` §6, "Done"). Production now runs on the database `runout` on the
  Railway Postgres service. The previous database `railway` is kept untouched as a fallback, and the
  previous encryption keys are kept as `ROLLBACK_*` variables: don't delete either without asking.
  Since 2026-11-04 the app is served at `https://runout.idlewinny.com` (`docs/railway-deployment.md`
  §10); the Railway address stays in `APP_ORIGINS` as the fallback. Don't remove or redirect it, and
  don't change `APP_ORIGIN` or the OAuth callbacks, without asking.
  The local `runout_development` archive is unchanged and remains the owner's fallback; the rules
  above still apply to it, and now to the Railway copy too. It authorises nothing else: no Last.fm
  sync, no enrichment, no other account.
- **One approved loved-songs import (2026-11-04):** the owner authorised importing their Last.fm
  loved list into `loved_tracks` (`docs/loved-songs.md`), read-only towards Last.fm, run by hand with
  `LASTFM_LOVED_IMPORT_ENABLED=true bin/rails loved:import` on Railway. It's done (2026-11-04, 859 songs):
  the flag is off again. It stores no plays and edits no scrobble, variant or catalogue link. Not a
  recurring refresh, not another run, not writes to Last.fm: each needs approval.
- **ListenBrainz stays off until the owner switches it on.** `LISTENBRAINZ_INGESTION_ENABLED` is off in
  every environment; while off, no ListenBrainz account can be connected and nothing is read or stored.
  Connecting verifies the user's token once and discards it (`docs/listenbrainz-spotify-feasibility.md` §8).
  Don't switch it on in production, or connect a real account, without the owner's explicit approval.
- **Last.fm sync needs the reverse matching rule first.** Before Last.fm sync or import is ever
  switched on again, a Last.fm play matching a stored Spotify play must be linked, not inserted
  (`docs/spotify-plan.md` §5).
- **Live API checks are read-only.** Any live Last.fm verification must be read-only and
  conservatively paced, and must not persist scrobbles.
- **Storage figures prove nothing about compliance.** Measured sizes don't establish compliance
  with Last.fm's terms. Future measurements must include staging, reconciliation and metadata
  tables, not just scrobbles.

## Authentication

- **Runout's own sign-in is behind `RUNOUT_PASSKEYS_ENABLED`** (`docs/milestone-5-plan.md` §2): passkeys,
  recovery codes, the operator link (`bin/rails auth:recovery_link`) and the session routes answer 404
  while it is off. Don't switch it on in production, enrol a passkey for the real account, or remove
  Last.fm sign-in without the owner's explicit approval; the Last.fm fallback stays at least seven
  days after the first passkey and is retired only on the owner's say-so.

## Secrets

- **Where secrets live.** Credentials go in `server/.env` (git-ignored). Never print, log or
  commit API keys, shared secrets, session keys or tokens.
- **Exceptions and logs.** These must not contain them either; the Last.fm client redacts them.
- **Load environment files without echoing them:** `set -a; . ./.env; set +a`.

## Local environment

Don't modify Homebrew, the PostgreSQL installation, or unrelated local configuration without
asking. Ruby is 3.4.7 via chruby (`source /usr/local/share/chruby/chruby.sh && chruby ruby-3.4.7`).

**Runout's database is the PostgreSQL 17 cluster in `~/.local`** (`~/.local/postgresql-17/bin`, data
`~/.local/var/postgresql-17`), started by hand with the command in `docs/real-import-runbook.md`; it
does not start by itself after a reboot. Homebrew's `postgresql@14` cluster belongs to other projects:
never start it on port 5432, use it, or modify it for Runout.

## Working trees (one per task, one per session)

Two Claude sessions must never share a working tree: on 2026-11-05 a checkout in one moved the
branch under another. The primary checkout `~/projects/runout` stays on `main` and is the owner's
console (pull, review, merge, worktree admin); task work happens in a git worktree of its own.

- **Create** one worktree per task, named after its branch, outside the primary:
  `git -C ~/projects/runout fetch origin && git -C ~/projects/runout worktree add ~/projects/runout-worktrees/<task> -b <task> origin/main`.
- **Prepare** it once: copy `.env`, `server/.env` and `server/tmp/local_secret.txt` from the primary
  (git-ignored; the secret file keeps development encryption keys the same), run `npm ci`. Gems are
  shared through chruby. Link the project memory so the session sees it:
  `mkdir -p ~/.claude/projects/-Users-carmen-projects-runout-worktrees-<task> && ln -sfn ~/.claude/projects/-Users-carmen-projects-runout/memory ~/.claude/projects/-Users-carmen-projects-runout-worktrees-<task>/memory`.
- **Launch** the session inside it: `cd ~/projects/runout-worktrees/<task> && claude`. Sessions are
  named after the folder. `git checkout main` fails there by design (main is checked out in the primary).
- **Background tasks never run `git checkout` or `git pull`.** Merge with `gh pr merge`, verify with
  `git fetch` and `git log origin/main`. Confirm `git branch --show-current` before every commit.
- **Databases are shared.** Every worktree uses the same PostgreSQL 17 server and `runout_test`; run
  one backend suite at a time. Local servers need their own `PORT`.
- **Remove** after the PR merges: `git -C ~/projects/runout worktree remove ~/projects/runout-worktrees/<task>`.

## Checks before committing

- Frontend (repo root): `npm run lint`, `npm run typecheck`, `npm test`, `npm run build`.
- Backend (`server/`): `bin/rails test`, `bin/rubocop`, `bin/brakeman --no-pager --quiet`,
  `bin/bundler-audit`.

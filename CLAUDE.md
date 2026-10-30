# Runout: development instructions

Personal Last.fm listening archive. React/TypeScript frontend at the repo root, Rails 8 API in
`server/`. Plans: `docs/backend-plan.md`, `docs/milestone-2-plan.md`.

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
- **Live API checks are read-only.** Any live Last.fm verification must be read-only and
  conservatively paced, and must not persist scrobbles.
- **Storage figures prove nothing about compliance.** Measured sizes don't establish compliance
  with Last.fm's terms. Future measurements must include staging, reconciliation and metadata
  tables, not just scrobbles.

## Secrets

- **Where secrets live.** Credentials go in `server/.env` (git-ignored). Never print, log or
  commit API keys, shared secrets, session keys or tokens.
- **Exceptions and logs.** These must not contain them either; the Last.fm client redacts them.
- **Load environment files without echoing them:** `set -a; . ./.env; set +a`.

## Local environment

Don't modify Homebrew, the PostgreSQL installation, or unrelated local configuration without
asking. Ruby is 3.4.7 via chruby (`source /usr/local/share/chruby/chruby.sh && chruby ruby-3.4.7`).

## Checks before committing

- Frontend (repo root): `npm run lint`, `npm run typecheck`, `npm test`, `npm run build`.
- Backend (`server/`): `bin/rails test`, `bin/rubocop`, `bin/brakeman --no-pager --quiet`,
  `bin/bundler-audit`.

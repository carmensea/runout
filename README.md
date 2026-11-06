# Runout

A personal listening archive: every play you have ever reported to Last.fm, Spotify or
ListenBrainz, kept in one database you control, with charts (years, hours, artists, genres), a
Time Machine for any day, loved songs, and the plumbing to keep it growing without depending on any
one service. It is built for one listener at a time, with invitation-only accounts, passkey
sign-in and encrypted off-platform backups.

**Source available, no open-source licence.** The code is public to read and study, and GitHub
lets anyone fork or clone it, but no general permission to reuse, modify or redistribute Runout is
granted at this time. A licence may be added later.

## What is here

- `src/`: the React and TypeScript frontend (Vite), an editorial design with five themes.
- `server/`: the Rails 8 API: Last.fm import and sync, Spotify and ListenBrainz ingestion with
  cross-provider deduplication, catalogue and genres, passkeys, invitations, backups.
- `deploy/backup/`: the encrypted backup job and its test.
- `docs/`: the plans and decisions behind each milestone, deployment and runbooks.
- `CLAUDE.md`: the working rules for development, including database safety.

## Run it locally

```sh
npm install
npm run dev        # http://localhost:5173, frontend only unless VITE_RUNOUT_API_URL is set
npm run build      # type-check and production build
npm run lint
npm test
```

Node 22 or later. The API needs Ruby 3.4.7 and PostgreSQL 17: see `server/README.md`. Set
`VITE_RUNOUT_API_URL=/api` (see `.env.example`) to use the dev proxy to a local server. Without a
server the app runs disconnected and shows the signed-out state.

## Data

The UI never fabricates listening data: everything comes from the Runout API (`src/data/api.ts`,
types in `src/data/types.ts`). Listening history is stored only with the data holder's terms
respected and the operator's explicit say-so; see the data rules in `CLAUDE.md`.

### Specimen mode (development only)

`npm run dev`, then open `/overview?specimen`: structural placeholder shapes
(`src/data/fixtures/specimenApi.ts`) with every figure as zeros, for layout work. Excluded from
production builds; `?specimen=off` turns it off.

## Period state

One global period lives in the URL (`?period=year:2014&vs=year:2011`) and is mirrored to
localStorage. See `src/lib/period.ts` and `src/state/PeriodContext.tsx`.

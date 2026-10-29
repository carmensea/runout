# Runout

Personal Last.fm listening archive. This repository currently implements the **Overview** screen
from the Claude Design handoff, plus the shared shell (sidebar, period bar, search).

## Run

```sh
npm install
npm run dev        # http://localhost:5173
npm run build      # type-check + production build
npm run lint
npm test
```

Node 22 or later.

## Data

The UI never fabricates listening data. It talks to a Runout API (`src/data/api.ts`):

| Endpoint | Returns |
|---|---|
| `GET /connection` | `ConnectionState` (none, importing, synced, failed) |
| `GET /overview?period=year:2014` | `OverviewData` for one period (requested again for the comparison period) |
| `GET /search?q=` | `SearchResults` |

Types are in `src/data/types.ts`. HTTP 409 means no Last.fm account is connected.
Set `VITE_RUNOUT_API_URL` (see `.env.example`). Without it the app runs disconnected and shows
the "Connect Last.fm" state.

### Specimen mode (development only)

`npm run dev`, then open `/overview?specimen`. This loads structural placeholder shapes
(`src/data/fixtures/specimenApi.ts`) and renders every figure as zeros and every date as its
format token, matching the design reference. It is excluded from production builds.
`?specimen=off` turns it off again.

## Period state

One global period lives in the URL (`?period=year:2014&vs=year:2011`) and is mirrored to
localStorage. See `src/lib/period.ts` and `src/state/PeriodContext.tsx`.

## Not built yet

Time Machine, Artists, Tracks, album and track detail, Settings, Connect, Lyrics and Mood render
`PendingScreen`, which says so plainly and shows the parameters it received.

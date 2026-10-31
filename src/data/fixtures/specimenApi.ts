/**
 * DEVELOPMENT ONLY. Structural specimen data for reviewing layout against the Claude Design
 * reference. It is loaded through a dynamic import guarded by `import.meta.env.DEV`, so it is
 * never part of a production bundle.
 *
 * Shapes are deterministic noise; names are numbered placeholders ("Artist 01"). Specimen mode
 * also swaps in the specimen formatter, so every figure renders as zeros and every date as its
 * format token. Nothing here is, or should ever be presented as, listening data.
 */
import { serializePeriod, type Period } from '../../lib/period';
import type { HistoryApi, RunoutApi } from '../api';
import type { ActivityBucket, GenreBreakdown, ImportStatus, OverviewData, TopEntry } from '../types';

function rng(seed: number) {
  let s = seed;
  return () => {
    s |= 0;
    s = (s + 0x6d2b79f5) | 0;
    let t = Math.imul(s ^ (s >>> 15), 1 | s);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const pad = (n: number) => String(n).padStart(2, '0');
const placeholder = (noun: string, n: number) => `${noun} ${pad(n)}`;

function buildOverview(period: Period, seed: number): OverviewData {
  const r = rng(seed);
  const firstYear = 2008;
  const months: ActivityBucket[] = [];
  for (let i = 0; i < 226; i++) {
    const v = Math.max(0.04, 0.45 + 0.28 * Math.sin(i / 19) + 0.12 * Math.sin(i / 5.3) + (r() - 0.5) * 0.35 - (i > 120 && i < 150 ? 0.25 : 0));
    months.push({ key: `${firstYear + Math.floor(i / 12)}-${pad((i % 12) + 1)}`, scrobbles: Math.round(v * 1000), topArtist: placeholder('Artist', 1) });
  }
  const years: ActivityBucket[] = [];
  for (let y = 0; y < 19; y++) {
    const slice = months.slice(y * 12, y * 12 + 12);
    years.push({ key: String(firstYear + y), scrobbles: slice.reduce((a, b) => a + b.scrobbles, 0), topArtist: placeholder('Artist', 1) });
  }

  const byHour = Array.from({ length: 24 }, (_, h) =>
    Math.round(1000 * (0.08 + 0.5 * Math.exp(-((h - 9) ** 2) / 6) + 0.8 * Math.exp(-((h - 20.5) ** 2) / 10) + 0.3 * Math.exp(-((h - 14) ** 2) / 8) + r() * 0.08)));
  const wv = [0.82, 0.86, 0.9, 0.84, 1, 0.7, 0.62];
  const byWeekday = wv.map((v) => Math.round(v * 1000));
  const hmx = Math.max(...byHour);
  const byWeekdayHour = wv.map((w, d) =>
    byHour.map((v, h) => {
      const x = (v / hmx) * w * (d > 4 && h < 11 ? 0.5 : 1) * (0.75 + r() * 0.5);
      return x < 0.12 ? 0 : Math.round(x * 1000);
    }));
  const avgPerDayByMonth = [0.9, 0.85, 0.7, 0.66, 0.6, 0.55, 0.5, 0.58, 0.72, 0.8, 0.95, 1].map((v) => v * 100);

  const genreNames: Array<[string, string[]]> = [
    ['Rock', ['Indie rock', 'Post-punk', 'Shoegaze', 'Alternative rock', 'Garage rock']],
    ['Electronic', ['House', 'Ambient', 'Techno', 'IDM', 'Downtempo']],
    ['Pop', ['Synth-pop', 'Art pop', 'Dream pop', 'Indie pop']],
    ['Hip-hop', ['Boom bap', 'Abstract hip-hop', 'UK hip-hop', 'Trap']],
    ['Folk', ['Indie folk', 'Singer-songwriter', 'Americana', 'Folk rock']],
    ['Jazz', ['Spiritual jazz', 'Hard bop', 'Jazz fusion', 'Nu jazz']],
    ['Other', ['Classical', 'Soundtrack', 'Reggae', 'Metal']],
  ];
  const byYear: GenreBreakdown['byYear'] = [];
  for (let y = 0; y < 19; y++) {
    const t = y / 18;
    const row = [0.42 - 0.25 * t, 0.12 + 0.28 * t, 0.15 + 0.05 * Math.sin(y / 3), 0.06 + 0.1 * t, 0.1 + 0.06 * Math.sin(y / 4 + 1), 0.03 + 0.07 * t * t, 0.08]
      .map((v) => Math.max(0.02, v + (r() - 0.5) * 0.03));
    const sum = row.reduce((a, b) => a + b, 0);
    byYear.push({ year: firstYear + y, shares: Object.fromEntries(row.map((v, g) => [`g${g}`, v / sum])) });
  }
  const categories = genreNames.map(([name, subgenres], g) => ({
    id: `g${g}`,
    name,
    share: byYear.reduce((a, row) => a + (row.shares[`g${g}`] ?? 0), 0) / byYear.length,
    subgenres,
    topArtists: [1, 2, 3, 4, 5].map((k) => ({ id: `a${g * 5 + k}`, name: placeholder('Artist', g * 5 + k), scrobbles: 1000 - k * 100 })),
  }));

  const topEntry = (kind: 'artists' | 'albums' | 'tracks', i: number): TopEntry => {
    let v = 12 + r() * 6;
    const trend = [v];
    for (let x = 0; x < 12; x++) {
      v = Math.max(2, Math.min(22, v + (r() - 0.5) * 8));
      trend.push(24 - v);
    }
    const noun = kind === 'artists' ? 'Artist' : kind === 'albums' ? 'Album title' : 'Track title';
    return {
      id: `${kind}-${i}`,
      name: placeholder(noun, i),
      artist: kind === 'artists' ? null : placeholder('Artist', ((i * 3) % 10) + 1),
      tracksPlayed: kind === 'artists' ? 1000 : null,
      imageUrl: null,
      scrobbles: 1000,
      firstScrobble: '2008-01-01',
      latestScrobble: '2026-01-01',
      trend,
    };
  };
  const top = (kind: 'artists' | 'albums' | 'tracks') => Array.from({ length: 10 }, (_, i) => topEntry(kind, i + 1));

  const ranks = [[1, 1, 2, 1, 1, 2, 1, 1], [3, 2, 1, 2, 3, 1, 2, 2], [6, 5, 4, 3, 2, 3, 3, 3], [2, 4, 5, 6, 5, 4, 5, 4], [9, 8, 6, 5, 4, 6, 4, 5]];

  const discoveryMonths = Array.from({ length: 24 }, (_, i) => {
    const idx = 2024 * 12 + 10 + i;
    return { key: `${Math.floor(idx / 12)}-${pad((idx % 12) + 1)}`, newArtists: Math.round((0.25 + r() * 0.7) * 100), explorationShare: 0.2 + r() * 0.4 };
  });

  return {
    period: serializePeriod(period),
    stats: {
      scrobbles: 100000, firstScrobbleDate: '2008-01-01', uniqueArtists: 1000, artistsPlayedOverTen: 100,
      uniqueTracks: 10000, tracksPlayedOnce: 1000, uniqueAlbums: 1000, albumsWithoutArtwork: 100,
    },
    activity: { month: months, year: years, week: null },
    mostActiveDays: [100, 92, 88, 81, 77].map((s, i) => ({ key: `2014-03-${pad(i + 1)}`, scrobbles: s })),
    mostActiveMonths: [100, 96, 90, 85, 83].map((s, i) => ({ key: `2014-${pad(i + 1)}`, scrobbles: s * 10 })),
    habits: { byHour, byWeekday, byWeekdayHour, avgPerDayByMonth },
    genres: { broad: { categories, untaggedShare: 0, byYear }, sub: null },
    top: { artists: top('artists'), albums: top('albums'), tracks: top('tracks'), totals: { artists: 1000, albums: 1000, tracks: 1000 } },
    rankHistory: {
      years: [2019, 2020, 2021, 2022, 2023, 2024, 2025, 2026],
      series: ranks.map((rk, a) => ({ id: `artists-${a + 1}`, name: placeholder('Artist', a + 1), ranks: rk })),
    },
    onRepeat: [1, 2, 3, 4, 5].map((i) => ({ trackId: `tracks-${i}`, name: placeholder('Track title', i), artist: placeholder('Artist', i), plays: 10, date: '2014-03-15' })),
    backInRotation: [16, 17, 18, 19, 20].map((i) => ({ id: `artists-${i}`, name: placeholder('Artist', i), awayMonths: 0, backMonth: '2026-01' })),
    discovery: {
      months: discoveryMonths,
      firstHeard: [21, 22, 23, 24].map((i) => ({ id: `artists-${i}`, name: placeholder('Artist', i), firstScrobble: '2026-01-01', scrobbles: 100 })),
      rediscovered: [31, 32, 33].map((i) => ({ id: `artists-${i}`, name: placeholder('Artist', i), lastYearBefore: 2010 })),
    },
    metadata: {
      byArtists: { male: 38, female: 21, nonbinary: 3, group: 26, unknown: 12 },
      byScrobbles: { male: 41, female: 18, nonbinary: 2, group: 31, unknown: 8 },
      unmatchedArtists: 100,
    },
    nearestWithData: [],
  };
}

/**
 * Settings layout review: the history panels' states, nothing real. `?specimen&history=` picks one:
 * `importing`, `paused`, `not_started`, `sync_paused`, `account`, `loading` (never answers),
 * `error` (every request fails); default: imported, with a gap, a stopped month and two review items.
 */
const specimenState = () => new URLSearchParams(window.location.search).get('history') ?? 'imported';

const specimenImport = (): ImportStatus => {
  const state = specimenState();
  const imported: ImportStatus = {
    enabled: true, state: 'completed', complete: true, stalled: false, activity: 'idle', percent: 100, importedScrobbles: 0,
    lastfmPlaycount: 0, historyFrom: '2006-01-01T00:00:00Z', cutoffAt: '2026-01-01T00:00:00Z', currentPeriod: null,
    periods: { pending: 0, processing: 0, committed: 0, failed: 0, review: 1 }, startedAt: null, finishedAt: null, lastImportedAt: null,
    error: null, failures: [], missingPeriods: [], attention: 2, canStart: false,
  };
  if (state === 'not_started') return { ...imported, state: 'not_started', complete: false, percent: null, canStart: true };
  if (state === 'importing' || state === 'paused') {
    return {
      ...imported, state: state === 'importing' ? 'running' : 'paused', complete: false, activity: state === 'importing' ? 'importing' : 'paused',
      percent: 42, currentPeriod: { from: '2014-03-01T00:00:00Z', to: '2014-04-01T00:00:00Z' },
      periods: { pending: 0, processing: 1, committed: 0, failed: 0, review: 0 },
    };
  }
  return imported;
};

/** `loading` and `error` states: the same for every history request. */
async function specimenRequest<T>(value: () => T): Promise<T> {
  if (specimenState() === 'loading') return new Promise<T>(() => {});
  if (specimenState() === 'error') throw new Error('Specimen: the request failed.');
  return value();
}

const specimenHistory: HistoryApi = {
  importStatus: () => specimenRequest(specimenImport),
  syncHealth: () => specimenRequest(() => ({
    importComplete: !['not_started', 'importing', 'paused'].includes(specimenState()),
    syncPaused: specimenState() === 'sync_paused',
    connectionState: specimenState() === 'account' ? 'failed' : 'imported',
    message: specimenState() === 'account' ? 'Your Last.fm username changed. Relink the account to resume syncing.' : null,
    activity: specimenState() === 'sync_paused' ? 'sync_paused' : 'idle',
    enabled: true,
    lastSuccessfulSyncAt: '2026-01-01T00:00:00Z', lastAttemptedSyncAt: '2026-01-01T00:00:00Z', syncedThrough: '2026-01-01T00:00:00Z',
    coveredThrough: '2014-03-05T10:00:00Z', coverage: [], activeRun: null, lastRun: null, newScrobbles: { lastRun: 0, last24Hours: 0 },
    missingPeriods: [{ from: '2014-03-05T10:00:00Z', to: '2014-03-05T11:00:00Z', state: 'needs_review', reason: 'undated_rows', message: null }],
    problemPeriods: [
      { id: 1, from: '2014-03-05T10:00:00Z', to: '2014-03-05T11:00:00Z', status: 'check_stopped', imported: false, reason: 'undated_rows',
        message: 'Specimen', retriesAutomatically: false, attempts: 1, httpStatus: null, lastfmError: null },
      { id: 2, from: '2025-12-01T00:00:00Z', to: '2026-01-01T00:00:00Z', status: 'check_stopped', imported: true, reason: 'gave_up',
        message: 'Specimen', retriesAutomatically: true, attempts: 5, httpStatus: 502, lastfmError: null },
    ],
    periods: {}, awaitingRecheck: 0, stalePeriods: 0, reviews: { disputes: 1, suspectedRemovals: 1, pendingRemovals: 1, reappeared: 0 },
    attention: { reviews: 2, periods: 1, account: 0, total: 3 },
    nextDue: { reconcile: '2026-01-01T00:00:00Z', catch_up: '2026-01-01T00:00:00Z', sync: '2026-01-01T00:00:00Z' },
  })),
  reviews: () => specimenRequest(() => ({
    total: 2, offset: 0, waiting: 1,
    items: [
      { kind: 'removal', id: 1, version: 'specimen', playedAt: '2014-03-15T20:00:00Z', history: [], removedAt: null,
        play: { id: 1, seq: 0, artist: placeholder('Artist', 1), track: placeholder('Track title', 1), album: placeholder('Album title', 1) },
        firstMissingAt: '2026-01-01T00:00:00Z', confirmedMissingAt: '2026-01-01T00:00:00Z' },
      { kind: 'dispute', id: 2, version: 'specimen', playedAt: '2014-04-02T09:00:00Z', history: [], firstSeenAt: '2026-01-01T00:00:00Z',
        lastSeenAt: '2026-01-01T00:00:00Z', stored: [{ id: 2, seq: 0, artist: placeholder('Artist', 2), track: placeholder('Track title', 2), album: null }],
        fetched: [{ index: 0, artist: placeholder('Artist', 2), track: placeholder('Track title', 3), album: null }] },
    ],
  })),
  startImport: async () => {}, pauseImport: async () => {}, resumeImport: async () => {}, cancelImport: async () => {},
  retryPeriod: async () => {}, refreshSync: async () => {}, pauseSync: async () => {}, resumeSync: async () => {},
  decide: async () => ({ result: 'specimen', item: null }),
};

export const specimenApi: RunoutApi = {
  getConnection: async () => ({ status: 'synced', username: 'lastfm-username', timezone: 'Europe/London', lastSyncedAt: '2026-01-01T00:00:00Z' }),
  getOverview: async (period) => buildOverview(period, 7 + serializePeriod(period).length),
  search: async () => ({
    artists: [1, 2, 3].map((i) => ({ id: `artists-${i}`, name: placeholder('Artist', i) })),
    albums: [1, 2].map((i) => ({ id: `albums-${i}`, name: placeholder('Album title', i), artist: placeholder('Artist', i) })),
    tracks: [1, 2].map((i) => ({ id: `tracks-${i}`, name: placeholder('Track title', i), artist: placeholder('Artist', i) })),
  }),
  signInUrl: () => null,
  signOut: async () => {},
  deleteAccount: async () => {
    throw new Error('Specimen mode has no account to delete.');
  },
  history: specimenHistory,
};

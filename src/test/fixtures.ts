/** Test-only data. Small, obviously synthetic values used to exercise rendering paths. */
import type { HistoryApi, RunoutApi } from '../data/api';
import { NotConnectedError, noHistoryApi } from '../data/api';
import type { ImportStatus, OverviewData, ReviewQueue, SyncHealth } from '../data/types';
import { serializePeriod } from '../lib/period';

const zeros = (n: number) => Array.from({ length: n }, () => 0);

export function makeOverview(overrides: Partial<OverviewData> = {}): OverviewData {
  return {
    period: 'all',
    stats: {
      scrobbles: 4321, firstScrobbleDate: '2020-01-05', uniqueArtists: 12, artistsPlayedOverTen: 3,
      uniqueTracks: 40, tracksPlayedOnce: 9, uniqueAlbums: 15, albumsWithoutArtwork: 2,
    },
    activity: {
      month: [
        { key: '2020-01', scrobbles: 10, topArtist: 'Test Artist A' },
        { key: '2020-02', scrobbles: 30, topArtist: 'Test Artist B' },
        { key: '2020-03', scrobbles: 20, topArtist: null },
      ],
      year: [{ key: '2020', scrobbles: 60, topArtist: 'Test Artist A' }],
      week: null,
    },
    mostActiveDays: [{ key: '2020-02-14', scrobbles: 12 }],
    mostActiveMonths: [{ key: '2020-02', scrobbles: 30 }],
    habits: {
      byHour: zeros(24).map((_, h) => (h === 21 ? 9 : 1)),
      byWeekday: [1, 2, 3, 4, 5, 6, 7],
      byWeekdayHour: Array.from({ length: 7 }, () => zeros(24).map((_, h) => h % 5)),
      avgPerDayByMonth: zeros(12).map((_, i) => i),
    },
    genres: {
      broad: {
        categories: [
          { id: 'rock', name: 'Rock', share: 0.6, subgenres: ['Post-punk'], topArtists: [{ id: 'a1', name: 'Test Artist A', scrobbles: 20 }] },
          { id: 'jazz', name: 'Jazz', share: 0.3, subgenres: [], topArtists: [] },
        ],
        untaggedShare: 0.1,
        byYear: [
          { year: 2020, shares: { rock: 0.6, jazz: 0.3, untagged: 0.1 } },
          { year: 2021, shares: { rock: 0.5, jazz: 0.4, untagged: 0.1 } },
        ],
      },
      sub: null,
    },
    top: {
      artists: [{ id: 'a1', name: 'Test Artist A', artist: null, tracksPlayed: 4, imageUrl: null, scrobbles: 20, firstScrobble: '2020-01-05', latestScrobble: '2021-02-01', trend: [1, 2, 3] }],
      albums: [],
      tracks: [],
      totals: { artists: 12, albums: 15, tracks: 40 },
    },
    rankHistory: { years: [2020, 2021], series: [{ id: 'a1', name: 'Test Artist A', ranks: [1, 2] }] },
    onRepeat: [],
    backInRotation: [],
    discovery: { months: [{ key: '2020-01', newArtists: 3, explorationShare: 0.2 }], firstHeard: [], rediscovered: [] },
    metadata: {
      byArtists: { male: 1, female: 1, nonbinary: 0, group: 1, unknown: 1 },
      byScrobbles: { male: 10, female: 10, nonbinary: 0, group: 10, unknown: 10 },
      unmatchedArtists: 0,
    },
    nearestWithData: [],
    coverage: { status: 'complete', missing: [] },
    ...overrides,
  };
}

export function connectedApi(overview: (period: string) => OverviewData = () => makeOverview()): RunoutApi {
  return {
    getConnection: async () => ({ status: 'synced', username: 'test-user', timezone: 'Europe/London', lastSyncedAt: '2026-10-29T09:00:00Z' }),
    getOverview: async (p) => overview(serializePeriod(p)),
    search: async () => ({ artists: [{ id: 'a1', name: 'Test Artist A' }], albums: [], tracks: [] }),
    getCalendar: async () => ({ firstDay: null, lastDay: null, years: [], months: [], coverage: { status: 'none', missing: [] } }),
    getCalendarDays: async (from, to) => ({ from, to, days: [], coverage: { status: 'none', missing: [] } }),
    getPlays: async (p) => ({ period: serializePeriod(p), total: 0, plays: [], nextCursor: null, coverage: { status: 'none', missing: [] } }),
    getOnThisDay: async (date) => ({ date, leapDay: false, years: [] }),
    signInUrl: () => '/api/auth/lastfm',
    signOut: async () => {},
    deleteAccount: async () => ({ revokeAccessUrl: 'https://www.last.fm/settings/applications' }),
    history: fakeHistoryApi(),
  };
}

export function makeImportStatus(overrides: Partial<ImportStatus> = {}): ImportStatus {
  return {
    enabled: true, state: 'completed', complete: true, stalled: false, activity: 'idle', percent: 100, importedScrobbles: 4321,
    lastfmPlaycount: 4321, historyFrom: '2020-01-01T00:00:00Z', cutoffAt: '2026-10-29T08:00:00Z', currentPeriod: null,
    periods: { pending: 0, processing: 0, committed: 82, failed: 0, review: 0 }, startedAt: '2026-10-29T07:00:00Z',
    finishedAt: '2026-10-29T08:00:00Z', lastImportedAt: '2026-10-29T08:00:00Z', error: null, failures: [], missingPeriods: [],
    attention: 0, canStart: false, ...overrides,
  };
}

export function makeSyncHealth(overrides: Partial<SyncHealth> = {}): SyncHealth {
  return {
    enabled: true, importComplete: true, connectionState: 'imported', syncPaused: false, activity: 'idle', message: null,
    lastSuccessfulSyncAt: '2026-10-29T09:00:00Z', lastAttemptedSyncAt: '2026-10-29T09:00:00Z', syncedThrough: '2026-10-29T08:45:00Z',
    coveredThrough: '2026-10-29T08:45:00Z', coverage: [{ from: '2020-01-01T00:00:00Z', to: '2026-10-29T08:45:00Z' }], missingPeriods: [],
    activeRun: null, lastRun: null, newScrobbles: { lastRun: 2, last24Hours: 12 }, periods: { synchronized: 82 }, awaitingRecheck: 0,
    problemPeriods: [], stalePeriods: 0, reviews: { disputes: 0, suspectedRemovals: 0, pendingRemovals: 0, reappeared: 0 },
    attention: { reviews: 0, periods: 0, account: 0, total: 0 },
    nextDue: { reconcile: '2026-11-05T08:00:00Z', catch_up: '2026-10-30T08:00:00Z', sync: '2026-10-29T09:30:00Z' }, ...overrides,
  };
}

/** A history API answering from fixed data, with every call recorded. Override any method. */
export function fakeHistoryApi(overrides: Partial<HistoryApi> & { calls?: string[] } = {}): HistoryApi & { calls: string[] } {
  const calls = overrides.calls ?? [];
  const record = (name: string) => async () => {
    calls.push(name);
  };
  const empty: ReviewQueue = { items: [], total: 0, offset: 0, waiting: 0 };
  return {
    importStatus: async () => makeImportStatus(),
    syncHealth: async () => makeSyncHealth(),
    reviews: async () => empty,
    startImport: record('startImport'),
    pauseImport: record('pauseImport'),
    resumeImport: record('resumeImport'),
    cancelImport: record('cancelImport'),
    retryPeriod: async (id) => {
      calls.push(`retryPeriod:${id}`);
    },
    refreshSync: record('refreshSync'),
    pauseSync: record('pauseSync'),
    resumeSync: record('resumeSync'),
    decide: async (item, decision, options) => {
      calls.push(`decide:${item.kind}:${item.id}:${decision}:${JSON.stringify(options ?? {})}`);
      return { result: decision, item: null };
    },
    ...overrides,
    calls,
  };
}

export const notConnectedApi: RunoutApi = {
  getConnection: async () => ({ status: 'none' }),
  getOverview: async () => {
    throw new NotConnectedError();
  },
  search: async () => {
    throw new NotConnectedError();
  },
  getCalendar: async () => {
    throw new NotConnectedError();
  },
  getCalendarDays: async () => {
    throw new NotConnectedError();
  },
  getPlays: async () => {
    throw new NotConnectedError();
  },
  getOnThisDay: async () => {
    throw new NotConnectedError();
  },
  signInUrl: () => '/api/auth/lastfm',
  signOut: async () => {},
  deleteAccount: async () => {
    throw new NotConnectedError();
  },
  history: noHistoryApi,
};

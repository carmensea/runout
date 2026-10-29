/** Test-only data. Small, obviously synthetic values used to exercise rendering paths. */
import type { RunoutApi } from '../data/api';
import { NotConnectedError } from '../data/api';
import type { OverviewData } from '../data/types';
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
    ...overrides,
  };
}

export function connectedApi(overview: (period: string) => OverviewData = () => makeOverview()): RunoutApi {
  return {
    getConnection: async () => ({ status: 'synced', username: 'test-user', timezone: 'Europe/London', lastSyncedAt: '2026-10-29T09:00:00Z' }),
    getOverview: async (p) => overview(serializePeriod(p)),
    search: async () => ({ artists: [{ id: 'a1', name: 'Test Artist A' }], albums: [], tracks: [] }),
    signInUrl: () => '/api/auth/lastfm',
    signOut: async () => {},
    deleteAccount: async () => ({ revokeAccessUrl: 'https://www.last.fm/settings/applications' }),
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
  signInUrl: () => '/api/auth/lastfm',
  signOut: async () => {},
  deleteAccount: async () => {
    throw new NotConnectedError();
  },
};

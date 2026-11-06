/** Test-only data. Small, obviously synthetic values used to exercise rendering paths. */
import type { AuthApi, HistoryApi, RunoutApi, SourcesApi } from '../data/api';
import { NotConnectedError, noAuthApi, noHistoryApi, noSourcesApi } from '../data/api';
import type {
  ArtistKindKey, BrowserSession, Passkey, SessionInfo, GenreDetail, ImportStatus, ListeningReviewItem, ListeningSources, LovedLibrary, LovedTrack, OverviewData, ReviewQueue, SpotifySource, SyncHealth,
} from '../data/types';
import { serializePeriod } from '../lib/period';

const zeros = (n: number) => Array.from({ length: n }, () => 0);

const noKinds: Record<ArtistKindKey, number> = {
  female: 0, male: 0, nonbinary: 0, other_gender: 0, person_unlisted: 0, group: 0, orchestra_choir: 0, other_type: 0,
  type_unlisted: 0, not_looked_up: 0, not_identified: 0,
};

export function makeGenreDetail(slug = 'rock', overrides: Partial<GenreDetail> = {}): GenreDetail {
  return {
    period: 'all',
    genre: { slug, name: 'Rock', level: 'broad', parent: null },
    plays: 100, allocated: 40, share: 0.4, reach: { plays: 70, share: 0.7 }, unclassifiedShare: 0.2,
    subgenres: [{ slug: 'post-punk', name: 'Post-punk', allocated: 30, share: 0.3 }, { slug: null, name: 'Other rock', allocated: 10, share: 0.1 }],
    topArtists: [{ id: 'a1', name: 'Test Artist A', allocated: 25.5, plays: 30, genreShare: 0.85 }],
    topTracks: [{ id: 't1', name: 'Test Track', artist: 'Test Artist A', allocated: 8.5 }],
    byYear: [{ year: 2020, plays: 60, allocated: 30, share: 0.5, reachShare: 0.8 }, { year: 2021, plays: 40, allocated: 10, share: 0.25, reachShare: 0.5 }],
    methodology: { level: 'artist', provider: 'MusicBrainz', license: 'CC BY-NC-SA 3.0', url: 'https://musicbrainz.org' },
    ...overrides,
  };
}

/** A loved song; `track.id` is the identity key hearts match on. */
export function makeLoved(i: number, overrides: Partial<LovedTrack> = {}): LovedTrack {
  return {
    id: i, source: 'lastfm', lovedAt: `2015-0${(i % 9) + 1}-01T12:00:00Z`, unlovedAt: null, manual: false, url: `https://www.last.fm/music/x/_/${i}`,
    artist: { id: `a${i}`, name: `Loved Artist ${i}` }, track: { id: `t${i}`, name: `Loved Track ${i}` },
    asLoved: { artist: `Loved Artist ${i}`, track: `Loved Track ${i}` }, link: 'linked',
    plays: 10 * i, firstPlayedAt: '2014-01-01T00:00:00Z', lastPlayedAt: '2024-06-01T00:00:00Z', lastPlayedDate: '2024-06-01',
    previousPlayedAt: '2020-01-01T00:00:00Z', namePlays: 10 * i,
    ...overrides,
  };
}

export function makeLovedLibrary(tracks: LovedTrack[] = [makeLoved(1), makeLoved(2)]): LovedLibrary {
  return { total: tracks.length, recentDays: 90, generatedAt: '2026-11-04T12:00:00Z', tracks };
}

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
        unclassified: { notIdentified: 0.05, notLookedUp: 0.03, noGenres: 0.02 },
        byYear: [
          { year: 2020, shares: { rock: 0.6, jazz: 0.3, untagged: 0.1 } },
          { year: 2021, shares: { rock: 0.5, jazz: 0.4, untagged: 0.1 } },
        ],
      },
      sub: null,
      level: 'artist',
      source: { provider: 'MusicBrainz', license: 'CC BY-NC-SA 3.0', url: 'https://musicbrainz.org' },
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
      byArtists: { ...noKinds, male: 1, female: 1, group: 1, not_looked_up: 1 },
      byScrobbles: { ...noKinds, male: 10, female: 10, group: 10, not_looked_up: 10 },
      unmatchedArtists: 0,
      source: { provider: 'MusicBrainz', license: 'CC0', url: 'https://musicbrainz.org' },
    },
    nearestWithData: [],
    coverage: { status: 'complete', missing: [] },
    ...overrides,
  };
}

export function connectedApi(overview: (period: string) => OverviewData = () => makeOverview()): RunoutApi {
  return {
    getConnection: async () => ({ status: 'synced', displayName: 'test-user', username: 'test-user', timezone: 'Europe/London', lastSyncedAt: '2026-10-29T09:00:00Z' }),
    getOverview: async (p) => overview(serializePeriod(p)),
    search: async () => ({ artists: [{ id: 'a1', name: 'Test Artist A' }], albums: [], tracks: [] }),
    getCalendar: async () => ({ firstDay: null, lastDay: null, years: [], months: [], coverage: { status: 'none', missing: [] } }),
    getCalendarDays: async (from, to) => ({ from, to, days: [], coverage: { status: 'none', missing: [] } }),
    getPlays: async (p) => ({ period: serializePeriod(p), total: 0, plays: [], nextCursor: null, coverage: { status: 'none', missing: [] } }),
    getOnThisDay: async (date) => ({ date, leapDay: false, years: [] }),
    getGenre: async (slug) => makeGenreDetail(slug),
    getLovedTracks: async () => makeLovedLibrary([]),
    signInUrl: () => '/api/auth/lastfm',
    signOut: async () => {},
    setTheme: async () => {},
    deleteAccount: async () => ({ revokeAccessUrl: 'https://www.last.fm/settings/applications', spotifyAppsUrl: null }),
    history: fakeHistoryApi(),
    sources: fakeSourcesApi(),
    auth: noAuthApi,
  };
}

export function makeSources(spotify: Partial<SpotifySource> = {}): ListeningSources {
  return {
    lastfm: { role: 'archive', connected: true, username: 'test-user' },
    spotify: { configured: true, ingestionEnabled: false, state: 'not_connected', account: null, ...spotify },
    listenbrainz: { enabled: true, state: 'not_connected', account: null },
  };
}

export function fakeSourcesApi(initial: ListeningSources = makeSources(), reviews: ListeningReviewItem[] = []): SourcesApi & { calls: string[] } {
  let current = initial;
  let queue = reviews;
  const calls: string[] = [];
  const set = (spotify: Partial<SpotifySource>) => {
    current = { ...current, spotify: { ...current.spotify, ...spotify } };
    return current;
  };
  return {
    calls,
    status: async () => current,
    connectSpotifyUrl: () => '/api/auth/spotify',
    disconnectSpotify: async () => {
      calls.push('disconnect');
      return set({ state: 'disconnected', disconnectedAt: '2026-10-31T12:00:00Z' });
    },
    syncSpotify: async () => { calls.push('sync'); },
    pauseSpotify: async () => { calls.push('pause'); return set({ paused: true }); },
    resumeSpotify: async () => { calls.push('resume'); return set({ paused: false }); },
    reviews: async () => queue,
    decide: async (id, decision) => {
      calls.push(`decide:${id}:${decision === 'separate' ? 'separate' : decision.link}`);
      queue = queue.filter((item) => item.id !== id);
      set({ pendingReview: queue.length });
      return queue;
    },
    connectListenbrainz: async (token) => {
      calls.push(`connectListenbrainz:${token}`);
      current = { ...current, listenbrainz: { ...current.listenbrainz, state: 'connected', account: { id: 'dana_lb', displayName: 'dana_lb' }, connectedAt: '2026-11-06T10:00:00Z' } };
      return current;
    },
    disconnectListenbrainz: async () => {
      calls.push('disconnectListenbrainz');
      current = { ...current, listenbrainz: { ...current.listenbrainz, state: 'disconnected', disconnectedAt: '2026-11-06T11:00:00Z' } };
      return current;
    },
  };
}

export function makeImportStatus(overrides: Partial<ImportStatus> = {}): ImportStatus {
  return {
    enabled: true, stored: { plays: 4321, firstPlayedAt: '2020-01-01T00:00:00Z', lastPlayedAt: '2026-10-29T08:00:00Z', sources: { lastfm: 4321 } },
    state: 'completed', complete: true, stalled: false, activity: 'idle', percent: 100, importedScrobbles: 4321,
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
  getConnection: async () => ({ status: 'signed_out' }),
  getLovedTracks: async () => {
    throw new NotConnectedError();
  },
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
  getGenre: async () => {
    throw new NotConnectedError();
  },
  signInUrl: () => '/api/auth/lastfm',
  signOut: async () => {},
  setTheme: async () => {},
  deleteAccount: async () => {
    throw new NotConnectedError();
  },
  history: noHistoryApi,
  sources: noSourcesApi,
  auth: noAuthApi,
};

export function makeSession(overrides: Partial<Extract<SessionInfo, { signedIn: true }>> = {}): SessionInfo {
  return { signedIn: true, user: { displayName: 'test-user', timezone: 'Europe/London' }, methods: { passkeys: 1, recoveryCodes: 10, lastfm: true }, ...overrides };
}

export function makePasskey(i: number, overrides: Partial<Passkey> = {}): Passkey {
  return { id: i, nickname: `Device ${i}`, createdAt: '2026-11-01T10:00:00Z', lastUsedAt: null, transports: ['internal'], ...overrides };
}

export function makeBrowserSession(i: number, overrides: Partial<BrowserSession> = {}): BrowserSession {
  return {
    id: i, current: i === 1, createdAt: '2026-11-01T10:00:00Z', lastSeenAt: '2026-11-04T09:00:00Z', ipAddress: '203.0.113.5',
    userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 19_0 like Mac OS X) AppleWebKit/605.1.15 Safari/605.1.15', ...overrides,
  };
}

/** Runout's own sign-in, switched on, with in-memory passkeys, codes and sessions. */
export function fakeAuthApi(initial: { session?: SessionInfo | null; passkeys?: Passkey[]; sessions?: BrowserSession[] } = {}): AuthApi & { calls: string[] } {
  const calls: string[] = [];
  let session: SessionInfo | null = initial.session === undefined ? makeSession() : initial.session;
  let passkeys = initial.passkeys ?? [makePasskey(1)];
  let sessions = initial.sessions ?? [makeBrowserSession(1), makeBrowserSession(2)];
  const codes = () => Array.from({ length: 10 }, (_, i) => `code${i}-abcde`);
  const signedIn = (): SessionInfo => makeSession({ methods: { passkeys: passkeys.length, recoveryCodes: 9, lastfm: true } });
  return {
    calls,
    status: async () => session,
    passkeys: async () => passkeys,
    addPasskey: async (nickname) => {
      calls.push(`addPasskey:${nickname}`);
      const first = passkeys.length === 0;
      const passkey = makePasskey(passkeys.length + 1, { nickname: nickname || null });
      passkeys = [...passkeys, passkey];
      // The session's methods follow, as GET /api/session would report them.
      if (session?.signedIn) session = { ...session, methods: { ...session.methods, passkeys: passkeys.length, recoveryCodes: first ? 10 : session.methods.recoveryCodes } };
      return { passkey, recoveryCodes: first ? codes() : null };
    },
    removePasskey: async (id) => {
      calls.push(`removePasskey:${id}`);
      passkeys = passkeys.filter((p) => p.id !== id);
    },
    regenerateRecoveryCodes: async () => {
      calls.push('regenerateRecoveryCodes');
      return codes();
    },
    signInWithPasskey: async () => {
      calls.push('signInWithPasskey');
      session = signedIn();
      return session;
    },
    signInWithRecoveryCode: async (code) => {
      calls.push(`signInWithRecoveryCode:${code}`);
      session = makeSession({ methods: { passkeys: 0, recoveryCodes: 9, lastfm: true } });
      return session;
    },
    sessions: async () => sessions,
    revokeSession: async (id) => {
      calls.push(`revokeSession:${id}`);
      sessions = sessions.filter((s) => s.id !== id);
    },
  };
}

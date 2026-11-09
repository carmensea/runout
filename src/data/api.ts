import { serializePeriod, type Period } from '../lib/period';
import { createPasskey, getPasskey } from '../lib/webauthn';
import type {
  BrowserSession, CalendarDays, ConnectionState, GenreDetail, HistoryCalendar, ImportStatus, LovedLibrary, OnThisDay, OverviewData, Passkey, PlaysPage, ReviewDecisionName, ListeningReviewItem, ListeningSources, ReviewDecisionResult, ReviewItem, ReviewQueue, SearchResults, SessionInfo, SyncHealth, Memory, MemoryInput, MemoriesResponse, SongDetail,
} from './types';

/**
 * Everything the UI needs from the backend. The Last.fm import, storage and aggregation live
 * server-side (see HANDOFF.md "Data and import"); the UI never talks to Last.fm directly.
 */
export interface RunoutApi {
  getConnection(signal?: AbortSignal): Promise<ConnectionState>;
  getOverview(period: Period, signal?: AbortSignal): Promise<OverviewData>;
  search(query: string, signal?: AbortSignal): Promise<SearchResults>;
  /** Time Machine: the whole history, plays per day, the plays themselves, and "On this day". */
  getCalendar(signal?: AbortSignal): Promise<HistoryCalendar>;
  getCalendarDays(from: string, to: string, signal?: AbortSignal): Promise<CalendarDays>;
  getPlays(period: Period, cursor: string | null, signal?: AbortSignal): Promise<PlaysPage>;
  getOnThisDay(date: string, signal?: AbortSignal): Promise<OnThisDay>;
  /** One genre in a period (GET /api/genres/:slug). */
  getGenre(slug: string, period: Period, signal?: AbortSignal): Promise<GenreDetail>;
  /** Loved songs with their listening (GET /api/loved-tracks). */
  getLovedTracks(signal?: AbortSignal): Promise<LovedLibrary>;
  /** One song with the signed-in person's listening and memories (GET /api/tracks/:key). */
  getSong(key: string, signal?: AbortSignal): Promise<SongDetail>;
  /** The music diary: memories about songs, private to their author. */
  memories: MemoriesApi;
  /** Where to send the browser to sign in with Last.fm, or null when no server is configured. */
  signInUrl(): string | null;
  signOut(): Promise<void>;
  /** Erases the signed-in account and its data. `confirmUsername` must match the Last.fm username. */
  /** Where Runout's access can also be removed on the services' side; null for a service never connected. */
  deleteAccount(confirmName: string): Promise<{ revokeAccessUrl: string | null; spotifyAppsUrl: string | null }>;
  /** Saves the theme on the account, so it follows the owner between browsers and sign-ins. */
  setTheme(theme: string): Promise<void>;
  /** Changes how the account is addressed. Trimmed; empty or over 80 characters is refused. */
  setDisplayName(name: string): Promise<void>;
  /** Listening-history import, sync and review controls (Settings). */
  history: HistoryApi;
  /** Listening sources: Last.fm as the archive, Spotify connected directly (Settings). */
  sources: SourcesApi;
  /** Runout's own sign-in: passkeys, recovery codes, other browsers (Settings, signed-out screen). */
  auth: AuthApi;
}

export interface MemoriesApi {
  /** Every memory of the signed-in person, newest written first; `q` matches the text, the label, the song or its artist. */
  list(q: string, signal?: AbortSignal): Promise<MemoriesResponse>;
  create(song: string, input: MemoryInput): Promise<Memory>;
  update(id: number, input: MemoryInput): Promise<Memory>;
  remove(id: number): Promise<void>;
}

export interface AuthApi {
  /** Who is signed in and how they can sign in; null while Runout's own sign-in is switched off on the server. */
  status(signal?: AbortSignal): Promise<SessionInfo | null>;
  passkeys(signal?: AbortSignal): Promise<Passkey[]>;
  /** Enrols a passkey through the browser. The first one comes with recovery codes, shown once. */
  addPasskey(nickname: string): Promise<{ passkey: Passkey; recoveryCodes: string[] | null }>;
  /** ApiError code `last_passkey`: the only passkey can't go while there are no recovery codes. */
  removePasskey(id: number): Promise<void>;
  regenerateRecoveryCodes(): Promise<string[]>;
  signInWithPasskey(): Promise<SessionInfo>;
  signInWithRecoveryCode(code: string): Promise<SessionInfo>;
  sessions(signal?: AbortSignal): Promise<BrowserSession[]>;
  revokeSession(id: number): Promise<void>;
  /**
   * Where to send the browser for Google (a full page navigation): to sign in, or to link Google to
   * the signed-in account, returning to `back` afterwards. Null when no server is configured.
   */
  googleUrl(intent: 'sign_in' | 'link', back?: 'overview' | 'settings' | 'welcome'): string | null;
  /** ApiError codes: `confirm_first` (sign in again first), `last_method` (the only way in stays). */
  unlinkGoogle(): Promise<void>;
}

export interface SourcesApi {
  status(signal?: AbortSignal): Promise<ListeningSources>;
  /** Where to send the browser to connect Spotify, or null when no server is configured. */
  connectSpotifyUrl(): string | null;
  /** Forgets the Spotify credentials. Plays already stored stay. */
  disconnectSpotify(): Promise<ListeningSources>;
  /** Queues a poll now. ApiError codes: ingestion_disabled, paused, not_connected, too_soon. */
  syncSpotify(): Promise<void>;
  pauseSpotify(): Promise<ListeningSources>;
  resumeSpotify(): Promise<ListeningSources>;
  reviews(signal?: AbortSignal): Promise<ListeningReviewItem[]>;
  /** Same play as a stored one (`scrobbleId`), or a separate play. Returns what is left to review. */
  decide(id: number, decision: { link: number } | 'separate'): Promise<ListeningReviewItem[]>;
  /** Verifies the token with ListenBrainz once and binds the username; the token is not kept. ApiError codes: invalid_token, account_taken, ingestion_disabled, rate_limited, unavailable. */
  connectListenbrainz(token: string): Promise<ListeningSources>;
  /** Forgets the connection. Plays already stored stay. */
  disconnectListenbrainz(): Promise<ListeningSources>;
  /** Reads ListenBrainz now and starts (or continues) the full-history import. ApiError codes: ingestion_disabled, not_connected, too_soon. */
  backfillListenbrainz(): Promise<void>;
}

export interface HistoryApi {
  importStatus(signal?: AbortSignal): Promise<ImportStatus>;
  startImport(): Promise<void>;
  pauseImport(): Promise<void>;
  resumeImport(): Promise<void>;
  /** Only with the owner's confirmation; imported scrobbles are kept. */
  cancelImport(): Promise<void>;
  retryPeriod(id: number): Promise<void>;
  /** Unchanged status costs a 304: the last answer is kept and reused. */
  syncHealth(signal?: AbortSignal): Promise<SyncHealth>;
  refreshSync(): Promise<void>;
  pauseSync(): Promise<void>;
  resumeSync(): Promise<void>;
  reviews(signal?: AbortSignal): Promise<ReviewQueue>;
  /**
   * Decides one review item. Throws ReviewChangedError when the item changed since it was loaded
   * (nothing was decided). Repeating a decision already made answers `result: 'already'`.
   */
  decide(item: Pick<ReviewItem, 'kind' | 'id' | 'version'>, decision: ReviewDecisionName,
         options?: { confirm?: boolean; pairs?: Array<[number, number]>; note?: string }): Promise<ReviewDecisionResult>;
}

export class NotConnectedError extends Error {
  constructor() {
    super('No Last.fm account is connected.');
    this.name = 'NotConnectedError';
  }
}

export class ApiError extends Error {
  /** The server's error code (`storage_disabled`, `busy`, `too_soon`...), when it sent one. */
  constructor(readonly status: number, message: string, readonly code: string | null = null, readonly body: unknown = null) {
    super(message);
    this.name = 'ApiError';
  }
}

/** HTTP 501: the server doesn't provide this yet (analytics arrive in a later version). */
export class NotAvailableError extends Error {
  constructor() {
    super('Not available in this version of Runout yet.');
    this.name = 'NotAvailableError';
  }
}

/** A review item changed after it was loaded; nothing was decided. `item` is how it is now. */
export class ReviewChangedError extends Error {
  constructor(readonly item: ReviewItem | null) {
    super('This item changed while it was open.');
    this.name = 'ReviewChangedError';
  }
}

const WRITE_HEADERS = { Accept: 'application/json', 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' };

/** HTTP client for the Runout API. */
export function createHttpApi(baseUrl: string): RunoutApi {
  const root = baseUrl.replace(/\/+$/, '');

  async function get<T>(path: string, params: Record<string, string>, signal?: AbortSignal): Promise<T> {
    const qs = new URLSearchParams(params).toString();
    const res = await fetch(`${root}${path}${qs ? `?${qs}` : ''}`, {
      signal,
      credentials: 'include',
      headers: { Accept: 'application/json' },
    });
    if (res.status === 409) throw new NotConnectedError();
    if (res.status === 501) throw new NotAvailableError();
    if (!res.ok) throw new ApiError(res.status, `Request to ${path} failed with HTTP ${res.status}.`);
    return (await res.json()) as T;
  }

  async function post<T>(path: string, body: object = {}): Promise<T> {
    const res = await fetch(`${root}${path}`, { method: 'POST', credentials: 'include', headers: WRITE_HEADERS, body: JSON.stringify(body) });
    const data = (await res.json().catch(() => null)) as (T & { error?: string }) | null;
    if (!res.ok) throw new ApiError(res.status, `Request to ${path} failed with HTTP ${res.status}.`, data?.error ?? null, data);
    return data as T;
  }

  async function del(path: string): Promise<void> {
    const res = await fetch(`${root}${path}`, { method: 'DELETE', credentials: 'include', headers: WRITE_HEADERS });
    const data = (await res.json().catch(() => null)) as { error?: string } | null;
    if (!res.ok) throw new ApiError(res.status, `Request to ${path} failed with HTTP ${res.status}.`, data?.error ?? null, data);
  }

  const auth: AuthApi = {
    status: async (signal) => {
      try {
        return await get<SessionInfo>('/session', {}, signal);
      } catch (e) {
        // 404: RUNOUT_PASSKEYS_ENABLED is off on the server.
        if (e instanceof ApiError && e.status === 404) return null;
        throw e;
      }
    },
    passkeys: async (signal) => (await get<{ passkeys: Passkey[] }>('/passkeys', {}, signal)).passkeys,
    addPasskey: async (nickname) => {
      const options = await post<PublicKeyCredentialCreationOptionsJSON>('/passkeys/options');
      const credential = await createPasskey(options);
      return post('/passkeys', { credential, nickname });
    },
    removePasskey: (id) => del(`/passkeys/${id}`),
    regenerateRecoveryCodes: async () => (await post<{ recoveryCodes: string[] }>('/recovery-codes')).recoveryCodes,
    signInWithPasskey: async () => {
      const options = await post<PublicKeyCredentialRequestOptionsJSON>('/auth/passkey/options');
      const credential = await getPasskey(options);
      return post<SessionInfo>('/auth/passkey', { credential });
    },
    signInWithRecoveryCode: (code) => post<SessionInfo>('/auth/recovery', { code }),
    sessions: async (signal) => (await get<{ sessions: BrowserSession[] }>('/sessions', {}, signal)).sessions,
    revokeSession: (id) => del(`/sessions/${id}`),
    googleUrl: (intent, back = 'overview') => `${root}/auth/google?${new URLSearchParams({ intent, return: back })}`,
    unlinkGoogle: () => del('/auth/google'),
  };

  // GET /sync answers 304 while nothing changed; the previous answer is reused.
  let syncCache: { etag: string; data: SyncHealth } | null = null;
  async function syncHealth(signal?: AbortSignal): Promise<SyncHealth> {
    const res = await fetch(`${root}/sync`, {
      signal,
      credentials: 'include',
      headers: { Accept: 'application/json', ...(syncCache ? { 'If-None-Match': syncCache.etag } : {}) },
    });
    if (res.status === 304 && syncCache) return syncCache.data;
    if (!res.ok) throw new ApiError(res.status, `Request to /sync failed with HTTP ${res.status}.`);
    const data = (await res.json()) as SyncHealth;
    const etag = res.headers.get('ETag');
    syncCache = etag ? { etag, data } : null;
    return data;
  }

  const history: HistoryApi = {
    importStatus: (signal) => get<ImportStatus>('/import', {}, signal),
    startImport: async () => { await post('/import'); },
    pauseImport: async () => { await post('/import/pause'); },
    resumeImport: async () => { await post('/import/resume'); },
    cancelImport: async () => { await post('/import/cancel', { confirm: true }); },
    retryPeriod: async (id) => { await post(`/import/periods/${id}/retry`); },
    syncHealth,
    refreshSync: async () => { await post('/sync/refresh'); },
    pauseSync: async () => { await post('/sync/pause'); },
    resumeSync: async () => { await post('/sync/resume'); },
    reviews: (signal) => get<ReviewQueue>('/reviews', {}, signal),
    decide: async (item, decision, options = {}) => {
      try {
        return await post<ReviewDecisionResult>(`/reviews/${item.kind}/${item.id}/${decision}`, { version: item.version, ...options });
      } catch (e) {
        if (e instanceof ApiError && e.code === 'changed') throw new ReviewChangedError((e.body as { item: ReviewItem | null }).item);
        throw e;
      }
    },
  };

  async function patchAccount(body: Record<string, string>, what: string) {
    const res = await fetch(`${root}/account`, { method: 'PATCH', credentials: 'include', headers: WRITE_HEADERS, body: JSON.stringify(body) });
    if (!res.ok) throw new ApiError(res.status, `${what} failed with HTTP ${res.status}.`);
  }

  return {
    getConnection: (signal) => get<ConnectionState>('/connection', {}, signal),
    getOverview: (period, signal) => get<OverviewData>('/overview', { period: serializePeriod(period) }, signal),
    search: (query, signal) => get<SearchResults>('/search', { q: query }, signal),
    getCalendar: (signal) => get<HistoryCalendar>('/calendar', {}, signal),
    getCalendarDays: (from, to, signal) => get<CalendarDays>('/calendar', { from, to }, signal),
    getPlays: (period, cursor, signal) => get<PlaysPage>('/plays', { period: serializePeriod(period), ...(cursor ? { cursor } : {}) }, signal),
    getOnThisDay: (date, signal) => get<OnThisDay>('/on-this-day', { date }, signal),
    getGenre: (slug, period, signal) => get<GenreDetail>(`/genres/${encodeURIComponent(slug)}`, { period: serializePeriod(period) }, signal),
    getLovedTracks: (signal) => get<LovedLibrary>('/loved-tracks', {}, signal),
    getSong: (key, signal) => get<SongDetail>(`/tracks/${encodeURIComponent(key)}`, {}, signal),
    memories: {
      list: (q, signal) => get<MemoriesResponse>('/memories', q ? { q } : {}, signal),
      create: (song, input) => post<Memory>('/memories', { song, ...input }),
      update: async (id, input) => {
        const res = await fetch(`${root}/memories/${id}`, { method: 'PATCH', credentials: 'include', headers: WRITE_HEADERS, body: JSON.stringify(input) });
        const data = (await res.json().catch(() => null)) as (Memory & { error?: string }) | null;
        if (!res.ok) throw new ApiError(res.status, `Request to /memories/${id} failed with HTTP ${res.status}.`, data?.error ?? null, data);
        return data as Memory;
      },
      remove: async (id) => {
        const res = await fetch(`${root}/memories/${id}`, { method: 'DELETE', credentials: 'include', headers: WRITE_HEADERS });
        if (!res.ok) throw new ApiError(res.status, `Request to /memories/${id} failed with HTTP ${res.status}.`, null, null);
      },
    },
    signInUrl: () => {
      const tz = Intl.DateTimeFormat().resolvedOptions().timeZone;
      return `${root}/auth/lastfm${tz ? `?${new URLSearchParams({ tz })}` : ''}`;
    },
    signOut: async () => {
      const res = await fetch(`${root}/session`, {
        method: 'DELETE',
        credentials: 'include',
        headers: { Accept: 'application/json', 'X-Requested-With': 'XMLHttpRequest' },
      });
      if (!res.ok && res.status !== 401) throw new ApiError(res.status, `Sign-out failed with HTTP ${res.status}.`);
    },
    setTheme: (theme) => patchAccount({ theme }, 'Saving the theme'),
    setDisplayName: (displayName) => patchAccount({ displayName }, 'Saving your name'),
    deleteAccount: async (confirmName) => {
      const res = await fetch(`${root}/account`, {
        method: 'DELETE',
        credentials: 'include',
        headers: { Accept: 'application/json', 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' },
        body: JSON.stringify({ confirm_name: confirmName }),
      });
      if (!res.ok) throw new ApiError(res.status, `Account deletion failed with HTTP ${res.status}.`);
      return (await res.json()) as { revokeAccessUrl: string | null; spotifyAppsUrl: string | null };
    },
    history,
    auth,
    sources: {
      status: (signal) => get<ListeningSources>('/listening-sources', {}, signal),
      connectSpotifyUrl: () => `${root}/auth/spotify`,
      disconnectSpotify: () => post<ListeningSources>('/listening-sources/spotify/disconnect'),
      syncSpotify: async () => { await post('/listening-sources/spotify/sync'); },
      pauseSpotify: () => post<ListeningSources>('/listening-sources/spotify/pause'),
      resumeSpotify: () => post<ListeningSources>('/listening-sources/spotify/resume'),
      reviews: async (signal) => (await get<{ items: ListeningReviewItem[] }>('/listening-sources/reviews', {}, signal)).items,
      decide: async (id, decision) => {
        const path = decision === 'separate' ? `/listening-sources/reviews/${id}/separate` : `/listening-sources/reviews/${id}/link`;
        const body = decision === 'separate' ? {} : { scrobble_id: decision.link };
        return (await post<{ items: ListeningReviewItem[] }>(path, body)).items;
      },
      connectListenbrainz: (token) => post<ListeningSources>('/listening-sources/listenbrainz', { token }),
      disconnectListenbrainz: () => post<ListeningSources>('/listening-sources/listenbrainz/disconnect'),
      backfillListenbrainz: async () => { await post('/listening-sources/listenbrainz/backfill'); },
    },
  };
}

const notConnected = async (): Promise<never> => {
  throw new NotConnectedError();
};

/** History controls when there is no server or no account: every call says so. */
export const noHistoryApi: HistoryApi = {
  importStatus: notConnected, startImport: notConnected, pauseImport: notConnected, resumeImport: notConnected,
  cancelImport: notConnected, retryPeriod: notConnected, syncHealth: notConnected, refreshSync: notConnected,
  pauseSync: notConnected, resumeSync: notConnected, reviews: notConnected, decide: notConnected,
};

/** Listening sources when there is no server or no account. */
export const noSourcesApi: SourcesApi = {
  status: notConnected,
  connectSpotifyUrl: () => null,
  disconnectSpotify: notConnected,
  syncSpotify: notConnected,
  pauseSpotify: notConnected,
  resumeSpotify: notConnected,
  reviews: notConnected,
  decide: notConnected,
  connectListenbrainz: notConnected,
  disconnectListenbrainz: notConnected,
  backfillListenbrainz: notConnected,
};

/** Runout's own sign-in when there is no server: switched off, every call says so. */
export const noAuthApi: AuthApi = {
  status: async () => null,
  passkeys: notConnected,
  addPasskey: notConnected,
  removePasskey: notConnected,
  regenerateRecoveryCodes: notConnected,
  signInWithPasskey: notConnected,
  signInWithRecoveryCode: notConnected,
  sessions: notConnected,
  googleUrl: () => null,
  unlinkGoogle: notConnected,
  revokeSession: notConnected,
};

/**
 * Used when no API is configured. Reports the true state: nothing is connected and
 * no listening data exists. It never fabricates data.
 */
export const disconnectedApi: RunoutApi = {
  getConnection: async () => ({ status: 'signed_out' }),
  getOverview: async () => {
    throw new NotConnectedError();
  },
  search: notConnected,
  getCalendar: notConnected,
  getCalendarDays: notConnected,
  getPlays: notConnected,
  getOnThisDay: notConnected,
  getGenre: notConnected,
  getLovedTracks: notConnected,
  getSong: notConnected,
  memories: { list: notConnected, create: notConnected, update: notConnected, remove: notConnected },
  signInUrl: () => null,
  signOut: async () => {},
  setTheme: async () => {},
  setDisplayName: async () => {},
  deleteAccount: async () => {
    throw new NotConnectedError();
  },
  history: noHistoryApi,
  sources: noSourcesApi,
  auth: noAuthApi,
};

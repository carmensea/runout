import { serializePeriod, type Period } from '../lib/period';
import type { ConnectionState, OverviewData, SearchResults } from './types';

/**
 * Everything the UI needs from the backend. The Last.fm import, storage and aggregation live
 * server-side (see HANDOFF.md "Data and import"); the UI never talks to Last.fm directly.
 */
export interface RunoutApi {
  getConnection(signal?: AbortSignal): Promise<ConnectionState>;
  getOverview(period: Period, signal?: AbortSignal): Promise<OverviewData>;
  search(query: string, signal?: AbortSignal): Promise<SearchResults>;
  /** Where to send the browser to sign in with Last.fm, or null when no server is configured. */
  signInUrl(): string | null;
  signOut(): Promise<void>;
  /** Erases the signed-in account and its data. `confirmUsername` must match the Last.fm username. */
  deleteAccount(confirmUsername: string): Promise<{ revokeAccessUrl: string }>;
}

export class NotConnectedError extends Error {
  constructor() {
    super('No Last.fm account is connected.');
    this.name = 'NotConnectedError';
  }
}

export class ApiError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
    this.name = 'ApiError';
  }
}

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
    if (!res.ok) throw new ApiError(res.status, `Request to ${path} failed with HTTP ${res.status}.`);
    return (await res.json()) as T;
  }

  return {
    getConnection: (signal) => get<ConnectionState>('/connection', {}, signal),
    getOverview: (period, signal) => get<OverviewData>('/overview', { period: serializePeriod(period) }, signal),
    search: (query, signal) => get<SearchResults>('/search', { q: query }, signal),
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
    deleteAccount: async (confirmUsername) => {
      const res = await fetch(`${root}/account`, {
        method: 'DELETE',
        credentials: 'include',
        headers: { Accept: 'application/json', 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' },
        body: JSON.stringify({ confirm_username: confirmUsername }),
      });
      if (!res.ok) throw new ApiError(res.status, `Account deletion failed with HTTP ${res.status}.`);
      return (await res.json()) as { revokeAccessUrl: string };
    },
  };
}

/**
 * Used when no API is configured. Reports the true state: nothing is connected and
 * no listening data exists. It never fabricates data.
 */
export const disconnectedApi: RunoutApi = {
  getConnection: async () => ({ status: 'none' }),
  getOverview: async () => {
    throw new NotConnectedError();
  },
  search: async () => {
    throw new NotConnectedError();
  },
  signInUrl: () => null,
  signOut: async () => {},
  deleteAccount: async () => {
    throw new NotConnectedError();
  },
};

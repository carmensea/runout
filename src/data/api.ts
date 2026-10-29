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
};

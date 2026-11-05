import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import { browserTimeZone } from '../lib/dates';
import { realFormatter, specimenFormatter, type Formatter } from '../lib/format';
import { createHttpApi, disconnectedApi, type RunoutApi } from './api';
import type { ConnectionState, SessionInfo } from './types';
import { useAsync, type AsyncState } from './useAsync';

interface AppData {
  api: RunoutApi;
  /** True only in development with ?specimen: layout review with placeholder shapes. */
  specimen: boolean;
  fmt: Formatter;
  connection: AsyncState<ConnectionState> & { retry: () => void };
  /** Runout's own sign-in; `data` is null while the server has it switched off. */
  auth: AsyncState<SessionInfo | null> & { retry: () => void };
  /** User timezone setting once connected, otherwise the browser's. */
  timeZone: string;
}

const AppDataContext = createContext<AppData | null>(null);

const SPECIMEN_KEY = 'runout:specimen';

function wantsSpecimen(): boolean {
  if (!import.meta.env.DEV) return false;
  const params = new URLSearchParams(window.location.search);
  try {
    if (params.has('specimen')) sessionStorage.setItem(SPECIMEN_KEY, params.get('specimen') === 'off' ? '0' : '1');
    return sessionStorage.getItem(SPECIMEN_KEY) === '1';
  } catch {
    return params.has('specimen') && params.get('specimen') !== 'off';
  }
}

function useApi(): { api: RunoutApi | null; specimen: boolean } {
  const [specimen] = useState(wantsSpecimen);
  const [specimenApi, setSpecimenApi] = useState<RunoutApi | null>(null);

  useEffect(() => {
    if (!specimen || !import.meta.env.DEV) return;
    let live = true;
    import('./fixtures/specimenApi').then((m) => live && setSpecimenApi(m.specimenApi));
    return () => {
      live = false;
    };
  }, [specimen]);

  if (specimen) return { api: specimenApi, specimen };
  const baseUrl = import.meta.env.VITE_RUNOUT_API_URL as string | undefined;
  return { api: baseUrl ? createHttpApi(baseUrl) : disconnectedApi, specimen };
}

export function AppDataProvider({ children, api: injected }: { children: ReactNode; api?: RunoutApi }) {
  const resolved = useApi();
  const api = injected ?? resolved.api;
  const specimen = !injected && resolved.specimen;
  const connection = useAsync(api ? `connection:${specimen}` : null, (signal) => api!.getConnection(signal));
  const auth = useAsync(api ? `auth:${specimen}` : null, (signal) => api!.auth.status(signal));

  const value = useMemo<AppData | null>(() => {
    if (!api) return null;
    const timeZone = connection.status === 'success' && connection.data.status !== 'none'
      ? connection.data.timezone
      : browserTimeZone();
    return { api, specimen, fmt: specimen ? specimenFormatter : realFormatter, connection, auth, timeZone };
  }, [api, specimen, connection, auth]);

  if (!value) return null;
  return <AppDataContext.Provider value={value}>{children}</AppDataContext.Provider>;
}

export function useAppData(): AppData {
  const ctx = useContext(AppDataContext);
  if (!ctx) throw new Error('useAppData must be used inside <AppDataProvider>');
  return ctx;
}

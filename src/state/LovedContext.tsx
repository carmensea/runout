import { createContext, useContext, useMemo, type ReactNode } from 'react';
import { useAppData } from '../data/AppDataContext';
import type { LovedLibrary } from '../data/types';
import { useAsync, type AsyncState } from '../data/useAsync';

interface LovedState {
  library: AsyncState<LovedLibrary> & { retry: () => void };
  /** Identity keys (`track.id`) of songs loved now, for hearts beside tracks anywhere. */
  isLoved(trackKey: string): boolean;
}

const LovedContext = createContext<LovedState | null>(null);

/** Loads the loved library once per signed-in session; hearts and the Loved page read it. */
export function LovedProvider({ children }: { children: ReactNode }) {
  const { api, connection } = useAppData();
  const connected = connection.status === 'success' && connection.data.status !== 'none';
  const library = useAsync(connected ? 'loved' : null, (signal) => api.getLovedTracks(signal));
  const keys = useMemo(
    () => new Set(library.status === 'success' ? library.data.tracks.filter((t) => !t.unlovedAt).map((t) => t.track.id) : []),
    [library],
  );
  const value = useMemo<LovedState>(() => ({ library, isLoved: (key) => keys.has(key) }), [library, keys]);
  return <LovedContext.Provider value={value}>{children}</LovedContext.Provider>;
}

export function useLoved(): LovedState {
  const ctx = useContext(LovedContext);
  if (!ctx) throw new Error('useLoved must be used inside <LovedProvider>');
  return ctx;
}

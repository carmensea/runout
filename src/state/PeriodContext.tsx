import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useAppData } from '../data/AppDataContext';
import { todayIn } from '../lib/dates';
import { defaultComparison, parsePeriod, serializePeriod, type Period } from '../lib/period';

interface PeriodState {
  current: Period;
  compare: Period | null;
  /** Today in the user's timezone, YYYY-MM-DD. */
  today: string;
  setCurrent(p: Period): void;
  setCompare(p: Period | null): void;
  /** Sets the period and comparison together in one URL update. */
  setBoth(p: Period, vs: Period | null): void;
  /** Appends the current period query to an in-app path so navigation keeps the selection. */
  withPeriod(path: string): string;
}

const STORAGE_KEY = 'runout:period';
const PeriodContext = createContext<PeriodState | null>(null);

function readStored(): { period: string | null; vs: string | null } {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (raw) return JSON.parse(raw) as { period: string | null; vs: string | null };
  } catch {
    // Storage unavailable or corrupt: fall back to defaults.
  }
  return { period: null, vs: null };
}

function writeStored(period: string, vs: string | null) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ period, vs }));
  } catch {
    // Persisting is a convenience; the URL remains the source of truth.
  }
}

/**
 * Period selection lives in the URL (`?period=year:2014&vs=year:2011`), mirrored to
 * localStorage so a fresh visit resumes the last selection. URL wins.
 */
export function PeriodProvider({ children }: { children: ReactNode }) {
  const { timeZone } = useAppData();
  const [params, setParams] = useSearchParams();
  const today = todayIn(timeZone);

  const urlPeriod = parsePeriod(params.get('period'));
  const urlVs = parsePeriod(params.get('vs'));
  const hasUrlPeriod = urlPeriod !== null;

  const [stored] = useState(readStored);
  const current: Period = urlPeriod ?? parsePeriod(stored.period) ?? { kind: 'all' };
  const compare: Period | null = hasUrlPeriod ? urlVs : parsePeriod(stored.vs);
  const currentKey = serializePeriod(current);
  const compareKey = compare ? serializePeriod(compare) : null;

  // Put the resolved selection into the URL when it arrived from storage or defaults.
  useEffect(() => {
    if (hasUrlPeriod) {
      writeStored(currentKey, compareKey);
      return;
    }
    setParams((prev) => {
      const next = new URLSearchParams(prev);
      next.set('period', currentKey);
      if (compareKey) next.set('vs', compareKey);
      return next;
    }, { replace: true });
  }, [hasUrlPeriod, currentKey, compareKey, setParams]);

  const update = useCallback((period: Period, vs: Period | null) => {
    setParams((prev) => {
      const next = new URLSearchParams(prev);
      next.set('period', serializePeriod(period));
      if (vs && period.kind !== 'all') next.set('vs', serializePeriod(vs));
      else next.delete('vs');
      return next;
    }, { replace: true });
  }, [setParams]);

  const value = useMemo<PeriodState>(() => ({
    current,
    compare,
    today,
    // A comparison follows the new period's unit: keep it when the kind is unchanged, otherwise
    // move it to the preceding period of the new kind.
    setCurrent: (p) => update(p, !compare ? null : p.kind === current.kind ? compare : defaultComparison(p, today)),
    setCompare: (p) => update(current, p),
    setBoth: (p, vs) => update(p, vs),
    withPeriod: (path) => {
      const [beforeHash, hash] = path.split('#');
      const [base, query] = (beforeHash ?? '').split('?');
      const q = new URLSearchParams(query);
      // An explicit period in the path (e.g. a Time Machine deep link) takes precedence.
      if (!q.has('period')) {
        q.set('period', currentKey);
        if (compareKey) q.set('vs', compareKey);
      }
      return `${base}?${q.toString()}${hash ? `#${hash}` : ''}`;
    },
    // `current` and `compare` are identified by their serialised keys.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }), [currentKey, compareKey, today, update]);

  return <PeriodContext.Provider value={value}>{children}</PeriodContext.Provider>;
}

export function usePeriod(): PeriodState {
  const ctx = useContext(PeriodContext);
  if (!ctx) throw new Error('usePeriod must be used inside <PeriodProvider>');
  return ctx;
}

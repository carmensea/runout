import { useCallback, useEffect, useRef, useState } from 'react';
import type { AsyncState } from '../data/useAsync';

/**
 * Loads now, then again after `intervalFor(latest data)` milliseconds (null: don't poll), so the
 * pace can follow what the data says, faster while work is running. A hidden tab schedules
 * nothing; becoming visible again loads at once. `refresh` loads immediately, for after an action.
 * A failed reload keeps showing the last data.
 */
export function usePolling<T>(
  load: (signal: AbortSignal) => Promise<T>,
  intervalFor: (data: T | null) => number | null,
): AsyncState<T> & { refresh: () => void } {
  const [state, setState] = useState<AsyncState<T>>({ status: 'loading' });
  const [tick, setTick] = useState(0);
  const loadRef = useRef(load);
  const intervalRef = useRef(intervalFor);
  useEffect(() => {
    loadRef.current = load;
    intervalRef.current = intervalFor;
  });
  const refresh = useCallback(() => setTick((t) => t + 1), []);

  useEffect(() => {
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const scheduleAfter = (data: T | null) => {
      const ms = intervalRef.current(data);
      if (ms !== null && document.visibilityState !== 'hidden') timer = setTimeout(() => setTick((t) => t + 1), ms);
    };
    loadRef.current(controller.signal).then(
      (data) => {
        if (controller.signal.aborted) return;
        setState({ status: 'success', data });
        scheduleAfter(data);
      },
      (error: unknown) => {
        if (controller.signal.aborted) return;
        setState((prev) => (prev.status === 'success' ? prev : { status: 'error', error: error instanceof Error ? error : new Error(String(error)) }));
        scheduleAfter(null);
      },
    );
    const onVisibility = () => {
      if (document.visibilityState === 'hidden') {
        clearTimeout(timer);
      } else {
        setTick((t) => t + 1);
      }
    };
    document.addEventListener('visibilitychange', onVisibility);
    return () => {
      controller.abort();
      clearTimeout(timer);
      document.removeEventListener('visibilitychange', onVisibility);
    };
  }, [tick]);

  return { ...state, refresh };
}

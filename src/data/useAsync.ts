import { useCallback, useEffect, useState } from 'react';

export type AsyncState<T> =
  | { status: 'loading' }
  | { status: 'success'; data: T }
  | { status: 'error'; error: Error };

/**
 * Runs `load` whenever `key` changes, aborting the previous request.
 * `retry` re-runs the current request.
 */
export function useAsync<T>(key: string | null, load: (signal: AbortSignal) => Promise<T>): AsyncState<T> & { retry: () => void } {
  const [state, setState] = useState<{ key: string | null; attempt: number; value: AsyncState<T> }>({
    key, attempt: 0, value: { status: 'loading' },
  });
  const [attempt, setAttempt] = useState(0);

  // Reset to loading synchronously when the request identity changes.
  if (state.key !== key || state.attempt !== attempt) {
    setState({ key, attempt, value: { status: 'loading' } });
  }

  useEffect(() => {
    if (key === null) return;
    const controller = new AbortController();
    load(controller.signal).then(
      (data) => !controller.signal.aborted && setState({ key, attempt, value: { status: 'success', data } }),
      (error: unknown) => {
        if (controller.signal.aborted) return;
        setState({ key, attempt, value: { status: 'error', error: error instanceof Error ? error : new Error(String(error)) } });
      },
    );
    return () => controller.abort();
    // `load` is intentionally keyed by `key`; callers pass a fresh closure each render.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, attempt]);

  const retry = useCallback(() => setAttempt((a) => a + 1), []);
  return { ...state.value, retry };
}

import { useAppData } from '../../data/AppDataContext';
import { useAsync } from '../../data/useAsync';
import { serializePeriod, type Period } from '../../lib/period';

/** Loads the overview for the current period and, independently, for the comparison period. */
export function useOverview(current: Period, compare: Period | null, enabled: boolean) {
  const { api } = useAppData();
  const main = useAsync(enabled ? `overview:${serializePeriod(current)}` : null, (signal) => api.getOverview(current, signal));
  const vs = useAsync(enabled && compare ? `overview:${serializePeriod(compare)}` : null, (signal) => api.getOverview(compare!, signal));
  return { main, compare: compare ? vs : null };
}

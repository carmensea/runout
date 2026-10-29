import type { OverviewData } from '../../data/types';
import type { Formatter } from '../../lib/format';
import { periodFromBucketKey, serializePeriod, type Period } from '../../lib/period';

/** Everything a section needs besides its data: formatting, period context and link builders. */
export interface OverviewView {
  fmt: Formatter;
  today: string;
  timeZone: string;
  current: Period;
  compare: Period | null;
  /** Short label of the comparison period ("2011"), when comparing. */
  compareLabel: string | null;
  currentLabel: string;
  withPeriod(path: string): string;
}

export interface SectionProps {
  data: OverviewData;
  /** Overview for the comparison period, once loaded. */
  vs: OverviewData | null;
  view: OverviewView;
}

/** Deep link into Time Machine that also moves the shared period to the bucket. */
export function timeMachineHref(view: OverviewView, key: string): string {
  const p = periodFromBucketKey(key);
  const q = new URLSearchParams({ at: key });
  if (p) q.set('period', serializePeriod(p));
  return view.withPeriod(`/time-machine?${q.toString()}`);
}

export const artistHref = (view: OverviewView, id: string) => view.withPeriod(`/artists/${encodeURIComponent(id)}`);
export const trackHref = (view: OverviewView, id: string) => view.withPeriod(`/tracks/${encodeURIComponent(id)}`);
export const albumHref = (view: OverviewView, id: string) => view.withPeriod(`/albums/${encodeURIComponent(id)}`);

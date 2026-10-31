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

/** A genre's own page (GET /api/genres/:slug), for a category id; "Other genres" has none. */
export function genreHref(view: OverviewView, id: string): string | null {
  if (id === 'other' || id === 'untagged') return null;
  return view.withPeriod(`/genres/${encodeURIComponent(id.replace(/^other:/, ''))}`);
}

/** "12% of plays are unclassified: 8% by artists not looked up yet, …", only the reasons present. */
export function unclassifiedText(b: { untaggedShare: number; unclassified: { notIdentified: number; notLookedUp: number; noGenres: number } }, percent: (share: number) => string): string {
  const parts = [
    [b.unclassified.notLookedUp, 'by artists not looked up yet'],
    [b.unclassified.notIdentified, 'by artists without a MusicBrainz ID'],
    [b.unclassified.noGenres, 'by artists with no listed genres'],
  ] as const;
  const present = parts.filter(([share]) => share > 0).map(([share, why]) => `${percent(share)} ${why}`);
  return `${percent(b.untaggedShare)} of plays are unclassified${present.length ? `: ${present.join(', ')}` : ''}.`;
}

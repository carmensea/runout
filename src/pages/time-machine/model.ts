import type { LocalDays } from '../../data/types';
import { MONTH_NAMES, addDays, isoWeekOf, isoWeekStart, monthEnd, monthStart, parseIsoDate } from '../../lib/dates';
import {
  defaultComparison, longDate, periodFromBucketKey, periodRange, serializePeriod, stepPeriod, timeMachineAt, type Period,
} from '../../lib/period';

/**
 * What Time Machine shows: the whole history, a year, a month, an ISO week, a day or a custom range.
 * The focus is the shared period (`?period=`), so the Overview and Time Machine always agree; `at`
 * keeps the deep-link form (`?at=2014-03`, `2014-W11`, `2014-03-15`, `2014`, and `all`).
 */
export type Focus = Exclude<Period, { kind: 'l12' }>;
export type Level = Focus['kind'];

/** Kinds that name a place in the history, so a shared period of that kind is kept on arrival. */
export function isPlace(p: Period): p is Exclude<Focus, { kind: 'all' }> {
  return p.kind === 'year' || p.kind === 'month' || p.kind === 'week' || p.kind === 'day' || p.kind === 'custom';
}

/** The last 12 months become their fixed range; everything else is already a focus. */
export function toFocus(p: Period, today: string): Focus {
  if (p.kind !== 'l12') return p;
  return { kind: 'custom', ...periodRange(p, today)! };
}

export function atFor(f: Focus): string | null {
  return f.kind === 'all' ? 'all' : timeMachineAt(f);
}

export function focusFromAt(at: string | null): Focus | null {
  if (!at) return null;
  if (at === 'all') return { kind: 'all' };
  const p = periodFromBucketKey(at);
  return p && p.kind !== 'l12' ? p : null;
}

/** Search for a Time Machine URL. A comparison follows the new unit, as the period bar does. */
function query(f: Focus, current: Period, compare: Period | null, today: string, withAt: boolean): URLSearchParams {
  const q = new URLSearchParams({ period: serializePeriod(f) });
  const at = atFor(f);
  if (withAt && at) q.set('at', at);
  if (compare && f.kind !== 'all') {
    const vs = f.kind === current.kind ? compare : defaultComparison(f, today);
    if (vs) q.set('vs', serializePeriod(vs));
  }
  return q;
}

export function timeMachineHref(f: Focus, current: Period, compare: Period | null, today: string): string {
  return `/time-machine?${query(f, current, compare, today, true).toString()}`;
}

export function overviewHref(f: Focus, current: Period, compare: Period | null, today: string): string {
  return `/overview?${query(f, current, compare, today, false).toString()}`;
}

const monthOf = (date: string): Focus => {
  const d = parseIsoDate(date);
  return { kind: 'month', year: d.getUTCFullYear(), month: d.getUTCMonth() + 1 };
};

/** A week belongs to the month and year of its Thursday, as ISO weeks belong to years. */
const weekThursday = (f: Extract<Focus, { kind: 'week' }>) => addDays(isoWeekStart(f.isoYear, f.week), 3);

/** One level up: day and week to their month, month to year, year and range to the whole history. */
export function parentOf(f: Focus): Focus | null {
  switch (f.kind) {
    case 'all': return null;
    case 'year': return { kind: 'all' };
    case 'month': return { kind: 'year', year: f.year };
    case 'week': return monthOf(weekThursday(f));
    case 'day': return monthOf(f.date);
    case 'custom': return { kind: 'all' };
  }
}

/** From the whole history down to the focus, for the breadcrumb trail. */
export function trailOf(f: Focus): Focus[] {
  const trail: Focus[] = [];
  for (let p: Focus | null = f; p; p = parentOf(p)) trail.unshift(p);
  return trail;
}

export function weekOf(date: string): Focus {
  return { kind: 'week', ...isoWeekOf(date) };
}

/** The neighbouring period of the same unit, or null past the history or after today. */
export function neighbour(f: Focus, dir: -1 | 1, today: string, firstDay: string | null): Focus | null {
  if (f.kind === 'all') return null;
  const next = stepPeriod(f, dir, today) as Focus;
  const r = periodRange(next, today)!;
  if (dir === 1 && r.from > today) return null;
  if (dir === -1 && firstDay && r.to < firstDay) return null;
  return next;
}

const MONTH_SHORT = MONTH_NAMES.map((m) => m.slice(0, 3));

/** "15 March 2014". */
export function dayMonthYear(date: string): string {
  const d = parseIsoDate(date);
  return `${d.getUTCDate()} ${MONTH_NAMES[d.getUTCMonth()]} ${d.getUTCFullYear()}`;
}

/** "10 to 16 March 2014", "29 December 2014 to 4 January 2015". */
export function rangeText(from: string, to: string): string {
  const a = parseIsoDate(from);
  const b = parseIsoDate(to);
  if (a.getUTCFullYear() !== b.getUTCFullYear()) return `${dayMonthYear(from)} to ${dayMonthYear(to)}`;
  if (a.getUTCMonth() !== b.getUTCMonth()) return `${a.getUTCDate()} ${MONTH_NAMES[a.getUTCMonth()]} to ${dayMonthYear(to)}`;
  return `${a.getUTCDate()} to ${dayMonthYear(to)}`;
}

/** The page title for a focus. */
export function focusTitle(f: Focus): string {
  switch (f.kind) {
    case 'all': return 'Your whole history';
    case 'year': return String(f.year);
    case 'month': return `${MONTH_NAMES[f.month - 1]} ${f.year}`;
    case 'week': return `Week ${f.week}, ${f.isoYear}`;
    case 'day': return longDate(f.date);
    case 'custom': return rangeText(f.from, f.to);
  }
}

/** The short label of a level in the breadcrumb trail. */
export function crumbLabel(f: Focus): string {
  switch (f.kind) {
    case 'all': return 'All years';
    case 'year': return String(f.year);
    case 'month': return MONTH_NAMES[f.month - 1]!;
    case 'week': return `Week ${f.week}`;
    case 'day': return String(parseIsoDate(f.date).getUTCDate());
    case 'custom': return 'Custom range';
  }
}

export const LEVEL_NOUN: Record<Level, string> = { all: 'history', year: 'year', month: 'month', week: 'week', day: 'day', custom: 'range' };

export function monthShort(month: number): string {
  return MONTH_SHORT[month - 1]!;
}

/** Rows of seven dates, Monday first, covering the month; dates outside it are included. */
export function monthWeeks(year: number, month: number): string[][] {
  const first = monthStart(year, month);
  const last = monthEnd(year, month);
  const { isoYear, week } = isoWeekOf(first);
  const rows: string[][] = [];
  for (let start = isoWeekStart(isoYear, week); start <= last; start = addDays(start, 7)) {
    rows.push(Array.from({ length: 7 }, (_, i) => addDays(start, i)));
  }
  return rows;
}

export function weekDates(f: Extract<Focus, { kind: 'week' }>): string[] {
  const start = isoWeekStart(f.isoYear, f.week);
  return Array.from({ length: 7 }, (_, i) => addDays(start, i));
}

/**
 * Whether a local day is imported, from a range's missing coverage (Analytics::Coverage): `none`
 * inside a missing range, `partial` on its first or last day when only part of it is missing,
 * `future` after today. A day with no plays is a confirmed empty day only when `complete`.
 */
export type DayStatus = 'complete' | 'partial' | 'none' | 'future';

export function dayStatusOf(missing: LocalDays[], today: string): (date: string) => DayStatus {
  return (date) => {
    if (date > today) return 'future';
    for (const m of missing) {
      if (date < m.from || date > m.to) continue;
      return (date === m.from && m.partialFrom) || (date === m.to && m.partialTo) ? 'partial' : 'none';
    }
    return 'complete';
  };
}

/** The same for a month: `none` when every day of it is missing, `partial` when some are. */
export function monthStatusOf(missing: LocalDays[], today: string): (key: string) => DayStatus {
  return (key) => {
    const [y, m] = key.split('-').map(Number);
    const from = monthStart(y!, m!);
    const to = monthEnd(y!, m!);
    if (from > today) return 'future';
    const overlapping = missing.filter((r) => r.from <= to && r.to >= from);
    if (overlapping.length === 0) return 'complete';
    const whole = overlapping.some((r) => (r.from < from || (r.from === from && !r.partialFrom))
      && (r.to > to || (r.to === to && !r.partialTo)));
    return whole ? 'none' : 'partial';
  };
}

export const STATUS_TEXT: Record<Exclude<DayStatus, 'complete'>, string> = {
  none: 'not imported',
  partial: 'partly imported',
  future: 'still to come',
};

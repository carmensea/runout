import {
  MONTH_NAMES,
  addDays,
  addMonths,
  daysBetween,
  isIsoDate,
  isoWeekOf,
  isoWeekStart,
  monthEnd,
  monthStart,
  parseIsoDate,
} from "./dates";

/** One global period object, set once, followed by every screen (HANDOFF.md "Period state"). */
export type Period =
  | { kind: "all" }
  | { kind: "year"; year: number }
  | { kind: "l12" }
  | { kind: "month"; year: number; month: number }
  | { kind: "week"; isoYear: number; week: number }
  | { kind: "day"; date: string }
  | { kind: "custom"; from: string; to: string };

export type PeriodKind = Period["kind"];

/** Kinds offered by the period bar. Week and day are set from Time Machine. */
export const BAR_KINDS: ReadonlyArray<{ kind: PeriodKind; label: string }> = [
  { kind: "all", label: "All time" },
  { kind: "year", label: "Year" },
  { kind: "l12", label: "Last 12 months" },
  { kind: "month", label: "Month" },
  { kind: "custom", label: "Custom" },
];

export interface DateRange {
  /** Inclusive, YYYY-MM-DD in the user's timezone. */
  from: string;
  to: string;
}

const pad = (n: number) => String(n).padStart(2, "0");

// ---------- Serialisation: ?period=year:2014&vs=year:2011 ----------

export function serializePeriod(p: Period): string {
  switch (p.kind) {
    case "all":
      return "all";
    case "l12":
      return "l12";
    case "year":
      return `year:${p.year}`;
    case "month":
      return `month:${p.year}-${pad(p.month)}`;
    case "week":
      return `week:${p.isoYear}-W${pad(p.week)}`;
    case "day":
      return `day:${p.date}`;
    case "custom":
      return `custom:${p.from}..${p.to}`;
  }
}

export function parsePeriod(raw: string | null | undefined): Period | null {
  if (!raw) return null;
  const [kind, value = ""] = raw.split(/:(.*)/s);
  switch (kind) {
    case "all":
      return { kind: "all" };
    case "l12":
      return { kind: "l12" };
    case "year": {
      const year = Number(value);
      return /^\d{4}$/.test(value) ? { kind: "year", year } : null;
    }
    case "month": {
      const m = /^(\d{4})-(\d{2})$/.exec(value);
      if (!m) return null;
      const month = Number(m[2]);
      return month >= 1 && month <= 12
        ? { kind: "month", year: Number(m[1]), month }
        : null;
    }
    case "week": {
      const m = /^(\d{4})-W(\d{2})$/.exec(value);
      if (!m) return null;
      const week = Number(m[2]);
      return week >= 1 && week <= 53
        ? { kind: "week", isoYear: Number(m[1]), week }
        : null;
    }
    case "day":
      return isIsoDate(value) ? { kind: "day", date: value } : null;
    case "custom": {
      const [from = "", to = ""] = value.split("..");
      return isIsoDate(from) && isIsoDate(to) && from <= to
        ? { kind: "custom", from, to }
        : null;
    }
    default:
      return null;
  }
}

export function samePeriod(a: Period | null, b: Period | null): boolean {
  if (!a || !b) return a === b;
  return serializePeriod(a) === serializePeriod(b);
}

// ---------- Ranges ----------

/** Inclusive date range. `all` returns null: its bounds are the user's history, known only to the server. */
export function periodRange(p: Period, today: string): DateRange | null {
  switch (p.kind) {
    case "all":
      return null;
    case "year":
      return { from: `${p.year}-01-01`, to: `${p.year}-12-31` };
    // The current calendar month (to date) plus the eleven before it.
    case "l12":
      return { from: `${addMonths(today, -11).slice(0, 7)}-01`, to: today };
    case "month":
      return {
        from: monthStart(p.year, p.month),
        to: monthEnd(p.year, p.month),
      };
    case "week": {
      const from = isoWeekStart(p.isoYear, p.week);
      return { from, to: addDays(from, 6) };
    }
    case "day":
      return { from: p.date, to: p.date };
    case "custom":
      return { from: p.from, to: p.to };
  }
}

/** Length in days, or null for `all`. */
export function periodLengthDays(p: Period, today: string): number | null {
  const r = periodRange(p, today);
  return r ? daysBetween(r.from, r.to) + 1 : null;
}

// ---------- Stepping (prev / next move by the period's own unit) ----------

export function stepPeriod(p: Period, dir: -1 | 1, today: string): Period {
  switch (p.kind) {
    case "all":
      return p;
    case "year":
      return { kind: "year", year: p.year + dir };
    case "month": {
      const idx = p.year * 12 + (p.month - 1) + dir;
      return {
        kind: "month",
        year: Math.floor(idx / 12),
        month: (idx % 12) + 1,
      };
    }
    case "week": {
      const next = addDays(isoWeekStart(p.isoYear, p.week), 7 * dir);
      return { kind: "week", ...isoWeekOf(next) };
    }
    case "day":
      return { kind: "day", date: addDays(p.date, dir) };
    case "l12": {
      // Stepping a rolling window yields a fixed 12-month range.
      const r = periodRange(p, today)!;
      const to = addMonths(r.to, 12 * dir);
      const [y, m] = to.split("-").map(Number);
      return {
        kind: "custom",
        from: addMonths(r.from, 12 * dir),
        to: monthEnd(y!, m!),
      };
    }
    case "custom": {
      const len = daysBetween(p.from, p.to) + 1;
      return {
        kind: "custom",
        from: addDays(p.from, len * dir),
        to: addDays(p.to, len * dir),
      };
    }
  }
}

export function canStep(p: Period, dir: -1 | 1, today: string): boolean {
  if (p.kind === "all") return false;
  if (dir === -1) return true;
  const next = periodRange(stepPeriod(p, 1, today), today);
  return !!next && next.from <= today;
}

// ---------- Switching kind from the segmented control ----------

/** Picks the period of `kind` that best contains the current selection. */
export function periodOfKind(
  kind: PeriodKind,
  current: Period,
  today: string,
): Period {
  const anchor = periodRange(current, today)?.to ?? today;
  const anchorClamped = anchor > today ? today : anchor;
  const d = parseIsoDate(anchorClamped);
  const year = d.getUTCFullYear();
  const month = d.getUTCMonth() + 1;
  switch (kind) {
    case "all":
      return { kind: "all" };
    case "l12":
      return { kind: "l12" };
    case "year":
      return { kind: "year", year };
    case "month":
      return { kind: "month", year, month };
    case "week":
      return { kind: "week", ...isoWeekOf(anchorClamped) };
    case "day":
      return { kind: "day", date: anchorClamped };
    case "custom": {
      const r = periodRange(current, today);
      return r
        ? { kind: "custom", ...r }
        : { kind: "custom", from: monthStart(year, 1), to: today };
    }
  }
}

/** The natural comparison: the preceding period of the same length. `all` has none. */
export function defaultComparison(p: Period, today: string): Period | null {
  if (p.kind === "all") return null;
  return stepPeriod(p, -1, today);
}

// ---------- Labels ----------

const MONTH_SHORT = MONTH_NAMES.map((m) => m.slice(0, 3));

function shortMonthYear(iso: string): string {
  const d = parseIsoDate(iso);
  return `${MONTH_SHORT[d.getUTCMonth()]} ${d.getUTCFullYear()}`;
}

/** Long title date: "Saturday 15 March 2014". */
export function longDate(iso: string): string {
  const d = parseIsoDate(iso);
  const weekday = new Intl.DateTimeFormat("en-GB", {
    weekday: "long",
    timeZone: "UTC",
  }).format(d);
  return `${weekday} ${d.getUTCDate()} ${MONTH_NAMES[d.getUTCMonth()]} ${d.getUTCFullYear()}`;
}

/** Value shown in the period stepper and page eyebrow. Ranges read "Nov 2025 to Oct 2026". */
export function periodLabel(p: Period, today: string): string {
  switch (p.kind) {
    case "all":
      return "Entire history";
    case "year":
      return String(p.year);
    case "month":
      return `${MONTH_NAMES[p.month - 1]} ${p.year}`;
    case "week":
      return `${p.isoYear}-W${pad(p.week)}`;
    case "day":
      return longDate(p.date);
    case "l12": {
      const r = periodRange(p, today)!;
      return `${shortMonthYear(r.from)} to ${shortMonthYear(r.to)}`;
    }
    case "custom": {
      const isWholeMonths =
        p.from.endsWith("-01") && addDays(p.to, 1).endsWith("-01");
      return isWholeMonths && daysBetween(p.from, p.to) > 31
        ? `${shortMonthYear(p.from)} to ${shortMonthYear(p.to)}`
        : `${p.from} to ${p.to}`;
    }
  }
}

/** Short form used in compare legends: "2011", "Sep 2026". */
export function periodShortLabel(p: Period, today: string): string {
  if (p.kind === "month") return `${MONTH_SHORT[p.month - 1]} ${p.year}`;
  return periodLabel(p, today);
}

/** Time Machine deep link value: ?at=2014-03 | 2014 | 2014-W11 | 2014-03-15 */
export function timeMachineAt(p: Period): string | null {
  switch (p.kind) {
    case "year":
      return String(p.year);
    case "month":
      return `${p.year}-${pad(p.month)}`;
    case "week":
      return `${p.isoYear}-W${pad(p.week)}`;
    case "day":
      return p.date;
    default:
      return null;
  }
}

/** Parses a bucket key as delivered by the API (same grammar as Time Machine `at`). */
export function periodFromBucketKey(key: string): Period | null {
  if (/^\d{4}$/.test(key)) return { kind: "year", year: Number(key) };
  if (/^\d{4}-\d{2}$/.test(key)) return parsePeriod(`month:${key}`);
  if (/^\d{4}-W\d{2}$/.test(key)) return parsePeriod(`week:${key}`);
  if (isIsoDate(key)) return { kind: "day", date: key };
  return null;
}

/**
 * Where the period and comparison controls do anything: the screens built from the selected
 * period. Settings, the welcome page, the loved library and the placeholders ignore the period,
 * so the controls stay out of their way.
 */
export function periodApplies(pathname: string): boolean {
  return ["/overview", "/time-machine", "/genres"].some(
    (base) => pathname === base || pathname.startsWith(`${base}/`),
  );
}

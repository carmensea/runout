import { MONTH_NAMES } from './dates';

/**
 * Display formatters. Figures are always grouped and tabular; dates follow the handoff's
 * format tokens (YYYY-MM-DD in data, "MMM YYYY" for months).
 *
 * In specimen mode (development only) every figure renders as zeros and every date as its
 * format token, so layout can be reviewed without anything resembling listening data.
 */
export interface Formatter {
  count(n: number): string;
  percent(share: number, digits?: number): string;
  date(iso: string): string;
  monthShort(key: string): string;
  /** YYYY-MM as written in data. */
  yearMonth(key: string): string;
  monthLong(key: string): string;
  year(key: string): string;
  time(isoDateTime: string, timeZone: string): string;
  dateTime(isoDateTime: string, timeZone: string): string;
}

const MONTH_SHORT = MONTH_NAMES.map((m) => m.slice(0, 3));
const grouping = new Intl.NumberFormat('en-GB');

function monthParts(key: string): [number, number] {
  const [y, m] = key.split('-').map(Number);
  return [y ?? 0, m ?? 1];
}

export const realFormatter: Formatter = {
  count: (n) => grouping.format(Math.round(n)),
  percent: (share, digits = 0) => `${(share * 100).toFixed(digits)}%`,
  date: (iso) => iso.slice(0, 10),
  monthShort: (key) => {
    const [y, m] = monthParts(key);
    return `${MONTH_SHORT[m - 1]} ${y}`;
  },
  monthLong: (key) => {
    const [y, m] = monthParts(key);
    return `${MONTH_NAMES[m - 1]} ${y}`;
  },
  yearMonth: (key) => key.slice(0, 7),
  year: (key) => key.slice(0, 4),
  time: (dt, timeZone) =>
    new Intl.DateTimeFormat('en-GB', { timeZone, hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date(dt)),
  dateTime: (dt, timeZone) => {
    const d = new Date(dt);
    const date = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
    return `${date} ${realFormatter.time(dt, timeZone)}`;
  },
};

const zeroDigits = (s: string) => s.replace(/\d/g, '0');

export const specimenFormatter: Formatter = {
  count: (n) => zeroDigits(realFormatter.count(n)),
  percent: (share, digits = 0) => zeroDigits(realFormatter.percent(share, digits)),
  date: () => 'YYYY-MM-DD',
  monthShort: () => 'MMM YYYY',
  monthLong: () => 'MMMM YYYY',
  yearMonth: () => 'YYYY-MM',
  year: () => 'YYYY',
  time: () => 'HH:MM',
  dateTime: () => 'YYYY-MM-DD HH:MM',
};

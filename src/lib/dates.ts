/**
 * Calendar helpers on plain ISO date strings (YYYY-MM-DD).
 * All arithmetic runs in UTC so results never drift with the host timezone;
 * "today" is resolved in the user's timezone setting.
 */

export const MONTH_NAMES = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
] as const;

export const WEEKDAY_SHORT = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'] as const;

/** Hour-of-day axis ticks, every three hours. */
export const HOUR_TICKS = ['00', '03', '06', '09', '12', '15', '18', '21'] as const;

const pad = (n: number, len = 2) => String(n).padStart(len, '0');

export function toIsoDate(d: Date): string {
  return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`;
}

export function parseIsoDate(iso: string): Date {
  const [y, m, d] = iso.split('-').map(Number);
  return new Date(Date.UTC(y ?? 1970, (m ?? 1) - 1, d ?? 1));
}

export function isIsoDate(s: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(s)) return false;
  return toIsoDate(parseIsoDate(s)) === s;
}

export function addDays(iso: string, days: number): string {
  const d = parseIsoDate(iso);
  d.setUTCDate(d.getUTCDate() + days);
  return toIsoDate(d);
}

/** Adds months, clamping the day to the end of the target month. */
export function addMonths(iso: string, months: number): string {
  const d = parseIsoDate(iso);
  const day = d.getUTCDate();
  d.setUTCDate(1);
  d.setUTCMonth(d.getUTCMonth() + months);
  d.setUTCDate(Math.min(day, daysInMonth(d.getUTCFullYear(), d.getUTCMonth() + 1)));
  return toIsoDate(d);
}

export function daysInMonth(year: number, month: number): number {
  return new Date(Date.UTC(year, month, 0)).getUTCDate();
}

export function daysBetween(fromIso: string, toIso: string): number {
  return Math.round((parseIsoDate(toIso).getTime() - parseIsoDate(fromIso).getTime()) / 86_400_000);
}

export function monthStart(year: number, month: number): string {
  return `${year}-${pad(month)}-01`;
}

export function monthEnd(year: number, month: number): string {
  return `${year}-${pad(month)}-${pad(daysInMonth(year, month))}`;
}

/** ISO-8601 week: Monday of week 1 is the Monday of the week containing 4 January. */
export function isoWeekStart(isoYear: number, week: number): string {
  const jan4 = new Date(Date.UTC(isoYear, 0, 4));
  const dow = (jan4.getUTCDay() + 6) % 7;
  jan4.setUTCDate(jan4.getUTCDate() - dow + (week - 1) * 7);
  return toIsoDate(jan4);
}

export function isoWeekOf(iso: string): { isoYear: number; week: number } {
  const d = parseIsoDate(iso);
  const dow = (d.getUTCDay() + 6) % 7;
  d.setUTCDate(d.getUTCDate() - dow + 3);
  const isoYear = d.getUTCFullYear();
  const firstThursday = parseIsoDate(isoWeekStart(isoYear, 1));
  firstThursday.setUTCDate(firstThursday.getUTCDate() + 3);
  const week = 1 + Math.round((d.getTime() - firstThursday.getTime()) / (7 * 86_400_000));
  return { isoYear, week };
}

/** Today's calendar date in an IANA timezone. */
export function todayIn(timeZone: string, now: Date = new Date()): string {
  try {
    const parts = new Intl.DateTimeFormat('en-CA', {
      timeZone, year: 'numeric', month: '2-digit', day: '2-digit',
    }).format(now);
    return parts;
  } catch {
    return toIsoDate(now);
  }
}

export function browserTimeZone(): string {
  return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
}

/** Seasons by hemisphere; Southern-hemisphere zones are matched by prefix. */
const SOUTHERN_PREFIXES = [
  'Australia/', 'Antarctica/', 'Pacific/Auckland', 'Pacific/Chatham', 'Pacific/Fiji',
  'America/Argentina', 'America/Santiago', 'America/Montevideo', 'America/Asuncion',
  'America/Sao_Paulo', 'America/Lima', 'America/La_Paz', 'Africa/Johannesburg',
  'Africa/Maputo', 'Africa/Harare', 'Africa/Windhoek', 'Indian/Mauritius', 'Indian/Reunion',
];

export function hemisphereOf(timeZone: string): 'northern' | 'southern' {
  return SOUTHERN_PREFIXES.some((p) => timeZone.startsWith(p)) ? 'southern' : 'northern';
}

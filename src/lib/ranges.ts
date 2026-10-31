import type { Formatter } from './format';
import type { LocalDays } from '../data/types';
import { daysInMonth } from './dates';

function localDate(ms: number, timeZone: string): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(ms));
}

/** Whether a day starts at this instant: the moment before it is on another local date. Works where daylight saving time skips midnight. */
function startsDay(ms: number, timeZone: string): boolean {
  return localDate(ms, timeZone) !== localDate(ms - 1, timeZone);
}

/** The server's rule (Analytics::Period.local_days), for intervals it sends as plain UTC. */
export function localDays(startsAt: string, endsAt: string, timeZone: string): LocalDays {
  const start = Date.parse(startsAt);
  const end = Date.parse(endsAt);
  return {
    from: localDate(start, timeZone),
    to: localDate(end - 1, timeZone),
    startsAt,
    endsAt,
    partialFrom: !startsDay(start, timeZone),
    partialTo: !startsDay(end, timeZone),
  };
}

/**
 * "2014-06-01 to 2014-06-30" for whole days; a day only partly inside shows its time instead
 * ("2014-05-31 17:00 to 2014-06-30 17:00", the end exclusive). "June 2014" for a whole local month
 * when `months` is set.
 */
export function localDaysLabel(days: LocalDays, fmt: Formatter, timeZone: string, { months = false } = {}): string {
  const [y, m] = days.from.split('-').map(Number);
  const wholeMonth = !days.partialFrom && !days.partialTo && days.from.endsWith('-01')
    && days.to === `${days.from.slice(0, 8)}${String(daysInMonth(y!, m!)).padStart(2, '0')}`;
  if (months && wholeMonth) return fmt.monthLong(days.from.slice(0, 7));
  const start = days.partialFrom ? fmt.dateTime(days.startsAt, timeZone) : fmt.date(days.from);
  const end = days.partialTo ? fmt.dateTime(days.endsAt, timeZone) : fmt.date(days.to);
  return start === end ? start : `${start} to ${end}`;
}

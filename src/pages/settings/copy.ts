import type { Formatter } from '../../lib/format';
import { localDays, localDaysLabel } from '../../lib/ranges';
import type { HistoryActivity, PeriodRange, StopReason } from '../../data/types';

/**
 * Plain wording for import, sync and review states. The server sends codes; nothing here should
 * read like a job queue. Technical detail stays available under "Technical details".
 */

export const ACTIVITY: Record<HistoryActivity, string> = {
  idle: 'Up to date',
  importing: 'Importing your history',
  syncing: 'Checking for new scrobbles',
  catching_up: 'Checking the last 14 days for late scrobbles',
  comparing: 'Comparing monthly totals with Last.fm',
  paused: 'Import paused',
  sync_paused: 'Automatic sync is paused',
  waiting_for_review: 'Waiting for you',
  working: 'Working',
};

/** Activities during which something is being fetched or saved right now. */
export const BUSY: ReadonlySet<HistoryActivity> = new Set(['importing', 'syncing', 'catching_up', 'comparing', 'working']);

export const REASON: Record<StopReason, string> = {
  undated_rows: 'Last.fm returned plays without a date, so this period was not saved.',
  malformed_rows: 'Last.fm returned entries Runout could not read, so this period was not saved.',
  out_of_range_rows: 'Last.fm returned plays from outside this period, so it was not saved.',
  too_large: 'This period has too many plays to check in one go.',
  reconciliation_check: 'Runout’s own check of the result failed, so nothing was changed.',
  incomplete_answer: 'Last.fm’s answer was missing most of the plays already stored, so nothing was treated as deleted.',
  staging_inconsistent: 'The downloaded copy didn’t add up, so nothing was saved.',
  commit_error: 'Saving this period failed unexpectedly. Nothing was changed.',
  unstable: 'Your history kept changing while this period was read, probably because you were listening.',
  attempts_exhausted: 'Several attempts didn’t succeed.',
  budget_exhausted: 'This period needed more requests than allowed.',
  gave_up: 'Last.fm couldn’t be reached.',
};

export function reasonText(reason: StopReason | null | undefined): string {
  return reason ? REASON[reason] : 'This period stopped.';
}

/**
 * An import period (UTC, end exclusive) in the user's timezone, by the same rule as the Overview's
 * missing ranges: "March 2014" for a whole local month, local dates for whole days, and the time
 * where a day is only partly inside. Import periods are UTC months, so outside UTC they rarely
 * line up with local months.
 */
export function periodLabel(range: PeriodRange, fmt: Formatter, timeZone: string): string {
  return localDaysLabel(localDays(range.from, range.to, timeZone), fmt, timeZone, { months: true });
}

export const REVIEW_KIND = {
  removal: 'Missing from Last.fm',
  reappeared: 'Back on Last.fm',
  dispute: 'Different on Last.fm',
} as const;

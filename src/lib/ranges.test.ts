import { describe, expect, it } from 'vitest';
import { realFormatter } from './format';
import { localDays, localDaysLabel } from './ranges';

// The same cases as server/test/services/analytics/coverage_dates_test.rb: one rule on both sides.
const la = 'America/Los_Angeles';
const pick = (d: ReturnType<typeof localDays>) => [d.from, d.to, d.partialFrom, d.partialTo];
const label = (from: string, to: string, tz: string) => localDaysLabel(localDays(from, to, tz), realFormatter, tz, { months: true });

describe('localDays', () => {
  it('places a UTC month in Pacific time: the evening before to the evening of its last day', () => {
    expect(pick(localDays('2014-06-01T00:00:00Z', '2014-07-01T00:00:00Z', la))).toEqual(['2014-05-31', '2014-06-30', true, true]);
    expect(pick(localDays('2014-01-01T00:00:00Z', '2014-02-01T00:00:00Z', la))).toEqual(['2013-12-31', '2014-01-31', true, true]);
    expect(label('2014-06-01T00:00:00Z', '2014-07-01T00:00:00Z', la)).toBe('2014-05-31 17:00 to 2014-06-30 17:00');
  });

  it('treats the end as exclusive: ending at local midnight never touches the next day', () => {
    expect(pick(localDays('2014-06-01T07:00:00Z', '2014-06-02T07:00:00Z', la))).toEqual(['2014-06-01', '2014-06-01', false, false]);
    expect(pick(localDays('2014-06-01T07:00:00Z', '2014-06-02T07:00:01Z', la))).toEqual(['2014-06-01', '2014-06-02', false, true]);
    expect(pick(localDays('2014-06-02T00:00:00Z', '2014-06-02T07:00:00Z', la))).toEqual(['2014-06-01', '2014-06-01', true, false]);
    expect(label('2014-06-01T07:00:00Z', '2014-06-02T07:00:00Z', la)).toBe('2014-06-01');
  });

  it('handles daylight saving changes, including a skipped midnight', () => {
    expect(pick(localDays('2014-03-09T08:00:00Z', '2014-03-10T07:00:00Z', la))).toEqual(['2014-03-09', '2014-03-09', false, false]);
    expect(pick(localDays('2014-11-02T07:00:00Z', '2014-11-03T08:00:00Z', la))).toEqual(['2014-11-02', '2014-11-02', false, false]);
    expect(pick(localDays('2014-11-02T07:00:00Z', '2014-11-03T07:00:00Z', la))).toEqual(['2014-11-02', '2014-11-02', false, true]);
    // Havana, 9 March 2014: 00:00 doesn't exist, so the day starts at 01:00 (05:00 UTC).
    expect(pick(localDays('2014-03-08T05:00:00Z', '2014-03-09T05:00:00Z', 'America/Havana'))).toEqual(['2014-03-08', '2014-03-08', false, false]);
    expect(pick(localDays('2014-03-01T00:00:00Z', '2014-04-01T00:00:00Z', 'Europe/London'))).toEqual(['2014-03-01', '2014-04-01', false, true]);
  });

  it('names a month only when it is a whole local month', () => {
    expect(label('2014-03-01T00:00:00Z', '2014-04-01T00:00:00Z', 'UTC')).toBe('March 2014');
    expect(label('2014-02-01T08:00:00Z', '2014-03-01T08:00:00Z', la)).toBe('February 2014');
    expect(label('2014-03-01T00:00:00Z', '2014-04-01T00:00:00Z', 'Europe/London')).toBe('2014-03-01 to 2014-04-01 01:00');
    expect(localDaysLabel(localDays('2014-03-01T00:00:00Z', '2014-04-01T00:00:00Z', 'UTC'), realFormatter, 'UTC')).toBe('2014-03-01 to 2014-03-31');
  });
});

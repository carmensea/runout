import { describe, expect, it } from 'vitest';
import {
  canStep, defaultComparison, parsePeriod, periodFromBucketKey, periodLabel, periodOfKind, periodRange,
  serializePeriod, stepPeriod, type Period,
} from './period';

const today = '2026-10-29';

describe('serialise / parse', () => {
  const cases: Period[] = [
    { kind: 'all' },
    { kind: 'l12' },
    { kind: 'year', year: 2014 },
    { kind: 'month', year: 2014, month: 3 },
    { kind: 'week', isoYear: 2014, week: 11 },
    { kind: 'day', date: '2014-03-15' },
    { kind: 'custom', from: '2026-03-01', to: '2026-06-30' },
  ];
  it.each(cases)('round-trips %o', (p) => {
    expect(parsePeriod(serializePeriod(p))).toEqual(p);
  });

  it('rejects malformed values', () => {
    for (const raw of ['', 'year:14', 'month:2014-13', 'week:2014-W54', 'day:2014-02-30', 'custom:2026-06-30..2026-03-01', 'decade:2010']) {
      expect(parsePeriod(raw)).toBeNull();
    }
  });
});

describe('stepping', () => {
  it('moves by the period unit', () => {
    expect(stepPeriod({ kind: 'month', year: 2014, month: 1 }, -1, today)).toEqual({ kind: 'month', year: 2013, month: 12 });
    expect(stepPeriod({ kind: 'year', year: 2014 }, 1, today)).toEqual({ kind: 'year', year: 2015 });
    expect(stepPeriod({ kind: 'week', isoYear: 2015, week: 1 }, -1, today)).toEqual({ kind: 'week', isoYear: 2014, week: 52 });
    expect(periodLabel(stepPeriod({ kind: 'l12' }, -1, today), today)).toBe('Nov 2024 to Oct 2025');
    expect(stepPeriod({ kind: 'custom', from: '2026-03-01', to: '2026-03-10' }, -1, today)).toEqual({ kind: 'custom', from: '2026-02-19', to: '2026-02-28' });
  });

  it('is disabled for all time and never moves into the future', () => {
    expect(canStep({ kind: 'all' }, -1, today)).toBe(false);
    expect(canStep({ kind: 'year', year: 2026 }, 1, today)).toBe(false);
    expect(canStep({ kind: 'month', year: 2026, month: 9 }, 1, today)).toBe(true);
    expect(canStep({ kind: 'month', year: 2026, month: 10 }, 1, today)).toBe(false);
  });
});

describe('labels and ranges', () => {
  it('formats ranges without em dashes', () => {
    expect(periodLabel({ kind: 'l12' }, today)).toBe('Nov 2025 to Oct 2026');
    expect(periodLabel({ kind: 'custom', from: '2026-03-01', to: '2026-06-30' }, today)).toBe('Mar 2026 to Jun 2026');
    expect(periodLabel({ kind: 'custom', from: '2026-03-04', to: '2026-03-09' }, today)).toBe('2026-03-04 to 2026-03-09');
    expect(periodLabel({ kind: 'day', date: '2014-03-15' }, today)).toBe('Saturday 15 March 2014');
  });

  it('computes inclusive ranges', () => {
    expect(periodRange({ kind: 'l12' }, today)).toEqual({ from: '2025-11-01', to: '2026-10-29' });
    expect(periodRange({ kind: 'month', year: 2024, month: 2 }, today)).toEqual({ from: '2024-02-01', to: '2024-02-29' });
    expect(periodRange({ kind: 'all' }, today)).toBeNull();
  });
});

describe('kind switching and comparison', () => {
  it('keeps the selection anchored when changing kind', () => {
    expect(periodOfKind('month', { kind: 'year', year: 2014 }, today)).toEqual({ kind: 'month', year: 2014, month: 12 });
    expect(periodOfKind('year', { kind: 'all' }, today)).toEqual({ kind: 'year', year: 2026 });
  });

  it('compares with the preceding period of the same unit', () => {
    expect(defaultComparison({ kind: 'year', year: 2026 }, today)).toEqual({ kind: 'year', year: 2025 });
    expect(defaultComparison({ kind: 'all' }, today)).toBeNull();
  });

  it('maps chart bucket keys to periods', () => {
    expect(periodFromBucketKey('2014-03')).toEqual({ kind: 'month', year: 2014, month: 3 });
    expect(periodFromBucketKey('2014')).toEqual({ kind: 'year', year: 2014 });
    expect(periodFromBucketKey('2014-W11')).toEqual({ kind: 'week', isoYear: 2014, week: 11 });
  });
});

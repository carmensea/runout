import { describe, expect, it } from 'vitest';
import {
  atFor, dayStatusOf, focusFromAt, focusTitle, monthStatusOf, monthWeeks, neighbour, overviewHref, parentOf, rangeText,
  timeMachineHref, toFocus, trailOf,
} from './model';

const today = '2026-10-31';

describe('Time Machine model', () => {
  it('keeps the deep-link form, and adds `all` for the whole history', () => {
    expect(atFor({ kind: 'day', date: '2014-03-15' })).toBe('2014-03-15');
    expect(atFor({ kind: 'week', isoYear: 2014, week: 11 })).toBe('2014-W11');
    expect(atFor({ kind: 'all' })).toBe('all');
    expect(atFor({ kind: 'custom', from: '2014-01-01', to: '2014-02-01' })).toBeNull();
    expect(focusFromAt('2014-03')).toEqual({ kind: 'month', year: 2014, month: 3 });
    expect(focusFromAt('all')).toEqual({ kind: 'all' });
    expect(focusFromAt('nonsense')).toBeNull();
    expect(toFocus({ kind: 'l12' }, today)).toEqual({ kind: 'custom', from: '2025-11-01', to: '2026-10-31' });
  });

  it('links carry the period and `at`; a comparison follows the new unit', () => {
    const current = { kind: 'year' as const, year: 2014 };
    expect(timeMachineHref({ kind: 'day', date: '2014-03-15' }, current, null, today)).toBe('/time-machine?period=day%3A2014-03-15&at=2014-03-15');
    expect(timeMachineHref({ kind: 'year', year: 2015 }, current, { kind: 'year', year: 2013 }, today))
      .toBe('/time-machine?period=year%3A2015&at=2015&vs=year%3A2013');
    expect(overviewHref({ kind: 'month', year: 2014, month: 3 }, current, { kind: 'year', year: 2013 }, today))
      .toBe('/overview?period=month%3A2014-03&vs=month%3A2014-02');
  });

  it('moves up: day and week to their month (a week by its Thursday), month to year, year to the history', () => {
    expect(parentOf({ kind: 'day', date: '2014-03-15' })).toEqual({ kind: 'month', year: 2014, month: 3 });
    expect(parentOf({ kind: 'week', isoYear: 2015, week: 1 })).toEqual({ kind: 'month', year: 2015, month: 1 }); // 29 Dec 2014 to 4 Jan 2015
    expect(parentOf({ kind: 'week', isoYear: 2014, week: 1 })).toEqual({ kind: 'month', year: 2014, month: 1 }); // 30 Dec 2013 to 5 Jan 2014
    expect(trailOf({ kind: 'day', date: '2014-03-15' }).map((f) => f.kind)).toEqual(['all', 'year', 'month', 'day']);
    expect(parentOf({ kind: 'all' })).toBeNull();
  });

  it('steps to neighbours, never after today or before the history', () => {
    expect(neighbour({ kind: 'day', date: '2014-12-31' }, 1, today, '2006-09-10')).toEqual({ kind: 'day', date: '2015-01-01' });
    expect(neighbour({ kind: 'month', year: 2014, month: 12 }, 1, today, null)).toEqual({ kind: 'month', year: 2015, month: 1 });
    expect(neighbour({ kind: 'day', date: today }, 1, today, null)).toBeNull();
    expect(neighbour({ kind: 'day', date: '2006-09-10' }, -1, today, '2006-09-10')).toBeNull();
    expect(neighbour({ kind: 'month', year: 2006, month: 9 }, -1, today, '2006-09-10')).toBeNull();
    expect(neighbour({ kind: 'all' }, 1, today, null)).toBeNull();
  });

  it('lays out months in Monday-first weeks, leap years included', () => {
    const feb2016 = monthWeeks(2016, 2);
    expect(feb2016[0]![0]).toBe('2016-02-01');
    expect(feb2016.flat()).toContain('2016-02-29');
    const march2014 = monthWeeks(2014, 3);
    expect(march2014[0]).toEqual(['2014-02-24', '2014-02-25', '2014-02-26', '2014-02-27', '2014-02-28', '2014-03-01', '2014-03-02']);
    expect(march2014.length).toBe(6);
  });

  it('tells confirmed empty days from missing and partly missing ones', () => {
    const status = dayStatusOf([
      { from: '2014-05-31', to: '2014-06-30', startsAt: '2014-06-01T00:00:00Z', endsAt: '2014-07-01T00:00:00Z', partialFrom: true, partialTo: true },
    ], today);
    expect(status('2014-05-30')).toBe('complete');
    expect(status('2014-05-31')).toBe('partial');
    expect(status('2014-06-15')).toBe('none');
    expect(status('2014-06-30')).toBe('partial');
    expect(status('2026-11-01')).toBe('future');

    const month = monthStatusOf([
      { from: '2014-06-01', to: '2014-06-30', startsAt: '', endsAt: '', partialFrom: false, partialTo: false },
      { from: '2014-08-31', to: '2014-09-30', startsAt: '', endsAt: '', partialFrom: true, partialTo: false },
    ], today);
    expect(month('2014-06')).toBe('none');
    expect(month('2014-08')).toBe('partial');
    expect(month('2014-09')).toBe('none');
    expect(month('2014-07')).toBe('complete');
    expect(month('2026-12')).toBe('future');
  });

  it('titles every level', () => {
    expect(focusTitle({ kind: 'day', date: '2014-03-15' })).toBe('Saturday 15 March 2014');
    expect(focusTitle({ kind: 'week', isoYear: 2014, week: 11 })).toBe('Week 11, 2014');
    expect(focusTitle({ kind: 'custom', from: '2010-06-01', to: '2011-05-31' })).toBe('1 June 2010 to 31 May 2011');
    expect(rangeText('2014-03-10', '2014-03-16')).toBe('10 to 16 March 2014');
    expect(rangeText('2014-12-29', '2015-01-04')).toBe('29 December 2014 to 4 January 2015');
  });
});

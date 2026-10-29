import { describe, expect, it } from 'vitest';
import { niceCeil, quantileBucketer, spreadLabels } from './scale';
import { realFormatter, specimenFormatter } from './format';

describe('scale helpers', () => {
  it('rounds axis ceilings to readable values', () => {
    expect(niceCeil(0)).toBe(1);
    expect(niceCeil(87)).toBe(100);
    expect(niceCeil(1340)).toBe(2000);
    expect(niceCeil(2400)).toBe(2500);
  });

  it('keeps zero separate from quantile steps', () => {
    const bucket = quantileBucketer([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 5);
    expect(bucket(0)).toBe(-1);
    expect(bucket(1)).toBe(0);
    expect(bucket(10)).toBe(4);
  });

  it('spreads crowded labels while keeping order', () => {
    const out = spreadLabels([50, 51, 52], 6);
    expect(out[1]! - out[0]!).toBeGreaterThanOrEqual(6);
    expect(out[2]! - out[1]!).toBeGreaterThanOrEqual(6);
  });
});

describe('formatters', () => {
  it('groups figures', () => {
    expect(realFormatter.count(123456)).toBe('123,456');
    expect(realFormatter.percent(0.123, 1)).toBe('12.3%');
    expect(realFormatter.monthShort('2014-03')).toBe('Mar 2014');
  });

  it('specimen formatter never shows real-looking figures', () => {
    expect(specimenFormatter.count(123456)).toBe('000,000');
    expect(specimenFormatter.date('2014-03-15')).toBe('YYYY-MM-DD');
  });
});

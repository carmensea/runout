import { describe, expect, it } from 'vitest';
import { wholePercentages } from './shares';

describe('wholePercentages', () => {
  it('adds up to exactly 100', () => {
    expect(wholePercentages({ a: 1, b: 1, c: 1 })).toEqual({ a: 34, b: 33, c: 33 });
    expect(wholePercentages({ a: 2, b: 1 })).toEqual({ a: 67, b: 33 });
    for (let i = 0; i < 200; i++) {
      const values = Object.fromEntries(Array.from({ length: 1 + (i % 9) }, (_, j) => [`k${j}`, Math.random()]));
      const p = wholePercentages(values);
      expect(Object.values(p).reduce((a, b) => a + b, 0)).toBe(100);
    }
  });

  it('gives zero parts nothing, and an empty total all zeros', () => {
    expect(wholePercentages({ a: 0, b: 3 })).toEqual({ a: 0, b: 100 });
    expect(wholePercentages({ a: 0, b: 0 })).toEqual({ a: 0, b: 0 });
  });
});

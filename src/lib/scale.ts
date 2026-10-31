/** Rounds a maximum up to a readable axis ceiling (1, 2, 2.5, 5 × 10^n). */
export function niceCeil(max: number): number {
  if (!(max > 0)) return 1;
  const exp = Math.floor(Math.log10(max));
  const base = 10 ** exp;
  for (const step of [1, 2, 2.5, 5, 10]) {
    if (step * base >= max) return step * base;
  }
  return 10 * base;
}

/** Evenly spaced ticks from the ceiling down to zero, inclusive. */
export function ticksFromTop(ceil: number, count: number): number[] {
  return Array.from({ length: count + 1 }, (_, i) => ceil - (ceil / count) * i);
}

/** Fraction 0..1 of a value against a maximum, safe for empty data. */
export function ratio(value: number, max: number): number {
  return max > 0 ? Math.max(0, Math.min(1, value / max)) : 0;
}

/**
 * Splits non-zero values into `steps` quantile buckets. Returns -1 for zero
 * (rendered as the empty surface) and 0..steps-1 otherwise.
 */
export function quantileBucketer(values: number[], steps: number): (v: number) => number {
  const sorted = values.filter((v) => v > 0).sort((a, b) => a - b);
  if (sorted.length === 0) return () => -1;
  const cuts = Array.from({ length: steps - 1 }, (_, i) => {
    const idx = Math.floor(((i + 1) / steps) * sorted.length);
    return sorted[Math.min(idx, sorted.length - 1)]!;
  });
  return (v) => {
    if (v <= 0) return -1;
    let b = 0;
    while (b < cuts.length && v >= cuts[b]!) b++;
    return b;
  };
}

/**
 * Spreads label positions (0..100 %) so neighbours keep `minGap` apart,
 * preserving order. Used for direct labels at the end of stacked/line charts.
 */
export function spreadLabels(positions: number[], minGap: number): number[] {
  const order = positions.map((p, i) => ({ p, i })).sort((a, b) => a.p - b.p);
  const placed: number[] = [];
  for (const [k, item] of order.entries()) {
    const prev = placed[k - 1];
    placed.push(prev === undefined ? Math.max(item.p, minGap / 2) : Math.max(item.p, prev + minGap));
  }
  // Pull back from the bottom edge if we overflowed.
  const overflow = (placed[placed.length - 1] ?? 0) - (100 - minGap / 2);
  if (overflow > 0) {
    for (let k = placed.length - 1; k >= 0; k--) {
      const next = placed[k + 1];
      placed[k] = next === undefined ? placed[k]! - overflow : Math.min(placed[k]!, next - minGap);
    }
  }
  const out = new Array<number>(positions.length);
  order.forEach((item, k) => (out[item.i] = placed[k]!));
  return out;
}

/** Accent opacity per quantile step (HANDOFF.md: 5 steps, zero = --s1). */
export const HEAT_RAMP = [0.12, 0.3, 0.5, 0.75, 1];

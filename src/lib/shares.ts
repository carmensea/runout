/**
 * Whole percentages for parts of one total, adding up to exactly 100 (largest remainder), as
 * docs/backend-plan.md §6 requires for every distribution Runout shows. Only for parts that don't
 * overlap: overlapping figures (genre reach) are never put through this, or summed.
 */
export function wholePercentages<K extends string>(values: Record<K, number>): Record<K, number> {
  const keys = Object.keys(values) as K[];
  const total = keys.reduce((sum, k) => sum + Math.max(0, values[k]), 0);
  const out = {} as Record<K, number>;
  if (total <= 0) {
    for (const k of keys) out[k] = 0;
    return out;
  }
  const exact = keys.map((k) => ({ k, v: (Math.max(0, values[k]) / total) * 100 }));
  for (const { k, v } of exact) out[k] = Math.floor(v);
  const missing = 100 - keys.reduce((sum, k) => sum + out[k], 0);
  exact
    .filter(({ v }) => v > 0)
    .sort((a, b) => (b.v - Math.floor(b.v)) - (a.v - Math.floor(a.v)) || a.k.localeCompare(b.k))
    .slice(0, missing)
    .forEach(({ k }) => { out[k] += 1; });
  return out;
}

/** 96 × 24 trend line, decorative (the table row carries the figures). */
export function Sparkline({ values, width = 96, height = 24 }: { values: number[]; width?: number; height?: number }) {
  if (values.length < 2) return <svg width={width} height={height} aria-hidden="true" />;
  // Zero baseline, so a flat but busy artist doesn't read as volatile.
  const max = Math.max(...values) || 1;
  const pad = 2;
  const d = values
    .map((v, i) => {
      const x = (i / (values.length - 1)) * width;
      const y = height - pad - (v / max) * (height - pad * 2);
      return `${i ? 'L' : 'M'}${x.toFixed(1)},${y.toFixed(1)}`;
    })
    .join(' ');
  return (
    <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`} aria-hidden="true" style={{ display: 'block' }}>
      <path d={d} fill="none" stroke="var(--fg2)" strokeWidth="1.25" />
    </svg>
  );
}

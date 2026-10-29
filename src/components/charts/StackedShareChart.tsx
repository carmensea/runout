import { useState, type KeyboardEvent } from 'react';
import { spreadLabels } from '../../lib/scale';
import styles from './GenreCharts.module.css';

export interface ShareSeries {
  id: string;
  name: string;
  color: string;
  /** Hatched "unknown" band. */
  hatched?: boolean;
}

interface Props {
  series: ShareSeries[];
  /** Rows per year; `shares` keyed by series id, each row summing to ~1. */
  rows: Array<{ year: number; shares: Record<string, number> }>;
  formatShare(share: number): string;
  summary: string;
}

const W = 700;
const H = 280;

/** 100% stacked area by year with direct labels at the right end. Arrow keys step through years. */
export function StackedShareChart({ series, rows, formatShare, summary }: Props) {
  const [active, setActive] = useState<number | null>(null);
  const n = rows.length;
  const x = (i: number) => (n > 1 ? (i / (n - 1)) * W : W / 2);

  const cum = rows.map(() => 0);
  const bands = series.map((s) => {
    const bottom = rows.map((_, i) => [x(i), cum[i]! * H] as const);
    rows.forEach((r, i) => (cum[i]! += r.shares[s.id] ?? 0));
    const top = rows.map((_, i) => [x(i), cum[i]! * H] as const);
    const d = `M${top.map(([a, b]) => `${a.toFixed(1)},${b.toFixed(1)}`).join(' L')} L${[...bottom].reverse().map(([a, b]) => `${a.toFixed(1)},${b.toFixed(1)}`).join(' L')} Z`;
    return { ...s, d };
  });

  const last = rows[n - 1];
  let acc = 0;
  const rawLabelPos = series.map((s) => {
    const share = last?.shares[s.id] ?? 0;
    const mid = (acc + share / 2) * 100;
    acc += share;
    return mid;
  });
  const labelPos = spreadLabels(rawLabelPos, 6);

  function onKeyDown(e: KeyboardEvent) {
    const cur = active ?? n;
    let next: number | null = null;
    if (e.key === 'ArrowRight') next = Math.min(n - 1, active === null ? 0 : cur + 1);
    else if (e.key === 'ArrowLeft') next = Math.max(0, cur - 1);
    else if (e.key === 'Home') next = 0;
    else if (e.key === 'End') next = n - 1;
    else if (e.key === 'Escape') setActive(null);
    if (next === null) return;
    e.preventDefault();
    setActive(next);
  }

  const activeRow = active !== null ? rows[active] : undefined;
  const activePct = active !== null ? (n > 1 ? (active / (n - 1)) * 100 : 50) : 0;
  const tickYears = pickTicks(rows.map((r) => r.year));

  return (
    <>
      <div className={styles.shareFrame}>
        <div
          className={styles.sharePlot}
          role="group"
          aria-roledescription="stacked area chart"
          aria-label={`${summary} Use arrow keys to read exact shares for each year.`}
          tabIndex={0}
          onKeyDown={onKeyDown}
          onPointerLeave={() => setActive(null)}
          onBlur={() => setActive(null)}
        >
          <svg viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" width="100%" height={H} aria-hidden="true">
            <defs>
              <pattern id="share-hatch" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
                <rect width="2" height="6" fill="var(--mu)" />
              </pattern>
            </defs>
            {bands.map((b) => (
              <path key={b.id} d={b.d} fill={b.hatched ? 'url(#share-hatch)' : b.color} stroke="var(--bg)" strokeWidth="1" vectorEffect="non-scaling-stroke" />
            ))}
            {rows.map((r, i) => (
              <rect
                key={r.year}
                className={styles.yearCol}
                x={Math.max(0, x(i) - W / Math.max(1, n - 1) / 2)}
                width={W / Math.max(1, n - 1)}
                y={0}
                height={H}
                onPointerEnter={() => setActive(i)}
              />
            ))}
          </svg>
          {activeRow && (
            <>
              <div className={styles.selLine} style={{ left: `${activePct}%` }} />
              <div className={styles.readout} style={activePct > 60 ? { right: `calc(${100 - activePct}% + 10px)` } : { left: `calc(${activePct}% + 10px)` }}>
                <div className={styles.readoutTitle}>{activeRow.year}</div>
                {series.map((s) => (
                  <div key={s.id} className={styles.readoutRow}>
                    <span>{s.name}</span>
                    <span>{formatShare(activeRow.shares[s.id] ?? 0)}</span>
                  </div>
                ))}
              </div>
            </>
          )}
          <p className="sr-only" aria-live="polite">
            {activeRow ? `${activeRow.year}: ${series.map((s) => `${s.name} ${formatShare(activeRow.shares[s.id] ?? 0)}`).join(', ')}` : ''}
          </p>
        </div>
        <div className={styles.labels} aria-hidden="true">
          {series.map((s, i) => (
            <span key={s.id} className={styles.label} style={{ top: `${labelPos[i]}%` }}>
              <span className={styles.labelKey} style={{ background: s.hatched ? 'var(--mu)' : s.color }} />
              {s.name}
            </span>
          ))}
        </div>
      </div>
      <div className={styles.xAxis} aria-hidden="true">
        {tickYears.map((t) => {
          const i = rows.findIndex((r) => r.year === t);
          const pct = n > 1 ? (i / (n - 1)) * 100 : 50;
          return (
            <span key={t} style={i === n - 1 ? { right: 0 } : { left: `${pct}%` }}>{t}</span>
          );
        })}
      </div>
    </>
  );
}

/** First, every fifth, and last year, dropping a fifth-year tick that would crowd the last. */
function pickTicks(years: number[]): number[] {
  if (years.length <= 6) return years;
  const out = years.filter((_, i) => i % 5 === 0);
  const last = years[years.length - 1]!;
  if (last - out[out.length - 1]! < 3) out.pop();
  out.push(last);
  return out;
}

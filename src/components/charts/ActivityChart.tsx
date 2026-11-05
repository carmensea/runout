import { useState, type KeyboardEvent } from 'react';
import { useNavigate } from 'react-router-dom';
import type { ActivityBucket } from '../../data/types';
import type { Formatter } from '../../lib/format';
import { niceCeil, ratio, ticksFromTop } from '../../lib/scale';
import styles from './ActivityChart.module.css';

export type Granularity = 'week' | 'month' | 'year';

interface Props {
  buckets: ActivityBucket[];
  granularity: Granularity;
  fmt: Formatter;
  /** Human label for a bucket key, e.g. "March 2014". */
  labelFor(key: string): string;
  /** Short x-axis label for a bucket that should carry a tick, or null. */
  tickFor(key: string, index: number, all: ActivityBucket[]): string | null;
  /** Time Machine link for a bucket. */
  hrefFor(key: string): string;
}

const TICKS = 4;

/**
 * Scrobbles per bucket. Hover previews a bar; click, tap or Enter opens it in Time Machine.
 * Arrow keys move between bars while the plot has focus.
 */
export function ActivityChart({ buckets, granularity, fmt, labelFor, tickFor, hrefFor }: Props) {
  const navigate = useNavigate();
  const [hover, setHover] = useState<number | null>(null);
  const [focusIdx, setFocusIdx] = useState<number | null>(null);

  const n = buckets.length;
  const max = Math.max(0, ...buckets.map((b) => b.scrobbles));
  const ceil = niceCeil(max);
  const ticks = ticksFromTop(ceil, TICKS);
  const gap = n > 50 ? 1 : 6;
  const shown = hover ?? focusIdx;
  const shownBucket = shown !== null ? buckets[shown] : undefined;
  const peak = buckets.reduce((best, b, i) => (b.scrobbles > (buckets[best]?.scrobbles ?? -1) ? i : best), 0);

  function onKeyDown(e: KeyboardEvent) {
    const cur = focusIdx ?? -1;
    let next: number | null = null;
    if (e.key === 'ArrowRight') next = Math.min(n - 1, cur + 1);
    else if (e.key === 'ArrowLeft') next = Math.max(0, cur < 0 ? n - 1 : cur - 1);
    else if (e.key === 'Home') next = 0;
    else if (e.key === 'End') next = n - 1;
    else if ((e.key === 'Enter' || e.key === ' ') && cur >= 0) {
      e.preventDefault();
      navigate(hrefFor(buckets[cur]!.key));
      return;
    }
    if (next === null) return;
    e.preventDefault();
    setFocusIdx(next);
  }

  const leftPct = (i: number) => ((i + 0.5) / n) * 100;
  const tipOnLeft = shown !== null && leftPct(shown) > 70;
  const unit = granularity;
  const summary = n
    ? `Bar chart of scrobbles per ${unit}, ${n} ${unit}s. Highest: ${labelFor(buckets[peak]!.key)} with ${fmt.count(buckets[peak]!.scrobbles)} scrobbles. Use arrow keys to move between bars and Enter to open one in Time Machine.`
    : `No scrobbles to chart.`;

  return (
    <div className={styles.frame}>
      <div className={styles.yAxis} aria-hidden="true">
        {ticks.map((t, i) => (
          <span key={i} style={{ top: `${(i / TICKS) * 100}%` }}>{fmt.count(t)}</span>
        ))}
      </div>
      <div
        className={styles.plot}
        role="group"
        aria-roledescription="bar chart"
        aria-label={summary}
        tabIndex={0}
        onKeyDown={onKeyDown}
        onBlur={(e) => {
          if (!e.currentTarget.contains(e.relatedTarget as Node)) setFocusIdx(null);
        }}
        onPointerLeave={() => setHover(null)}
      >
        <div className={styles.grid} aria-hidden="true">
          {ticks.slice(0, -1).map((_, i) => <div key={i} style={{ top: `${(i / TICKS) * 100}%` }} />)}
        </div>
        <div className={styles.bars} style={{ gap }} aria-hidden="true">
          {buckets.map((b, i) => (
            <div
              key={b.key}
              className={`${styles.slot} ${i === shown ? styles.active : ''}`}
              onPointerEnter={() => setHover(i)}
              onClick={() => navigate(hrefFor(b.key))}
            >
              <div className={styles.bar} style={{ height: `${ratio(b.scrobbles, ceil) * 100}%` }} />
            </div>
          ))}
        </div>
        {shownBucket && shown !== null && (
          <>
            <div className={styles.marker} style={{ left: `${leftPct(shown)}%` }} aria-hidden="true" />
            <div
              className={styles.tooltip}
              style={tipOnLeft ? { right: `calc(${100 - leftPct(shown)}% + 10px)` } : { left: `calc(${leftPct(shown)}% + 10px)` }}
              aria-hidden="true"
            >
              <span className={styles.tooltipTitle}>{labelFor(shownBucket.key)}</span>
              <span className={styles.tooltipValue}>
                {fmt.count(shownBucket.scrobbles)} <small>scrobbles</small>
              </span>
              {shownBucket.topArtist && <span>Top artist: {shownBucket.topArtist}</span>}
            </div>
          </>
        )}
        <p className="sr-only" aria-live="polite">
          {shownBucket ? `${labelFor(shownBucket.key)}: ${fmt.count(shownBucket.scrobbles)} scrobbles${shownBucket.topArtist ? `, top artist ${shownBucket.topArtist}` : ''}.` : ''}
        </p>
      </div>
      <div />
      <div className={styles.xAxis} aria-hidden="true">
        {buckets.map((b, i) => {
          const label = tickFor(b.key, i, buckets);
          if (!label) return null;
          const pos = granularity === 'year' ? { left: `${leftPct(i)}%`, transform: 'translateX(-50%)' } : { left: `${(i / n) * 100}%` };
          return <span key={b.key} style={pos}>{label}</span>;
        })}
      </div>
    </div>
  );
}

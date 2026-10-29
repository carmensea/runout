import { HOUR_TICKS, WEEKDAY_SHORT } from '../../lib/dates';
import { quantileBucketer } from '../../lib/scale';
import styles from './Charts.module.css';

/** Accent opacity per quantile step (HANDOFF.md: 5 steps, zero = --s1). */
const HEAT_RAMP = [0.12, 0.3, 0.5, 0.75, 1];

interface Props {
  /** 7 rows (Monday first) × 24 hours. */
  values: number[][];
  format(n: number): string;
  summary: string;
}

export function Heatmap({ values, format, summary }: Props) {
  const bucket = quantileBucketer(values.flat(), HEAT_RAMP.length);
  return (
    <div className={styles.heatGrid} role="img" aria-label={summary}>
      {WEEKDAY_SHORT.map((d, di) => (
        <div key={d} style={{ display: 'contents' }}>
          <span className={styles.heatDay} aria-hidden="true">{d}</span>
          <div className={styles.heatRow} aria-hidden="true">
            {(values[di] ?? []).map((v, h) => {
              const q = bucket(v);
              return (
                <div
                  key={h}
                  className={styles.heatCell}
                  title={`${d} ${String(h).padStart(2, '0')}:00, ${format(v)} scrobbles`}
                  style={{ background: q < 0 ? 'var(--s1)' : 'var(--ac)', opacity: q < 0 ? 1 : HEAT_RAMP[q] }}
                />
              );
            })}
          </div>
        </div>
      ))}
      <span />
      <div className={styles.axis} style={{ marginTop: 4 }} aria-hidden="true">
        {HOUR_TICKS.map((l) => <span key={l}>{l}</span>)}
      </div>
    </div>
  );
}

export function HeatRamp() {
  return (
    <div className={styles.ramp} aria-hidden="true">
      <span>Fewer</span>
      {HEAT_RAMP.map((o) => <span key={o} className={styles.rampStep} style={{ background: 'var(--ac)', opacity: o }} />)}
      <span>More</span>
    </div>
  );
}

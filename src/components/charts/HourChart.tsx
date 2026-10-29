import { HOUR_TICKS } from '../../lib/dates';
import { ratio } from '../../lib/scale';
import styles from './Charts.module.css';

interface Props {
  values: number[];
  compare: number[] | null;
  summary: string;
}

/** 24 bars; the busiest hour inverts to --fg. Comparison adds an outlined bar beside each. */
export function HourChart({ values, compare, summary }: Props) {
  const max = Math.max(0, ...values, ...(compare ?? []));
  const peak = values.indexOf(Math.max(...values));
  return (
    <>
      <div className={styles.hourPlot} role="img" aria-label={summary}>
        {values.map((v, h) => (
          <div key={h} className={styles.hourSlot}>
            <div style={{ height: `${ratio(v, max) * 95}%`, background: h === peak ? 'var(--fg)' : 'var(--ac)' }} />
            {compare && <div className={styles.outlineBar} style={{ height: `${ratio(compare[h] ?? 0, max) * 95}%` }} />}
          </div>
        ))}
      </div>
      <div className={styles.axis} aria-hidden="true">
        {HOUR_TICKS.map((l) => <span key={l}>{l}</span>)}
      </div>
    </>
  );
}

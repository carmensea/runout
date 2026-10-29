import { WEEKDAY_SHORT } from '../../lib/dates';
import { ratio } from '../../lib/scale';
import styles from './Charts.module.css';

interface Props {
  values: number[];
  compare: number[] | null;
  format(n: number): string;
  summary: string;
}

/** Horizontal bars, Monday first. The busiest day inverts to --fg. */
export function WeekdayBars({ values, compare, format, summary }: Props) {
  const max = Math.max(0, ...values, ...(compare ?? []));
  const peak = values.indexOf(Math.max(...values));
  return (
    <div role="img" aria-label={summary}>
      {WEEKDAY_SHORT.map((d, i) => (
        <div key={d} className={styles.weekRow} aria-hidden="true">
          <span className={styles.weekLabel}>{d}</span>
          <div className={styles.weekBars}>
            <div style={{ height: 10, width: `${ratio(values[i] ?? 0, max) * 100}%`, background: i === peak ? 'var(--fg)' : 'var(--ac)' }} />
            {compare && <div style={{ height: 6, width: `${ratio(compare[i] ?? 0, max) * 100}%`, border: '1.5px solid var(--fg2)' }} />}
          </div>
          <span className={`${styles.mono12} ${styles.right}`}>{format(values[i] ?? 0)}</span>
        </div>
      ))}
    </div>
  );
}

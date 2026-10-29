import { ratio } from '../../lib/scale';
import styles from './Charts.module.css';

const INITIALS = ['J', 'F', 'M', 'A', 'M', 'J', 'J', 'A', 'S', 'O', 'N', 'D'];
const SEASONS = {
  northern: ['Winter', 'Spring', 'Summer', 'Autumn'],
  southern: ['Summer', 'Autumn', 'Winter', 'Spring'],
};

interface Props {
  /** Average scrobbles per day, January first. */
  values: number[];
  hemisphere: 'northern' | 'southern';
  summary: string;
}

/** 12 bars; the highest month inverts to --fg, others --fg2. Season bands follow the hemisphere. */
export function SeasonalChart({ values, hemisphere, summary }: Props) {
  const max = Math.max(0, ...values);
  const peak = values.indexOf(max);
  return (
    <div role="img" aria-label={summary}>
      <div className={styles.seasonPlot} aria-hidden="true">
        {values.map((v, i) => (
          <div key={i} style={{ height: `${ratio(v, max) * 95}%`, background: i === peak ? 'var(--fg)' : 'var(--fg2)' }} />
        ))}
      </div>
      <div className={styles.months12} aria-hidden="true">
        {INITIALS.map((m, i) => <span key={i}>{m}</span>)}
      </div>
      <div className={styles.seasons} aria-hidden="true">
        {SEASONS[hemisphere].map((s) => <span key={s}>{s}</span>)}
      </div>
    </div>
  );
}

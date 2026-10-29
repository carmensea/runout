import { Link } from 'react-router-dom';
import { ratio } from '../../lib/scale';
import styles from './Charts.module.css';

export interface RankedItem {
  key: string;
  label: string;
  value: string;
  amount: number;
  href: string;
  /** Accessible description of the row's destination. */
  linkLabel: string;
}

/** Top-N rows with an inline bar scaled to the first row. Each row links to its period. */
export function RankedBars({ items }: { items: RankedItem[] }) {
  const max = items[0]?.amount ?? 0;
  return (
    <ol style={{ margin: 0, padding: 0, listStyle: 'none' }}>
      {items.map((it, i) => (
        <li key={it.key}>
          <Link to={it.href} className={styles.rankRow} aria-label={it.linkLabel}>
            <span className={styles.rank}>{i + 1}</span>
            <span className={styles.mono12}>{it.label}</span>
            <div className={styles.track6} aria-hidden="true">
              <div style={{ width: `${ratio(it.amount, max) * 100}%`, background: 'var(--fg2)' }} />
            </div>
            <span className={`${styles.mono12} ${styles.right}`}>{it.value}</span>
          </Link>
        </li>
      ))}
    </ol>
  );
}

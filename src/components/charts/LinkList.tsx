import { Link } from 'react-router-dom';
import { Heart } from '../ui/Heart';
import styles from './MoreCharts.module.css';

export interface LinkListItem {
  key: string;
  href: string;
  primary: string;
  meta: string;
  /** A loved song: shows the heart beside the name. */
  loved?: boolean;
}

/** Short ranked list of links: name over mono meta, or name and meta on one row. */
export function LinkList({ items, empty, inline }: { items: LinkListItem[]; empty: string; inline?: boolean }) {
  if (items.length === 0) {
    return <p className="caption" style={{ padding: '10px 0', borderTop: '1px solid var(--ln)' }}>{empty}</p>;
  }
  return (
    <ul style={{ margin: 0, padding: 0, listStyle: 'none' }}>
      {items.map((i) => (
        <li key={i.key}>
          <Link to={i.href} className={inline ? styles.inlineLink : styles.stackLink}>
            <span className={styles.primary}>{i.primary}{i.loved && <Heart />}</span>
            <span className={styles.meta}>{i.meta}</span>
          </Link>
        </li>
      ))}
    </ul>
  );
}

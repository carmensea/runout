import { useMemo, useRef, useState } from 'react';
import { NavLink, useLocation } from 'react-router-dom';
import { useNav } from '../../app/useNav';
import { useDismiss } from '../../hooks/useDismiss';
import { usePeriod } from '../../state/PeriodContext';
import { Icon } from '../ui/Icon';
import styles from './MobileNav.module.css';

const PRIMARY = ['overview', 'time', 'artists'];
const ICONS: Record<string, string> = { overview: 'bar_chart', time: 'history', artists: 'person' };

/** Bottom bar below 768px: Overview, Time Machine, Artists, More. */
export function MobileNav() {
  const { withPeriod } = usePeriod();
  const { pathname } = useLocation();
  const [moreOpen, setMoreOpen] = useState(false);
  const ref = useRef<HTMLElement>(null);
  const refs = useMemo(() => [ref], []);
  useDismiss(moreOpen, () => setMoreOpen(false), refs);

  const { items } = useNav();
  const primary = items.filter((i) => PRIMARY.includes(i.id));
  const more = items.filter((i) => !PRIMARY.includes(i.id));
  const moreActive = more.some((i) => pathname.startsWith(i.path));

  return (
    <nav ref={ref} aria-label="Primary, compact" className={styles.nav}>
      {primary.map((i) => (
        <NavLink key={i.id} to={withPeriod(i.path)} className={styles.item} onClick={() => setMoreOpen(false)}>
          <Icon name={ICONS[i.id] ?? 'circle'} size={22} />
          {i.label}
        </NavLink>
      ))}
      <button
        type="button"
        className={styles.item}
        aria-expanded={moreOpen}
        aria-controls="mobile-more"
        aria-current={moreActive ? 'page' : undefined}
        onClick={() => setMoreOpen((o) => !o)}
      >
        <Icon name="more_horiz" size={22} />
        More
      </button>
      {moreOpen && (
        <ul id="mobile-more" className={styles.more}>
          {more.map((i) => (
            <li key={i.id}>
              <NavLink to={withPeriod(i.path)} onClick={() => setMoreOpen(false)}>
                <span className={styles.number}>{i.number}</span>
                {i.label}
                {i.group === 'planned' && <span className="eyebrow">Later</span>}
              </NavLink>
            </li>
          ))}
        </ul>
      )}
    </nav>
  );
}

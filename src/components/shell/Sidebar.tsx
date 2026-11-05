import { Link, NavLink } from 'react-router-dom';
import { NAV_ITEMS, type NavItem } from '../../app/navigation';
import { useAppData } from '../../data/AppDataContext';
import { todayIn } from '../../lib/dates';
import { usePeriod } from '../../state/PeriodContext';
import { Icon } from '../ui/Icon';
import { BrandMark } from './BrandMark';
import styles from './Sidebar.module.css';

function Item({ item }: { item: NavItem }) {
  const { withPeriod } = usePeriod();
  return (
    <li>
      <NavLink to={withPeriod(item.path)} className={styles.item} aria-label={item.label} title={item.label}>
        <span className={styles.number}>{item.number}</span>
        <span className={styles.label}>{item.label}</span>
        {item.group === 'planned' && <span className={styles.later}>Later</span>}
      </NavLink>
    </li>
  );
}

export function Sidebar() {
  const listening = NAV_ITEMS.filter((i) => i.group === 'listening');
  const planned = NAV_ITEMS.filter((i) => i.group === 'planned');
  const settings = NAV_ITEMS.filter((i) => i.group === 'settings');

  return (
    <nav aria-label="Primary" className={styles.nav}>
      <Link to="/" className={styles.brand} aria-label="Runout home">
        <BrandMark />
        <span className={styles.wordmark}>Runout</span>
      </Link>
      <div className={styles.group}>
        <div id="nav-listening" className={`eyebrow ${styles.groupLabel}`}>Listening</div>
        <ul className={styles.list} aria-labelledby="nav-listening">
          {listening.map((i) => <Item key={i.id} item={i} />)}
        </ul>
      </div>
      <div className={styles.group}>
        <div id="nav-planned" className={`eyebrow ${styles.groupLabel}`}>Planned</div>
        <ul className={styles.list} aria-labelledby="nav-planned">
          {planned.map((i) => <Item key={i.id} item={i} />)}
        </ul>
      </div>
      <div className={styles.spacer} />
      <div className={`${styles.group} ${styles.bottom}`}>
        <ul className={styles.list}>
          {settings.map((i) => <Item key={i.id} item={i} />)}
        </ul>
      </div>
      <AccountStatus />
    </nav>
  );
}

/** Sidebar footer mirrors the Settings connection state. */
function AccountStatus() {
  const { connection, fmt, timeZone } = useAppData();
  const { withPeriod } = usePeriod();
  const to = withPeriod('/settings#lastfm');

  if (connection.status === 'loading') {
    return (
      <div className={styles.account} role="status">
        <div className={styles.who}>
          <div className={styles.avatar} />
          <div className={styles.whoText}><span className={styles.status}>Checking Last.fm</span></div>
        </div>
      </div>
    );
  }

  if (connection.status === 'error') {
    return (
      <Link to={to} className={styles.account} title="Connection status unavailable">
        <div className={styles.who}>
          <div className={styles.avatar}><Icon name="error" size={16} /></div>
          <div className={styles.whoText}>
            <span className={styles.username}>Status unavailable</span>
            <span className={styles.status}>Could not reach Runout</span>
          </div>
        </div>
      </Link>
    );
  }

  const c = connection.data;
  const syncedLabel = (at: string) => {
    const day = fmt.dateTime(at, timeZone).slice(0, 10);
    return day === todayIn(timeZone) ? `Synced today, ${fmt.time(at, timeZone)}` : `Synced ${fmt.dateTime(at, timeZone)}`;
  };
  if (c.status === 'signed_out') {
    return (
      <Link to={withPeriod('/overview')} className={styles.account} title="Not signed in">
        <div className={styles.who}>
          <div className={styles.avatar}><Icon name="person_off" size={16} /></div>
          <div className={styles.whoText}>
            <span className={styles.username}>Not signed in</span>
            <span className={styles.status}>Sign in to see your listening</span>
          </div>
        </div>
      </Link>
    );
  }

  const lastfm = c.status === 'none' ? 'Last.fm not connected' : 'Last.fm connected';
  return (
    <Link to={to} className={styles.account} title={`${c.displayName}, ${lastfm}`}>
      <div className={styles.who}>
        <div className={styles.avatar} aria-hidden="true">{c.displayName.charAt(0).toUpperCase()}</div>
        <div className={styles.whoText}>
          <span className={styles.username}>{c.displayName}</span>
          <span className={styles.status}>{lastfm}</span>
        </div>
      </div>
      {c.status === 'synced' && (
        <div className={styles.syncLine}>
          <span className={styles.dot} style={{ background: c.syncPaused ? 'var(--mu)' : 'var(--c3)' }} />
          <span>{c.syncPaused ? 'Sync paused' : syncedLabel(c.lastSyncedAt)}</span>
        </div>
      )}
      {c.status === 'failed' && (
        <div className={styles.syncLine}>
          <span className={styles.dot} style={{ background: 'var(--err)' }} />
          <span>Import failed</span>
        </div>
      )}
      {c.status === 'importing' && (
        <div className={styles.progress}>
          <div className={styles.progressHead}>
            <span>Importing history</span>
            <span>{fmt.percent(c.progress)}</span>
          </div>
          <div className={styles.track} role="progressbar" aria-label="Import progress" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(c.progress * 100)}>
            <div className={styles.fill} style={{ width: `${c.progress * 100}%` }} />
          </div>
        </div>
      )}
    </Link>
  );
}

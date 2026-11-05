import { Link, Outlet } from 'react-router-dom';
import { useMediaQuery } from '../../hooks/useMediaQuery';
import { useAppData } from '../../data/AppDataContext';
import { BarBanner, PeriodBar } from '../period/PeriodBar';
import { MobileHeader } from './MobileHeader';
import { MobileNav } from './MobileNav';
import { Sidebar } from './Sidebar';
import { Sky } from './Sky';
import styles from './AppShell.module.css';

export function AppShell() {
  const compact = useMediaQuery('(max-width: 767px)');
  return (
    <div className={styles.shell}>
      <Sky />
      <a href="#main" className={styles.skip}>Skip to content</a>
      <Sidebar />
      <div className={styles.column}>
        {compact ? <MobileHeader banner={<GlobalBanner />} /> : <PeriodBar banner={<GlobalBanner />} />}
        <Outlet />
      </div>
      <MobileNav />
    </div>
  );
}

/** The slot under the period bar: specimen notice in development, import state otherwise. */
function GlobalBanner() {
  const { specimen, connection, fmt } = useAppData();
  if (specimen) {
    return (
      <BarBanner tag="Specimen">
        Figures render as zeros, names as numbered placeholders, and chart shapes are structural. None of this is listening data.
      </BarBanner>
    );
  }
  if (connection.status !== 'success') return null;
  const c = connection.data;
  if (c.status === 'importing') {
    return (
      <BarBanner tag="Importing">
        Importing your Last.fm history, {fmt.percent(c.progress)} done.
        {c.attention ? <> {c.attention === 1 ? '1 item needs' : `${c.attention} items need`} your attention. <Link to="/settings#review">Review in Settings</Link></> : null}
      </BarBanner>
    );
  }
  if (c.status === 'failed') {
    return (
      <BarBanner tag="Import failed">
        {c.message} Imported scrobbles are kept. <Link to="/settings#history">Open Settings</Link>
      </BarBanner>
    );
  }
  // Only what needs the owner: review items and problems, never background work.
  if (c.status === 'synced' && c.attention) {
    return (
      <BarBanner tag="Needs attention">
        {c.attention === 1 ? '1 item in your history needs your attention.' : `${c.attention} items in your history need your attention.`}{' '}
        <Link to="/settings#review">Review in Settings</Link>
      </BarBanner>
    );
  }
  if (c.status === 'synced' && c.syncPaused) {
    return (
      <BarBanner tag="Sync paused">
        Automatic sync is paused, so new scrobbles aren’t being added. <Link to="/settings#history">Resume in Settings</Link>
      </BarBanner>
    );
  }
  return null;
}

import { useState } from 'react';
import { Link, Navigate, Outlet, useLocation, useNavigate } from 'react-router-dom';
import { useMediaQuery } from '../../hooks/useMediaQuery';
import { useAppData } from '../../data/AppDataContext';
import { useAccountTheme } from '../../theme/useTheme';
import { BarBanner, PeriodBar } from '../period/PeriodBar';
import { MobileHeader } from './MobileHeader';
import { MobileNav } from './MobileNav';
import { Sidebar } from './Sidebar';
import { Sky } from './Sky';
import styles from './AppShell.module.css';

export function AppShell() {
  const compact = useMediaQuery('(max-width: 767px)');
  const { auth } = useAppData();
  const { pathname } = useLocation();
  useAccountTheme();
  // An invited account is complete only once it has a passkey (and so its recovery codes): until
  // then every page is the onboarding page. Accounts with Last.fm sign-in are never sent there.
  const session = auth.status === 'success' ? auth.data : null;
  const onboarding = session?.signedIn === true && session.methods.passkeys === 0 && !session.methods.lastfm;
  if (onboarding && pathname !== '/welcome') return <Navigate to="/welcome" replace />;
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
  const { specimen, connection, fmt, operator } = useAppData();
  if (operator) return <OperatorBanner until={operator.expiresAt} />;
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

/**
 * The operator's read-only look at an account (auth:sign_in_as): on every page, so it is never
 * mistaken for the person's own session. The server refuses every write; this says so and offers
 * the one write allowed, ending the session.
 */
function OperatorBanner({ until }: { until: string }) {
  const { api, connection, auth, fmt, timeZone } = useAppData();
  const navigate = useNavigate();
  const [state, setState] = useState<'idle' | 'busy' | 'error'>('idle');
  const c = connection.status === 'success' && connection.data.status !== 'signed_out' ? connection.data : null;
  async function end() {
    setState('busy');
    try {
      await api.signOut();
      connection.retry();
      auth.retry();
      navigate('/overview');
    } catch {
      setState('error');
    }
  }
  return (
    <BarBanner tag="Operator view">
      Signed in as {c?.displayName ?? 'this person'} to see what they see. Read-only: nothing can be changed, and memory words are placeholders. Ends {fmt.time(until, timeZone)}.{' '}
      <button type="button" className={styles.bannerButton} onClick={end} disabled={state === 'busy'}>{state === 'busy' ? 'Ending' : 'End operator session'}</button>
      {state === 'error' && <> Ending it failed; try again.</>}
    </BarBanner>
  );
}

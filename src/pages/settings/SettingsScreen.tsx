import { useEffect, useId, useState } from 'react';
import { Link, useLocation, useNavigate } from 'react-router-dom';
import { Tabs } from '../../components/ui/Tabs';
import { SignIn } from '../../components/auth/SignIn';
import stateStyles from '../../components/states/States.module.css';
import { useAppData } from '../../data/AppDataContext';
import type { ConnectedState } from '../../data/types';
import { usePeriod } from '../../state/PeriodContext';
import styles from '../PendingScreen.module.css';
import { HistorySection } from './HistorySection';
import { ReviewSection } from './ReviewSection';
import { SignInSection } from './SignInSection';
import { AppearancePanel } from './AppearancePanel';
import { SourcesSection } from './SourcesSection';
import settings from './Settings.module.css';

const TABS = [
  { id: 'sources', label: 'Sources' },
  { id: 'history', label: 'History' },
  { id: 'review', label: 'Review' },
  { id: 'appearance', label: 'Appearance' },
  { id: 'account', label: 'Account' },
] as const;
type Tab = (typeof TABS)[number]['id'];
/** Hashes that links elsewhere in the app use; each opens the tab that holds that panel. */
const HASH_TAB: Record<string, Tab> = {
  spotify: 'sources', 'sign-in': 'account', passkeys: 'account', 'recovery-codes': 'account', sessions: 'account', lastfm: 'account', data: 'account',
};
const isTab = (h: string): h is Tab => TABS.some((t) => t.id === h);

/**
 * Settings: listening sources (Last.fm, Spotify), the listening-history import and sync,
 * differences to review, appearance, and the account (sign-in, sign out, delete): one tab each,
 * chosen by the URL hash. Preferences, metadata coverage and export arrive later.
 */
export function SettingsScreen() {
  const { api, connection, auth } = useAppData();
  const navigate = useNavigate();
  const location = useLocation();
  const { withPeriod } = usePeriod();
  // The hash is the tab, so links like /settings#review open the right one and reload keeps it.
  const hash = location.hash.slice(1);
  const tab: Tab = HASH_TAB[hash] ?? (isTab(hash) ? hash : 'sources');
  const openTab = (id: Tab) => navigate({ search: location.search, hash: `#${id}` }, { replace: true });

  useEffect(() => {
    document.title = 'Settings · Runout';
  }, []);
  const [state, setState] = useState<'idle' | 'busy' | 'error'>('idle');
  // While the connection reloads (after any action here), keep showing the account it last
  // reported, so the sections below don't unmount and lose what they show.
  const current = connection.status === 'success' ? (connection.data.status !== 'none' ? connection.data : null) : undefined;
  const [lastKnown, setLastKnown] = useState<ConnectedState | null>(null);
  if (current !== undefined && current !== lastKnown) setLastKnown(current);
  const signedIn = current === undefined ? lastKnown : current;
  const attention = signedIn && 'attention' in signedIn ? signedIn.attention : undefined;
  // Likewise for Runout's own sign-in: while it reloads after an action, keep the section mounted.
  const [authOn, setAuthOn] = useState(false);
  if (auth.status === 'success' && (auth.data !== null) !== authOn) setAuthOn(auth.data !== null);
  const [deletedRevokeUrl, setDeletedRevokeUrl] = useState<string | null>(null);

  async function signOut() {
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
    <main id="main" className={settings.main}>
      <div className="eyebrow">08 / Settings</div>
      <h1 className={settings.title}>Settings</h1>
      {!signedIn && !deletedRevokeUrl && (
        <p className={settings.lede}>Sign in to see your listening history and manage it here.</p>
      )}
      {!signedIn && !deletedRevokeUrl && authOn && (
        <div className={settings.panel} id="sign-in">
          <SignIn lastfmUrl={api.signInUrl()} align="left" />
        </div>
      )}
      {signedIn && (
        <Tabs
          idBase="settings"
          label="Settings"
          className={settings.tabs}
          tabs={TABS.map((t) => (t.id === 'review' && attention ? { ...t, label: `Review ${attention}` } : t))}
          value={tab}
          onChange={openTab}
        />
      )}
      <div id="settings-panel" role={signedIn ? 'tabpanel' : undefined} aria-labelledby={signedIn ? `settings-tab-${tab}` : undefined} className={signedIn ? settings.tabpanel : undefined}>
      {signedIn && tab === 'sources' && (
        <section className={settings.section} id="sources" aria-labelledby="sources-title">
          <h2 id="sources-title" className={settings.h2}>Listening sources</h2>
          <SourcesSection />
        </section>
      )}
      {signedIn && tab === 'history' && (
        <section className={settings.section} id="history" aria-labelledby="history-title">
          <h2 id="history-title" className={settings.h2}>Listening history</h2>
          <HistorySection onChanged={connection.retry} />
        </section>
      )}
      {signedIn && tab === 'review' && (
        <section className={settings.section} id="review" aria-labelledby="review-title">
          <h2 id="review-title" className={settings.h2}>To review</h2>
          <ReviewSection onChanged={connection.retry} />
        </section>
      )}
      {(!signedIn || tab === 'appearance') && (
      <section className={settings.section} id="appearance" aria-labelledby="appearance-title">
        <h2 id="appearance-title" className={settings.h2}>Appearance</h2>
        <p className={settings.lede}>Five looks for the same Runout. The choice is kept in this browser.</p>
        <AppearancePanel />
      </section>
      )}
      {signedIn && authOn && tab === 'account' && (
        <section className={settings.section} id="sign-in" aria-labelledby="sign-in-title">
          <h2 id="sign-in-title" className={settings.h2}>Sign-in</h2>
          <SignInSection />
        </section>
      )}
      {(!signedIn || tab === 'account') && (
      <section className={settings.section} aria-labelledby="account-title">
        <h2 id="account-title" className={settings.h2}>Account</h2>
      {deletedRevokeUrl && (
        <div className={settings.panel} role="status">
          <strong style={{ color: 'var(--fg)', fontWeight: 600 }}>Your Runout account and its data were deleted.</strong>
          <span>
            Runout cannot remove its own access on Last.fm. To do that, open your{' '}
            <a href={deletedRevokeUrl} target="_blank" rel="noreferrer">Last.fm application settings</a> and remove Runout.
          </span>
        </div>
      )}
      {signedIn && (
        <div className={settings.panel} id="lastfm">
          <span>Signed in with Last.fm as <strong style={{ color: 'var(--fg)', fontWeight: 600 }}>{signedIn.username}</strong>.</span>
          <span>Reporting timezone: {signedIn.timezone.replace(/_/g, ' ')}. Hour and weekday patterns assume this timezone for your whole history.</span>
          <div className={stateStyles.actions}>
            <button type="button" className={stateStyles.secondary} onClick={signOut} disabled={state === 'busy'}>
              {state === 'busy' ? 'Signing out' : 'Sign out'}
            </button>
          </div>
          {state === 'error' && <p role="alert" style={{ color: 'var(--err)', margin: 0 }}>Sign-out failed. Try again.</p>}
        </div>
      )}
      {signedIn && (
        <DeleteAccount
          username={signedIn.username}
          onDeleted={(revokeUrl) => {
            setDeletedRevokeUrl(revokeUrl);
            connection.retry();
          }}
        />
      )}
      </section>
      )}
      </div>
      <p className={settings.note} style={{ marginTop: 32 }}>Preferences, metadata coverage and data export arrive in later versions.</p>
      <Link to={withPeriod('/overview')} className={styles.back}>Back to Overview</Link>
    </main>
  );
}

function DeleteAccount({ username, onDeleted }: { username: string; onDeleted(revokeUrl: string): void }) {
  const { api } = useAppData();
  const inputId = useId();
  const [typed, setTyped] = useState('');
  const [state, setState] = useState<'idle' | 'busy' | 'error'>('idle');
  const matches = typed.trim().toLowerCase() === username.toLowerCase();

  async function remove() {
    setState('busy');
    try {
      const { revokeAccessUrl } = await api.deleteAccount(typed.trim());
      onDeleted(revokeAccessUrl);
    } catch {
      setState('error');
    }
  }

  return (
    <section className={settings.panel} id="data" aria-labelledby={`${inputId}-title`}>
      <strong id={`${inputId}-title`} style={{ color: 'var(--fg)', fontWeight: 600 }}>Delete account</strong>
      <span>
        Deletes your Runout account and everything stored for it, including the Last.fm access key. This cannot be undone.
      </span>
      <label className={styles.field} htmlFor={inputId}>
        Type your Last.fm username, {username}, to confirm
        <input
          id={inputId}
          className={styles.input}
          value={typed}
          autoComplete="off"
          spellCheck={false}
          onChange={(e) => setTyped(e.target.value)}
        />
      </label>
      <button type="button" className={styles.danger} disabled={!matches || state === 'busy'} onClick={remove}>
        {state === 'busy' ? 'Deleting' : 'Delete account'}
      </button>
      {state === 'error' && <p role="alert" style={{ color: 'var(--err)', margin: 0 }}>Deletion did not complete. Check your connection and try again.</p>}
    </section>
  );
}

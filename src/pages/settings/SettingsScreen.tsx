import { useEffect, useId, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import stateStyles from '../../components/states/States.module.css';
import { useAppData } from '../../data/AppDataContext';
import type { ConnectedState } from '../../data/types';
import { usePeriod } from '../../state/PeriodContext';
import styles from '../PendingScreen.module.css';
import { HistorySection } from './HistorySection';
import { ReviewSection } from './ReviewSection';
import settings from './Settings.module.css';

/**
 * Settings: the listening-history import and sync, differences to review, and the account
 * (sign out, delete). Preferences, metadata coverage and export arrive later.
 */
export function SettingsScreen() {
  const { api, connection } = useAppData();
  const navigate = useNavigate();
  const { withPeriod } = usePeriod();

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
  const [deletedRevokeUrl, setDeletedRevokeUrl] = useState<string | null>(null);

  async function signOut() {
    setState('busy');
    try {
      await api.signOut();
      connection.retry();
      navigate('/overview');
    } catch {
      setState('error');
    }
  }

  return (
    <main id="main" className={settings.main}>
      <div className="eyebrow">07 / Settings</div>
      <h1 className={settings.title}>Settings</h1>
      {!signedIn && !deletedRevokeUrl && (
        <p className={settings.lede}>Sign in with Last.fm to import your listening history and manage it here.</p>
      )}
      {signedIn && (
        <section className={settings.section} id="history" aria-labelledby="history-title">
          <h2 id="history-title" className={settings.h2}>Listening history</h2>
          <HistorySection onChanged={connection.retry} />
        </section>
      )}
      {signedIn && (
        <section className={settings.section} id="review" aria-labelledby="review-title">
          <h2 id="review-title" className={settings.h2}>To review</h2>
          <ReviewSection onChanged={connection.retry} />
        </section>
      )}
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

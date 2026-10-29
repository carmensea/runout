import { useId, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import stateStyles from '../components/states/States.module.css';
import { useAppData } from '../data/AppDataContext';
import { PendingScreen } from './PendingScreen';
import styles from './PendingScreen.module.css';

/**
 * Settings is designed but not built. Until it is, this keeps the controls authentication
 * needs: signing out, and deleting the account and everything stored for it.
 */
export function SettingsScreen() {
  const { api, connection } = useAppData();
  const navigate = useNavigate();
  const [state, setState] = useState<'idle' | 'busy' | 'error'>('idle');
  const signedIn = connection.status === 'success' && connection.data.status !== 'none' ? connection.data : null;
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
    <PendingScreen
      eyebrow="07 / Settings"
      title="Settings"
      description="Last.fm connection and import, metadata coverage, preferences such as timezone, account and data export."
    >
      {deletedRevokeUrl && (
        <div className={styles.panel} role="status">
          <strong style={{ color: 'var(--fg)', fontWeight: 600 }}>Your Runout account and its data were deleted.</strong>
          <span>
            Runout cannot remove its own access on Last.fm. To do that, open your{' '}
            <a href={deletedRevokeUrl} target="_blank" rel="noreferrer">Last.fm application settings</a> and remove Runout.
          </span>
        </div>
      )}
      {signedIn && (
        <div className={styles.panel} id="lastfm">
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
    </PendingScreen>
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
    <section className={styles.panel} id="data" aria-labelledby={`${inputId}-title`}>
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

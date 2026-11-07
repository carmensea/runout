import { useState, type FormEvent } from 'react';
import { useNavigate } from 'react-router-dom';
import { ApiError } from '../../data/api';
import { useAppData } from '../../data/AppDataContext';
import { PasskeyCancelledError, PasskeyUnsupportedError, passkeysSupported } from '../../lib/webauthn';
import stateStyles from '../states/States.module.css';
import styles from './SignIn.module.css';

const SIGN_IN_ERRORS: Record<string, string> = {
  passkey_rejected: 'That passkey wasn’t accepted. Try again, or use a recovery code.',
  challenge_expired: 'That took too long. Try again.',
  code_rejected: 'That recovery code isn’t valid. Each code works once.',
  rate_limited: 'Too many attempts. Wait a while and try again.',
};

function describe(e: unknown): string {
  if (e instanceof PasskeyCancelledError) return 'The passkey prompt was closed before it finished.';
  if (e instanceof PasskeyUnsupportedError) return e.message;
  const known = e instanceof ApiError && e.code ? SIGN_IN_ERRORS[e.code] : undefined;
  if (known) return known;
  return 'Sign-in didn’t complete. Check your connection and try again.';
}

/**
 * The ways in: a passkey, a recovery code, and Last.fm while it remains the fallback. Shown only
 * when the server has Runout's own sign-in switched on; otherwise the Last.fm link stands alone.
 * After a recovery code, Settings is opened so a new passkey can be added.
 */
export function SignIn({ lastfmUrl, align = 'center' }: { lastfmUrl: string | null; align?: 'center' | 'left' }) {
  const { api, connection, auth } = useAppData();
  const navigate = useNavigate();
  const [busy, setBusy] = useState<'passkey' | 'code' | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [showCode, setShowCode] = useState(false);
  const [code, setCode] = useState('');
  const supported = passkeysSupported();

  async function run(kind: 'passkey' | 'code', action: () => Promise<unknown>, then?: () => void) {
    setBusy(kind);
    setError(null);
    try {
      await action();
      auth.retry();
      connection.retry();
      then?.();
    } catch (e) {
      setError(describe(e));
    } finally {
      setBusy(null);
    }
  }

  function submitCode(event: FormEvent) {
    event.preventDefault();
    if (!code.trim()) return;
    void run('code', () => api.auth.signInWithRecoveryCode(code.trim()), () => navigate('/settings?recovered=1#sign-in'));
  }

  return (
    <div className={`${styles.choices} ${align === 'left' ? styles.left : ''}`}>
      {!supported && <p className={styles.error}>This browser can’t use passkeys here. Use a recovery code or Last.fm.</p>}
      {error && <p className={styles.error} role="alert">{error}</p>}
      <div className={styles.actions}>
        <button type="button" className={`${stateStyles.primary} ${styles.button}`} disabled={busy !== null || !supported} onClick={() => run('passkey', () => api.auth.signInWithPasskey())}>
          {busy === 'passkey' ? 'Waiting for your passkey' : 'Sign in with a passkey'}
        </button>
        {lastfmUrl && (
          // A full page navigation: the server redirects to Last.fm.
          <a href={lastfmUrl} className={`${stateStyles.secondary} ${styles.button}`}>Sign in with Last.fm</a>
        )}
      </div>
      {lastfmUrl && (
        <p className={`caption ${styles.caption}`}>Last.fm sign-in is for the archive’s owner. Invited people sign in with a passkey.</p>
      )}
      {showCode ? (
        <form className={styles.code} onSubmit={submitCode}>
          <input
            className={styles.input}
            aria-label="Recovery code"
            placeholder="xxxxx-xxxxx"
            autoComplete="one-time-code"
            spellCheck={false}
            value={code}
            onChange={(e) => setCode(e.target.value)}
          />
          <button type="submit" className={`${stateStyles.secondary} ${styles.button}`} disabled={busy !== null || !code.trim()}>
            {busy === 'code' ? 'Checking' : 'Use code'}
          </button>
        </form>
      ) : (
        <button type="button" className={styles.toggle} onClick={() => setShowCode(true)}>Use a recovery code instead</button>
      )}
    </div>
  );
}

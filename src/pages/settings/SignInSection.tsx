import { useId, useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import stateStyles from '../../components/states/States.module.css';
import { ApiError } from '../../data/api';
import { useAppData } from '../../data/AppDataContext';
import type { BrowserSession, Passkey } from '../../data/types';
import { useAsync } from '../../data/useAsync';
import { PasskeyCancelledError, PasskeyUnsupportedError, passkeysSupported } from '../../lib/webauthn';
import pending from '../PendingScreen.module.css';
import styles from './Settings.module.css';

const ERRORS: Record<string, string> = {
  passkey_rejected: 'The browser’s passkey wasn’t accepted. Try again.',
  challenge_expired: 'That took too long. Try again.',
  last_passkey: 'This is your only passkey and you have no recovery codes, so it has to stay. Generate recovery codes first.',
  rate_limited: 'Too many attempts. Wait a while and try again.',
};

function describe(e: unknown): string {
  if (e instanceof PasskeyCancelledError) return 'The passkey prompt was closed before it finished.';
  if (e instanceof PasskeyUnsupportedError) return e.message;
  const known = e instanceof ApiError && e.code ? ERRORS[e.code] : undefined;
  if (known) return known;
  return 'That didn’t work. Check your connection and try again.';
}

/**
 * Settings → Sign-in: passkeys (add, remove), recovery codes (shown once, regenerable) and other
 * signed-in browsers. Last.fm stays available as a sign-in until the owner retires it, and its
 * connection is managed under Listening sources.
 */
export function SignInSection() {
  const { api, auth } = useAppData();
  const [version, setVersion] = useState(0);
  const passkeys = useAsync(`passkeys:${version}`, (signal) => api.auth.passkeys(signal));
  const sessions = useAsync(`sessions:${version}`, (signal) => api.auth.sessions(signal));
  const [codes, setCodes] = useState<string[] | null>(null);
  const recovered = new URLSearchParams(useLocation().search).get('recovered') === '1';
  const refresh = () => {
    setVersion((v) => v + 1);
    auth.retry();
  };
  const methods = auth.status === 'success' && auth.data?.signedIn ? auth.data.methods : null;

  return (
    <>
      {recovered && (
        <p className={styles.error} role="alert">You signed in with a recovery code, which is now used up. Add a passkey for this device now.</p>
      )}
      <PasskeysPanel
        passkeys={passkeys}
        onAdded={(recoveryCodes) => {
          if (recoveryCodes) setCodes(recoveryCodes);
          refresh();
        }}
        onChanged={refresh}
      />
      <RecoveryCodesPanel remaining={methods?.recoveryCodes ?? null} codes={codes} onCodes={(c) => { setCodes(c); refresh(); }} onDismiss={() => setCodes(null)} />
      <SessionsPanel sessions={sessions} onChanged={refresh} />
    </>
  );
}

function PasskeysPanel({ passkeys, onAdded, onChanged }: {
  passkeys: ReturnType<typeof useAsync<Passkey[]>>;
  onAdded(recoveryCodes: string[] | null): void;
  onChanged(): void;
}) {
  const { api, fmt, timeZone } = useAppData();
  const inputId = useId();
  const [nickname, setNickname] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const supported = passkeysSupported();

  async function add() {
    setBusy('add');
    setError(null);
    try {
      const { recoveryCodes } = await api.auth.addPasskey(nickname.trim());
      setNickname('');
      onAdded(recoveryCodes);
    } catch (e) {
      setError(describe(e));
    } finally {
      setBusy(null);
    }
  }

  async function remove(id: number) {
    setBusy(`remove:${id}`);
    setError(null);
    try {
      await api.auth.removePasskey(id);
      onChanged();
    } catch (e) {
      setError(describe(e));
    } finally {
      setBusy(null);
    }
  }

  return (
    <section className={styles.panel} aria-labelledby="passkeys-title" id="passkeys">
      <span id="passkeys-title" className={styles.panelTitle}>Passkeys</span>
      <span>A passkey signs you in with this device’s own unlock. It works only on this address, {window.location.host}.</span>
      {passkeys.status === 'loading' && <p className={stateStyles.statusText} role="status">Loading your passkeys</p>}
      {passkeys.status === 'error' && <p className={styles.error} role="alert">Your passkeys couldn’t be loaded.</p>}
      {passkeys.status === 'success' && passkeys.data.length === 0 && <span className={styles.note}>No passkey yet.</span>}
      {passkeys.status === 'success' && passkeys.data.length > 0 && (
        <ul className={styles.list} aria-label="Your passkeys">
          {passkeys.data.map((p) => (
            <li key={p.id} className={styles.row} style={{ gridTemplateColumns: '1fr auto' }}>
              <div className={styles.rowBody} style={{ gridColumn: 1 }}>
                <span className={styles.rowTitle}>{p.nickname ?? 'Passkey'}</span>
                <span className={styles.note}>
                  Added {fmt.dateTime(p.createdAt, timeZone)}. {p.lastUsedAt ? `Last used ${fmt.dateTime(p.lastUsedAt, timeZone)}.` : 'Not used yet.'}
                </span>
              </div>
              <button type="button" className={stateStyles.secondary} disabled={busy !== null} onClick={() => remove(p.id)}>
                {busy === `remove:${p.id}` ? 'Removing' : 'Remove'}
              </button>
            </li>
          ))}
        </ul>
      )}
      {supported ? (
        <>
          <label className={pending.field} htmlFor={inputId}>
            A name for this passkey, such as the device it lives on
            <input id={inputId} className={pending.input} value={nickname} maxLength={60} autoComplete="off" onChange={(e) => setNickname(e.target.value)} />
          </label>
          <div className={styles.actions}>
            <button type="button" className={stateStyles.primary} disabled={busy !== null} onClick={add}>
              {busy === 'add' ? 'Waiting for your device' : 'Add a passkey'}
            </button>
          </div>
        </>
      ) : (
        <span className={styles.note}>This browser can’t make passkeys here.</span>
      )}
      {error && <p className={styles.error} role="alert">{error}</p>}
    </section>
  );
}

function RecoveryCodesPanel({ remaining, codes, onCodes, onDismiss }: {
  remaining: number | null;
  codes: string[] | null;
  onCodes(codes: string[]): void;
  onDismiss(): void;
}) {
  const { api } = useAppData();
  const [confirming, setConfirming] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function regenerate() {
    setBusy(true);
    setError(null);
    try {
      onCodes(await api.auth.regenerateRecoveryCodes());
      setConfirming(false);
    } catch (e) {
      setError(describe(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className={styles.panel} aria-labelledby="recovery-title" id="recovery-codes">
      <span id="recovery-title" className={styles.panelTitle}>Recovery codes</span>
      <span>Each code signs you in once if no passkey is at hand. Keep them in your password manager.</span>
      {codes ? (
        <div className={`${styles.confirm} ${styles.confirmChange}`} role="region" aria-label="Your new recovery codes">
          <span>These codes are shown once. Save them now.</span>
          <ul className="mono" style={{ margin: 0, paddingLeft: 20, columns: 2 }}>
            {codes.map((c) => <li key={c}>{c}</li>)}
          </ul>
          <div className={styles.actions}>
            <button type="button" className={stateStyles.secondary} onClick={onDismiss}>I’ve saved them</button>
          </div>
        </div>
      ) : (
        <dl className={styles.facts}>
          <dt>Unused</dt>
          <dd>{remaining === null ? '—' : remaining === 0 ? 'None. Generate a new set.' : `${remaining} of 10`}</dd>
        </dl>
      )}
      {!codes && !confirming && (
        <div className={styles.actions}>
          <button type="button" className={stateStyles.secondary} disabled={busy} onClick={() => setConfirming(true)}>Generate new codes</button>
        </div>
      )}
      {confirming && (
        <div className={styles.confirm} role="group" aria-label="Confirm new recovery codes">
          <span>Your current codes stop working the moment new ones are made.</span>
          <div className={styles.actions}>
            <button type="button" className={pending.danger} disabled={busy} onClick={regenerate}>{busy ? 'Generating' : 'Replace my codes'}</button>
            <button type="button" className={stateStyles.secondary} disabled={busy} onClick={() => setConfirming(false)}>Keep them</button>
          </div>
        </div>
      )}
      {error && <p className={styles.error} role="alert">{error}</p>}
    </section>
  );
}

function SessionsPanel({ sessions, onChanged }: { sessions: ReturnType<typeof useAsync<BrowserSession[]>>; onChanged(): void }) {
  const { api, fmt, timeZone, connection, auth } = useAppData();
  const navigate = useNavigate();
  const [busy, setBusy] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);

  // This browser: the server ends the session and clears the cookie (DELETE /api/session); the app
  // then reloads who is signed in and shows the signed-out Overview. Other browsers keep their sessions.
  async function signOutHere(id: number) {
    setBusy(id);
    setError(null);
    try {
      await api.signOut();
      connection.retry();
      auth.retry();
      navigate('/overview');
    } catch (e) {
      setError(describe(e));
      setBusy(null);
    }
  }

  async function revoke(id: number) {
    setBusy(id);
    setError(null);
    try {
      await api.auth.revokeSession(id);
      onChanged();
    } catch (e) {
      setError(describe(e));
    } finally {
      setBusy(null);
    }
  }

  return (
    <section className={styles.panel} aria-labelledby="sessions-title" id="sessions">
      <span id="sessions-title" className={styles.panelTitle}>Signed-in browsers</span>
      <span>Sign out here, or sign another browser out. Your Last.fm and Spotify connections stay as they are.</span>
      {sessions.status === 'loading' && <p className={stateStyles.statusText} role="status">Loading your sessions</p>}
      {sessions.status === 'error' && <p className={styles.error} role="alert">Your sessions couldn’t be loaded.</p>}
      {sessions.status === 'success' && (
        <ul className={styles.list} aria-label="Signed-in browsers">
          {sessions.data.map((s) => (
            <li key={s.id} className={styles.row} style={{ gridTemplateColumns: '1fr auto' }}>
              <div className={styles.rowBody} style={{ gridColumn: 1 }}>
                <span className={styles.rowTitle}>{s.current ? 'This browser' : describeAgent(s.userAgent)}</span>
                <span className={styles.note}>Last seen {fmt.dateTime(s.lastSeenAt, timeZone)}{s.ipAddress ? ` from ${s.ipAddress}` : ''}. Signed in {fmt.dateTime(s.createdAt, timeZone)}.</span>
              </div>
              {s.current ? (
                <button type="button" className={stateStyles.primary} disabled={busy !== null} onClick={() => signOutHere(s.id)}>
                  {busy === s.id ? 'Signing out' : 'Sign out'}
                </button>
              ) : (
                <button type="button" className={stateStyles.secondary} disabled={busy !== null} onClick={() => revoke(s.id)}>
                  {busy === s.id ? 'Signing out' : 'Sign out'}
                </button>
              )}
            </li>
          ))}
        </ul>
      )}
      {error && <p className={styles.error} role="alert">{error}</p>}
    </section>
  );
}

/** A browser and system from the user agent, without pretending to know more. */
function describeAgent(agent: string | null): string {
  if (!agent) return 'Another browser';
  const browser = /Firefox\//.test(agent) ? 'Firefox' : /Edg\//.test(agent) ? 'Edge' : /Chrome\//.test(agent) ? 'Chrome' : /Safari\//.test(agent) ? 'Safari' : 'A browser';
  const system = /iPhone|iPad/.test(agent) ? 'iOS' : /Android/.test(agent) ? 'Android' : /Mac OS X/.test(agent) ? 'macOS' : /Windows/.test(agent) ? 'Windows' : /Linux/.test(agent) ? 'Linux' : null;
  return system ? `${browser} on ${system}` : browser;
}

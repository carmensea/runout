import { useEffect, useId, useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import stateStyles from '../../components/states/States.module.css';
import { useAppData } from '../../data/AppDataContext';
import type { ListenbrainzSource } from '../../data/types';
import { describeAuthError, googleErrorMessage } from '../../lib/authErrors';
import { passkeysSupported } from '../../lib/webauthn';
import { usePeriod } from '../../state/PeriodContext';
import pending from '../PendingScreen.module.css';
import { ListenbrainzConnectForm, ListenbrainzHelp } from '../settings/ListenbrainzConnect';
import settings from '../settings/Settings.module.css';
import styles from './Onboarding.module.css';

type Step = 'passkey' | 'codes' | 'source';

/**
 * /welcome: an invited person's first visit. A way to sign in again, then a listening source (or
 * none for now), nothing else. The way in is theirs to choose: Google, when the server offers it
 * (one click, no codes to keep), or a passkey, which comes with recovery codes to save. The
 * account is complete once either exists; the other can be added later in Settings.
 */
export function OnboardingPage() {
  const { api, auth, connection } = useAppData();
  const navigate = useNavigate();
  const { withPeriod } = usePeriod();
  const inputId = useId();
  const [nickname, setNickname] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [codes, setCodes] = useState<string[] | null>(null);
  const [enrolled, setEnrolled] = useState(false);
  const [saved, setSaved] = useState(false);
  const [listenbrainz, setListenbrainz] = useState<ListenbrainzSource | null>(null);
  const supported = passkeysSupported();

  useEffect(() => {
    document.title = 'Welcome · Runout';
  }, []);

  // Which sources this server offers (ListenBrainz is shown only while it is switched on there).
  const loadSources = () => api.sources.status().then((s) => setListenbrainz(s.listenbrainz)).catch(() => setListenbrainz(null));
  useEffect(() => {
    void loadSources();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [api]);

  const session = auth.status === 'success' ? auth.data : null;
  const hasPasskey = enrolled || (session?.signedIn === true && session.methods.passkeys > 0);
  const hasGoogle = session?.signedIn === true && session.methods.google;
  // A full page navigation: Google, then back here with the account linked.
  const googleUrl = session?.providers?.google ? api.auth.googleUrl('link', 'welcome') : null;
  const googleError = googleErrorMessage(new URLSearchParams(useLocation().search).get('google_error'));
  const name = connection.status === 'success' && connection.data.status !== 'signed_out' ? connection.data.displayName : null;
  const step: Step = !hasPasskey && !hasGoogle ? 'passkey' : codes && !saved ? 'codes' : 'source';
  const connectUrl = api.sources.connectSpotifyUrl();

  async function addPasskey() {
    setBusy(true);
    setError(null);
    try {
      const { recoveryCodes } = await api.auth.addPasskey(nickname.trim());
      setCodes(recoveryCodes);
      setEnrolled(true);
      auth.retry();
    } catch (e) {
      setError(describeAuthError(e));
    } finally {
      setBusy(false);
    }
  }

  const done = (s: Step) => (s === 'passkey' ? hasPasskey || hasGoogle : s === 'codes' ? hasPasskey && (saved || !codes) : false);
  // Recovery codes belong to passkeys: someone who chose Google has none to save.
  const all: Array<[Step, string]> = [['passkey', googleUrl || hasGoogle ? 'Choose how you sign in' : 'Add a passkey'], ['codes', 'Save your recovery codes'], ['source', 'Connect a music source']];
  const steps = hasGoogle && !hasPasskey ? all.filter(([id]) => id !== 'codes') : all;

  return (
    <main id="main" className={settings.main}>
      <div className="eyebrow">Welcome</div>
      <h1 className={settings.title}>{name ? `Welcome to Runout, ${name}.` : 'Welcome to Runout.'}</h1>
      <p className={settings.lede}>A few short steps, then your listening history starts to grow. Nothing here needs Last.fm or Spotify.</p>
      <ol className={styles.steps} aria-label="Steps">
        {steps.map(([id, label], i) => (
          <li key={id} className={`${styles.step} ${step === id ? styles.current : ''} ${done(id) ? styles.done : ''}`} aria-current={step === id ? 'step' : undefined}>
            <span className={`mono ${styles.stepNumber}`}>{done(id) ? '✓' : i + 1}</span>
            <span>{label}</span>
          </li>
        ))}
      </ol>

      {step === 'passkey' && googleUrl && (
        <section className={settings.panel} aria-labelledby="ob-google">
          <span id="ob-google" className={settings.panelTitle}>Continue with Google</span>
          <span>Sign in to Runout with your Google account from now on. Google only tells Runout that it’s you: nothing in your Google account is read.</span>
          <div className={settings.actions}>
            <a className={stateStyles.primary} href={googleUrl}>Continue with Google</a>
          </div>
          {googleError && <p className={settings.error} role="alert">{googleError}</p>}
        </section>
      )}
      {step === 'passkey' && (
        <section className={settings.panel} aria-labelledby="ob-passkey">
          <span id="ob-passkey" className={settings.panelTitle}>{googleUrl ? 'Or add a passkey' : 'Add a passkey'}</span>
          <span>A passkey signs you in with this device’s own unlock, with no password. It works only on this address, {window.location.host}.</span>
          {supported ? (
            <>
              <label className={pending.field} htmlFor={inputId}>
                A name for this passkey, such as the device it lives on
                <input id={inputId} className={pending.input} value={nickname} maxLength={60} autoComplete="off" onChange={(e) => setNickname(e.target.value)} />
              </label>
              <div className={settings.actions}>
                <button type="button" className={googleUrl ? stateStyles.secondary : stateStyles.primary} disabled={busy} onClick={addPasskey}>
                  {busy ? 'Waiting for your device' : 'Add a passkey'}
                </button>
              </div>
            </>
          ) : (
            <span className={settings.note}>This browser can’t make passkeys here. Open your invitation in a current browser on the device you will sign in from.</span>
          )}
          {error && <p className={settings.error} role="alert">{error}</p>}
        </section>
      )}

      {step === 'codes' && codes && (
        <section className={settings.panel} aria-labelledby="ob-codes">
          <span id="ob-codes" className={settings.panelTitle}>Save your recovery codes</span>
          <span>Each code signs you in once if your passkey is ever out of reach. They are shown once: put them in your password manager now.</span>
          <ul className="mono" style={{ margin: 0, paddingLeft: 20, columns: 2 }} aria-label="Your recovery codes">
            {codes.map((c) => <li key={c}>{c}</li>)}
          </ul>
          <div className={settings.actions}>
            <button type="button" className={stateStyles.primary} onClick={() => setSaved(true)}>I’ve saved them</button>
          </div>
        </section>
      )}

      {step === 'source' && (
        <section className={settings.panel} aria-labelledby="ob-source">
          <span id="ob-source" className={settings.panelTitle}>Connect a music source</span>
          <span>
            Runout keeps the plays a connected service reports, in your own archive. Spotify connects directly. Anything else, such as
            YouTube Music, reaches Runout through ListenBrainz, a free public listening record you can feed from any player.
          </span>
          <ul className={styles.disclosure} aria-label="What to know in this beta">
            <li>Spotify reports your 50 most recent plays and sometimes misses one. Runout records what it gets and never invents the rest.</li>
            {listenbrainz?.enabled && <li>Your ListenBrainz listening history is public on listenbrainz.org, with or without Runout.</li>}
            <li>The person running Runout can read the database, so they can see your listening history. Nobody else can.</li>
            <li>Encrypted backups include your plays: daily ones are kept for 30 days, monthly ones for 12 months.</li>
            <li>You can delete your account at any time in Settings → Account. It removes everything at once; backups made before then age out on that schedule.</li>
          </ul>
          {listenbrainz?.enabled && listenbrainz.state === 'connected' && listenbrainz.account ? (
            <span className={settings.note} role="status">ListenBrainz is connected as {listenbrainz.account.displayName}. Its last 30 days are read first; the rest can be imported from Settings → Sources.</span>
          ) : listenbrainz?.enabled ? (
            <>
              <span className={settings.panelTitle}>ListenBrainz</span>
              <ListenbrainzConnectForm state={listenbrainz.state} onConnected={() => void loadSources()} />
              <ListenbrainzHelp />
            </>
          ) : null}
          <div className={settings.actions}>
            {connectUrl && <a className={stateStyles.primary} href={connectUrl}>Connect Spotify</a>}
            <button type="button" className={stateStyles.secondary} onClick={() => navigate(withPeriod('/overview'))}>
              {connectUrl || listenbrainz?.enabled ? (listenbrainz?.state === 'connected' ? 'Open your Overview' : 'Skip for now') : 'Open your Overview'}
            </button>
          </div>
          <span className={settings.note}>You can connect or change a source any time in Settings → Sources.</span>
        </section>
      )}
    </main>
  );
}

import { useEffect, useId, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import stateStyles from '../../components/states/States.module.css';
import { useAppData } from '../../data/AppDataContext';
import { describeAuthError } from '../../lib/authErrors';
import { passkeysSupported } from '../../lib/webauthn';
import { usePeriod } from '../../state/PeriodContext';
import pending from '../PendingScreen.module.css';
import settings from '../settings/Settings.module.css';
import styles from './Onboarding.module.css';

type Step = 'passkey' | 'codes' | 'source';

/**
 * /welcome: an invited person's first visit. Three steps, nothing else: a passkey, the recovery
 * codes, then a listening source (or none for now). Provider-independent: the account is complete
 * once the passkey and codes exist; Spotify or anything else can be connected later in Settings.
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
  const supported = passkeysSupported();

  useEffect(() => {
    document.title = 'Welcome · Runout';
  }, []);

  const session = auth.status === 'success' ? auth.data : null;
  const hasPasskey = enrolled || (session?.signedIn === true && session.methods.passkeys > 0);
  const name = connection.status === 'success' && connection.data.status !== 'signed_out' ? connection.data.displayName : null;
  const step: Step = !hasPasskey ? 'passkey' : codes && !saved ? 'codes' : 'source';
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

  const done = (s: Step) => (s === 'passkey' ? hasPasskey : s === 'codes' ? hasPasskey && (saved || !codes) : false);
  const steps: Array<[Step, string]> = [['passkey', 'Add a passkey'], ['codes', 'Save your recovery codes'], ['source', 'Connect a music source']];

  return (
    <main id="main" className={settings.main}>
      <div className="eyebrow">Welcome</div>
      <h1 className={settings.title}>{name ? `Welcome to Runout, ${name}.` : 'Welcome to Runout.'}</h1>
      <p className={settings.lede}>Three short steps, then your listening history starts to grow. Nothing here needs Last.fm.</p>
      <ol className={styles.steps} aria-label="Steps">
        {steps.map(([id, label], i) => (
          <li key={id} className={`${styles.step} ${step === id ? styles.current : ''} ${done(id) ? styles.done : ''}`} aria-current={step === id ? 'step' : undefined}>
            <span className={`mono ${styles.stepNumber}`}>{done(id) ? '✓' : i + 1}</span>
            <span>{label}</span>
          </li>
        ))}
      </ol>

      {step === 'passkey' && (
        <section className={settings.panel} aria-labelledby="ob-passkey">
          <span id="ob-passkey" className={settings.panelTitle}>Add a passkey</span>
          <span>A passkey signs you in with this device’s own unlock, with no password. It works only on this address, {window.location.host}.</span>
          {supported ? (
            <>
              <label className={pending.field} htmlFor={inputId}>
                A name for this passkey, such as the device it lives on
                <input id={inputId} className={pending.input} value={nickname} maxLength={60} autoComplete="off" onChange={(e) => setNickname(e.target.value)} />
              </label>
              <div className={settings.actions}>
                <button type="button" className={stateStyles.primary} disabled={busy} onClick={addPasskey}>
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
          <span>Runout keeps the plays a connected service reports, in your own archive. Spotify reports your 50 most recent plays and sometimes misses one: Runout records what it gets and never invents the rest.</span>
          <span className={settings.note}>This is a beta. The archive’s owner can see the database, and backups include your plays.</span>
          <div className={settings.actions}>
            {connectUrl && <a className={stateStyles.primary} href={connectUrl}>Connect Spotify</a>}
            <button type="button" className={stateStyles.secondary} onClick={() => navigate(withPeriod('/overview'))}>
              {connectUrl ? 'Skip for now' : 'Open your Overview'}
            </button>
          </div>
          <span className={settings.note}>No Spotify? You can connect a source any time in Settings → Sources, and more services are on the way.</span>
        </section>
      )}
    </main>
  );
}

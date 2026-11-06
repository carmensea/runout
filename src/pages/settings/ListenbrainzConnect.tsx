import { useState } from 'react';
import stateStyles from '../../components/states/States.module.css';
import { useAppData } from '../../data/AppDataContext';
import type { ListenbrainzSource } from '../../data/types';
import { describeListenbrainzError } from '../../lib/listenbrainzErrors';
import styles from './Settings.module.css';

/**
 * The token form shared by Settings → Sources and the welcome page: the token proves the account
 * is yours, is checked once with ListenBrainz, and is never kept or shown.
 */
export function ListenbrainzConnectForm({ state, onConnected }: { state: ListenbrainzSource['state']; onConnected(): void }) {
  const { api } = useAppData();
  const [token, setToken] = useState('');
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const inputId = 'listenbrainz-token';
  const label = state === 'not_connected' ? 'Connect ListenBrainz' : 'Connect ListenBrainz again';

  async function connect() {
    setPending(true);
    setError(null);
    try {
      await api.sources.connectListenbrainz(token.trim());
      setToken('');
      onConnected();
    } catch (e) {
      setError(describeListenbrainzError(e));
    } finally {
      setPending(false);
    }
  }

  return (
    <>
      <span className={styles.note}>
        Your ListenBrainz listening history is public on listenbrainz.org, with or without Runout. Connecting only tells Runout
        which account is yours: Runout checks the token once with ListenBrainz and does not keep it.
      </span>
      <span className={styles.note}>
        To find the token: sign in at listenbrainz.org, open Settings from your username at the top right, and copy the
        <strong> User token</strong>. It’s a long code; paste the whole thing.
      </span>
      <label className={styles.fieldLabel} htmlFor={inputId}>
        ListenBrainz user token
        <input id={inputId} className={styles.select} type="password" autoComplete="off" value={token} onChange={(e) => setToken(e.target.value)} />
      </label>
      <div className={styles.actions}>
        <button type="button" className={stateStyles.primary} disabled={pending || token.trim() === ''} onClick={connect}>
          {pending ? 'Checking with ListenBrainz' : label}
        </button>
      </div>
      {error && <p className={styles.error} role="alert">{error}</p>}
    </>
  );
}

/** How plays reach ListenBrainz in the first place: its Spotify connection, or a scrobbler for YouTube Music. */
export function ListenbrainzHelp() {
  return (
    <details className={styles.technical}>
      <summary>Getting your plays into ListenBrainz</summary>
      <ul className={styles.list}>
        <li className={styles.row}>
          <span className={styles.rowTitle}>Spotify</span>
          <span className={styles.rowBody}>
            On listenbrainz.org, open Settings → Music services, connect Spotify and choose to record your listens. ListenBrainz then
            keeps every play Spotify reports to it, and Runout imports them from there. Not yet checked: Runout hasn’t tried this
            route with a real account, so connecting Spotify directly in Runout is the one to rely on for now. Both at once is fine:
            the same play is counted once.
          </span>
        </li>
        <li className={styles.row}>
          <span className={styles.rowTitle}>YouTube Music on Android</span>
          <span className={styles.rowBody}>
            Install Pano Scrobbler from Google Play. In its settings, add ListenBrainz as a scrobbling service and paste the same user
            token. Pano then reports what you play in the YouTube Music app. This is a route Runout has checked: plays reported this
            way reach ListenBrainz with the track, the artist and the time.
          </span>
        </li>
        <li className={styles.row}>
          <span className={styles.rowTitle}>YouTube Music in a browser</span>
          <span className={styles.rowBody}>
            Install the Web Scrobbler extension for Chrome, Firefox or Edge. In its options, under Accounts, add ListenBrainz with the
            same user token. It reports what you play on music.youtube.com. Checked by Runout the same way.
          </span>
        </li>
        <li className={styles.row}>
          <span className={styles.rowTitle}>What Runout keeps</span>
          <span className={styles.rowBody}>
            Runout reads your ListenBrainz history every few minutes and stores each play once, in your own archive. ListenBrainz’s
            copy stays public there; Runout’s is private to your account.
          </span>
        </li>
      </ul>
    </details>
  );
}

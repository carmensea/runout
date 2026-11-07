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

/**
 * How plays reach ListenBrainz in the first place: its Spotify connection, or a scrobbler for
 * YouTube Music. Once the account is connected the list is about adding a player, and what Runout
 * keeps is already on the panel above.
 */
export function ListenbrainzHelp({ connected = false }: { connected?: boolean }) {
  return (
    <details className={styles.technical}>
      <summary>{connected ? 'Adding a player that reports to ListenBrainz' : 'Getting your plays into ListenBrainz'}</summary>
      <dl className={styles.help}>
        <div className={styles.helpItem}>
          <dt>Spotify</dt>
          <dd>
            On listenbrainz.org, open Settings → Music services, connect Spotify and choose to record your listens. ListenBrainz then
            keeps every play Spotify reports to it, and Runout imports them from there. Not yet checked: Runout hasn’t tried this
            route with a real account, so connecting Spotify directly in Runout is the one to rely on for now. Both at once is fine:
            the same play is counted once.
          </dd>
        </div>
        <div className={styles.helpItem}>
          <dt>YouTube Music on Android</dt>
          <dd>
            Install Pano Scrobbler from Google Play. In its settings, add ListenBrainz as a scrobbling service and paste the same user
            token. Pano then reports what you play in the YouTube Music app. This is a route Runout has checked: plays reported this
            way reach ListenBrainz with the track, the artist and the time.
          </dd>
        </div>
        <div className={styles.helpItem}>
          <dt>YouTube Music in a browser</dt>
          <dd>
            Install the Web Scrobbler extension for Chrome, Firefox or Edge. In its options, under Accounts, add ListenBrainz with the
            same user token. It reports what you play on music.youtube.com. Checked by Runout the same way.
          </dd>
        </div>
        {!connected && (
          <div className={styles.helpItem}>
            <dt>What Runout keeps</dt>
            <dd>
              Runout reads your ListenBrainz history every few minutes and stores each play once, in your own archive. ListenBrainz’s
              copy stays public there; Runout’s is private to your account.
            </dd>
          </div>
        )}
      </dl>
    </details>
  );
}

import { useState } from 'react';
import { useLocation } from 'react-router-dom';
import stateStyles from '../../components/states/States.module.css';
import { useAppData } from '../../data/AppDataContext';
import type { ListeningSources, SpotifySource } from '../../data/types';
import { usePolling } from '../../hooks/usePolling';
import styles from './Settings.module.css';

const IDLE_INTERVAL = 60_000;

/** What came back from connecting Spotify (`?spotify_error=` on the return to Settings). */
const CONNECT_ERRORS: Record<string, string> = {
  denied: 'Spotify access wasn’t granted, so nothing was connected.',
  state: 'That connection link expired or was opened in another browser. Start again from here.',
  account_taken: 'That Spotify account is already connected to another Runout account.',
  scope: 'Spotify didn’t grant access to your recently played tracks, which Runout needs. Connect again and allow it.',
  forbidden: 'Spotify refused this account. In Development Mode, the account must be added to the Spotify app’s users.',
  spotify_rejected: 'Spotify refused the connection. Try again.',
  spotify_unavailable: 'Spotify couldn’t be reached. Try again in a few minutes.',
  unavailable: 'Spotify isn’t set up on this server yet.',
  signed_out: 'Sign in first, then connect Spotify.',
  rate_limited: 'Too many attempts. Wait a minute and try again.',
};

/**
 * Settings → Listening sources: Last.fm as the historical archive, and Spotify connected
 * directly. Connection only; tokens never reach the browser.
 */
export function SourcesSection() {
  const { api } = useAppData();
  const sources = usePolling((signal) => api.sources.status(signal), () => IDLE_INTERVAL);
  const params = new URLSearchParams(useLocation().search);
  const connected = params.get('spotify') === 'connected';
  const error = params.get('spotify_error');

  if (sources.status === 'loading') return <p className={stateStyles.statusText} role="status">Loading your listening sources</p>;
  if (sources.status === 'error') {
    return (
      <div className={styles.panel} role="alert">
        <span>Your listening sources couldn’t be loaded.</span>
        <div className={styles.actions}>
          <button type="button" className={stateStyles.secondary} onClick={sources.refresh}>Try again</button>
        </div>
      </div>
    );
  }
  return (
    <>
      {connected && sources.data.spotify.state === 'connected' && (
        <p className={styles.note} role="status">Spotify is connected.</p>
      )}
      {error && <p className={styles.error} role="alert">{CONNECT_ERRORS[error] ?? 'Spotify couldn’t be connected. Try again.'}</p>}
      <LastfmPanel lastfm={sources.data.lastfm} />
      <SpotifyPanel spotify={sources.data.spotify} onChanged={sources.refresh} />
    </>
  );
}

function LastfmPanel({ lastfm }: { lastfm: ListeningSources['lastfm'] }) {
  return (
    <section className={styles.panel} aria-labelledby="source-lastfm">
      <span id="source-lastfm" className={styles.panelTitle}>Last.fm</span>
      <dl className={styles.facts}>
        <dt>Role</dt>
        <dd>Historical archive</dd>
        <dt>Account</dt>
        <dd>{lastfm.connected && lastfm.username ? lastfm.username : 'Not connected'}</dd>
      </dl>
      <span className={styles.note}>Plays imported from Last.fm stay as they are. Its import and sync are under Listening history.</span>
    </section>
  );
}

function SpotifyPanel({ spotify, onChanged }: { spotify: SpotifySource; onChanged(): void }) {
  const { api, fmt, timeZone } = useAppData();
  const [confirming, setConfirming] = useState(false);
  const [pending, setPending] = useState(false);
  const [failed, setFailed] = useState(false);
  const connectUrl = api.sources.connectSpotifyUrl();
  const linked = spotify.state === 'connected' || spotify.state === 'needs_reauth';

  async function disconnect() {
    setPending(true);
    setFailed(false);
    try {
      await api.sources.disconnectSpotify();
      setConfirming(false);
      onChanged();
    } catch {
      setFailed(true);
    } finally {
      setPending(false);
    }
  }

  return (
    <section className={styles.panel} aria-labelledby="source-spotify" id="spotify">
      <span id="source-spotify" className={styles.panelTitle}>Spotify</span>
      {!spotify.configured && !linked ? (
        <span>Spotify isn’t set up on this server yet. It needs a Spotify app’s client ID and secret.</span>
      ) : (
        <dl className={styles.facts}>
          <dt>Status</dt>
          <dd>{STATE_TEXT[spotify.state]}</dd>
          {spotify.account && linked && (
            <>
              <dt>Account</dt>
              <dd>{spotify.account.displayName}{spotify.account.displayName !== spotify.account.id && ` (${spotify.account.id})`}</dd>
            </>
          )}
          {spotify.connectedAt && linked && (
            <>
              <dt>Connected</dt>
              <dd>{fmt.dateTime(spotify.connectedAt, timeZone)}</dd>
            </>
          )}
          {linked && (
            <>
              <dt>Scrobbling</dt>
              <dd>{spotify.ingestionEnabled ? 'Switched on on this server' : 'Off: Runout isn’t storing plays from Spotify yet'}</dd>
            </>
          )}
        </dl>
      )}
      {spotify.state === 'needs_reauth' && (
        <span className={styles.note}>Spotify stopped accepting Runout’s access{spotify.lastError ? ` (${spotify.lastError})` : ''}. Connect again to continue.</span>
      )}
      <div className={styles.actions}>
        {spotify.configured && connectUrl && spotify.state !== 'connected' && (
          <a className={stateStyles.primary} href={connectUrl}>{spotify.state === 'not_connected' ? 'Connect Spotify' : 'Connect Spotify again'}</a>
        )}
        {linked && !confirming && (
          <button type="button" className={stateStyles.secondary} onClick={() => setConfirming(true)}>Disconnect Spotify</button>
        )}
      </div>
      {confirming && (
        <div className={styles.confirm} role="group" aria-label="Disconnect Spotify">
          <span>Runout forgets its Spotify access. Plays already stored stay. To remove Runout on Spotify’s side too, use your Spotify account’s Manage apps page.</span>
          <div className={styles.actions}>
            <button type="button" className={styles.danger} disabled={pending} onClick={disconnect}>{pending ? 'Disconnecting' : 'Disconnect'}</button>
            <button type="button" className={stateStyles.secondary} disabled={pending} onClick={() => setConfirming(false)}>Keep connected</button>
          </div>
        </div>
      )}
      {failed && <p className={styles.error} role="alert">Disconnecting didn’t work. Check your connection and try again.</p>}
    </section>
  );
}

const STATE_TEXT: Record<SpotifySource['state'], string> = {
  not_connected: 'Not connected',
  connected: 'Connected',
  needs_reauth: 'Needs to be connected again',
  disconnected: 'Disconnected',
};

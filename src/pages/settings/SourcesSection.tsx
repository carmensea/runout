import { useState } from 'react';
import { useLocation } from 'react-router-dom';
import stateStyles from '../../components/states/States.module.css';
import { ApiError } from '../../data/api';
import { useAppData } from '../../data/AppDataContext';
import type { ListeningReviewItem, ListeningSources, SpotifyPoll, SpotifySource } from '../../data/types';
import { usePolling } from '../../hooks/usePolling';
import styles from './Settings.module.css';

/** Every 30 s while a poll is running or due soon, otherwise every minute. */
const BUSY_INTERVAL = 30_000;
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

const ACTION_ERRORS: Record<string, string> = {
  ingestion_disabled: 'Storing plays from Spotify is switched off on this server.',
  paused: 'Scrobbling is paused. Resume it first.',
  not_connected: 'Spotify isn’t connected.',
  too_soon: 'Synced moments ago. Try again in a minute.',
};

const POLL_OUTCOMES: Record<SpotifyPoll['outcome'], string> = {
  ok: 'Checked',
  rate_limited: 'Spotify asked Runout to wait',
  unavailable: 'Spotify couldn’t be reached',
  forbidden: 'Spotify refused',
  needs_reauth: 'Spotify access ended',
  failed: 'Stopped by an error',
  running: 'Checking',
};

/**
 * Settings → Listening sources: Last.fm as the historical archive, Spotify scrobbled directly.
 * Spotify's sync status is its own: the Last.fm import's coverage is under Listening history.
 * Tokens never reach the browser.
 */
export function SourcesSection() {
  const { api } = useAppData();
  const sources = usePolling(
    (signal) => api.sources.status(signal),
    (data) => (data?.spotify.recentPolls?.[0]?.outcome === 'running' ? BUSY_INTERVAL : IDLE_INTERVAL),
  );
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
  const spotify = sources.data.spotify;
  return (
    <>
      {connected && spotify.state === 'connected' && <p className={styles.note} role="status">Spotify is connected.</p>}
      {error && <p className={styles.error} role="alert">{CONNECT_ERRORS[error] ?? 'Spotify couldn’t be connected. Try again.'}</p>}
      <LastfmPanel lastfm={sources.data.lastfm} />
      <SpotifyPanel spotify={spotify} onChanged={sources.refresh} />
      {(spotify.pendingReview ?? 0) > 0 && <ReviewPanel onChanged={sources.refresh} />}
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
  const [pending, setPending] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [queued, setQueued] = useState(false);
  const connectUrl = api.sources.connectSpotifyUrl();
  const linked = spotify.state === 'connected' || spotify.state === 'needs_reauth';
  const active = spotify.state === 'connected';
  const at = (iso: string | null | undefined) => (iso ? fmt.dateTime(iso, timeZone) : 'Never');

  async function run(name: string, action: () => Promise<unknown>) {
    setPending(name);
    setActionError(null);
    try {
      await action();
      if (name === 'sync') setQueued(true);
      if (name === 'disconnect') setConfirming(false);
      onChanged();
    } catch (e) {
      const code = e instanceof ApiError ? e.code : null;
      setActionError((code && ACTION_ERRORS[code]) ?? 'That didn’t work. Check your connection and try again.');
    } finally {
      setPending(null);
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
          {linked && (
            <>
              <dt>Scrobbling</dt>
              <dd>{scrobblingText(spotify)}</dd>
              <dt>Last check</dt>
              <dd>{at(spotify.lastSuccessAt)}{spotify.lastPollAt && spotify.lastPollAt !== spotify.lastSuccessAt && ` (last attempt ${at(spotify.lastPollAt)})`}</dd>
              <dt>Last new play</dt>
              <dd>{spotify.lastNewPlayAt ? `${at(spotify.lastNewPlayAt)}, ${fmt.count(spotify.playsAdded ?? 0)} added in all` : 'None yet'}</dd>
              {spotify.coveredFrom && (
                <>
                  <dt>Recorded from</dt>
                  <dd>{at(spotify.coveredFrom)}</dd>
                </>
              )}
            </>
          )}
        </dl>
      )}

      {spotify.state === 'needs_reauth' && (
        <span className={styles.note}>Spotify stopped accepting Runout’s access{spotify.lastError ? ` (${spotify.lastError})` : ''}. Connect again to continue.</span>
      )}
      {active && spotify.lastError && (
        <p className={styles.error} role="status">
          Last problem, {at(spotify.lastErrorAt)}: {spotify.lastError}.
          {spotify.nextPollAt && ` Runout tries again after ${fmt.time(spotify.nextPollAt, timeZone)}.`}
        </p>
      )}
      {linked && (spotify.gaps?.length ?? 0) > 0 && (
        <div className={styles.confirm} role="status">
          <strong style={{ color: 'var(--fg)', fontWeight: 600 }}>Plays may be missing</strong>
          <span>
            Spotify only returns your most recent plays. Runout couldn’t reach back to the plays it already had, so anything played in
            these intervals may not be recorded. Runout hasn’t filled them in.
          </span>
          <ul className={styles.list}>
            {spotify.gaps!.map((g) => (
              <li key={g.from} className={styles.row}>
                <span className={`${styles.swatch} ${styles.swatchMissing}`} aria-hidden="true" />
                <span className={styles.rowTitle}>{at(g.from)} to {at(g.to)}</span>
              </li>
            ))}
          </ul>
        </div>
      )}

      <div className={styles.actions}>
        {spotify.configured && connectUrl && !active && (
          <a className={stateStyles.primary} href={connectUrl}>{spotify.state === 'not_connected' ? 'Connect Spotify' : 'Connect Spotify again'}</a>
        )}
        {active && spotify.ingestionEnabled && !spotify.paused && (
          <button type="button" className={stateStyles.primary} disabled={!!pending} onClick={() => run('sync', api.sources.syncSpotify)}>
            {pending === 'sync' ? 'Queuing' : 'Sync now'}
          </button>
        )}
        {active && spotify.ingestionEnabled && (spotify.paused ? (
          <button type="button" className={stateStyles.primary} disabled={!!pending} onClick={() => run('resume', api.sources.resumeSpotify)}>Resume</button>
        ) : (
          <button type="button" className={stateStyles.secondary} disabled={!!pending} onClick={() => run('pause', api.sources.pauseSpotify)}>Pause</button>
        ))}
        {linked && !confirming && (
          <button type="button" className={stateStyles.secondary} disabled={!!pending} onClick={() => setConfirming(true)}>Disconnect Spotify</button>
        )}
      </div>
      {queued && !actionError && <p className={styles.note} role="status">Checking Spotify now. New plays appear within a minute.</p>}
      {actionError && <p className={styles.error} role="alert">{actionError}</p>}

      {confirming && (
        <div className={styles.confirm} role="group" aria-label="Disconnect Spotify">
          <span>Runout forgets its Spotify access and stops scrobbling. Plays already stored stay. To remove Runout on Spotify’s side too, use your Spotify account’s Manage apps page.</span>
          <div className={styles.actions}>
            <button type="button" className={styles.danger} disabled={!!pending} onClick={() => run('disconnect', api.sources.disconnectSpotify)}>
              {pending === 'disconnect' ? 'Disconnecting' : 'Disconnect'}
            </button>
            <button type="button" className={stateStyles.secondary} disabled={!!pending} onClick={() => setConfirming(false)}>Keep connected</button>
          </div>
        </div>
      )}

      {linked && (spotify.recentPolls?.length ?? 0) > 0 && (
        <details className={styles.technical}>
          <summary>Recent checks</summary>
          <ul className={styles.list}>
            {spotify.recentPolls!.map((p) => (
              <li key={p.startedAt} className={styles.row}>
                <span className={styles.rowTitle}>{at(p.startedAt)} · {POLL_OUTCOMES[p.outcome]}{p.trigger === 'manual' ? ' (Sync now)' : ''}</span>
                <span className={styles.rowBody}>
                  {p.outcome === 'ok'
                    ? `${fmt.count(p.items)} recent plays read: ${fmt.count(p.added)} new${p.linked ? `, ${fmt.count(p.linked)} already in your archive` : ''}${p.held ? `, ${fmt.count(p.held)} to check` : ''}`
                    : p.error}
                </span>
              </li>
            ))}
          </ul>
        </details>
      )}
    </section>
  );
}

function scrobblingText(spotify: SpotifySource): string {
  if (!spotify.ingestionEnabled) return 'Off: Runout isn’t storing plays from Spotify yet';
  if (spotify.state !== 'connected') return 'Stopped until Spotify is connected again';
  if (spotify.paused) return 'Paused';
  return `On, ${spotify.pollSchedule ?? 'every few minutes'}`;
}

function ReviewPanel({ onChanged }: { onChanged(): void }) {
  const { api, fmt, timeZone } = useAppData();
  const reviews = usePolling((signal) => api.sources.reviews(signal), () => null);
  const [pending, setPending] = useState<number | null>(null);
  const [failed, setFailed] = useState(false);

  async function decide(item: ListeningReviewItem, decision: { link: number } | 'separate') {
    setPending(item.id);
    setFailed(false);
    try {
      await api.sources.decide(item.id, decision);
      reviews.refresh();
      onChanged();
    } catch {
      setFailed(true);
    } finally {
      setPending(null);
    }
  }

  return (
    <section className={styles.panel} aria-labelledby="source-review">
      <span id="source-review" className={styles.panelTitle}>Spotify plays to check</span>
      <span>
        These plays might already be in your archive from Last.fm. They aren’t counted until you decide. Spotify’s time is believed to
        be when the track ended; Last.fm’s is when it started.
      </span>
      {reviews.status === 'loading' && <p className={stateStyles.statusText} role="status">Loading</p>}
      {reviews.status === 'error' && <p className={styles.error} role="alert">These plays couldn’t be loaded.</p>}
      {reviews.status === 'success' && (
        <ul className={styles.list}>
          {reviews.data.map((item) => (
            <li key={item.id} className={styles.item}>
              <span className={styles.rowTitle}>{item.play.artist} – {item.play.track}</span>
              <span className={styles.rowBody}>Spotify: played {fmt.dateTime(item.reportedAt, timeZone)}</span>
              {item.candidates.map((c) => (
                <div key={c.scrobbleId} className={styles.actions}>
                  <span className={styles.rowBody}>
                    {c.source === 'lastfm' ? 'Last.fm' : 'Spotify'}: {c.artist} – {c.track}, started {fmt.dateTime(c.playedAt, timeZone)}
                  </span>
                  <button type="button" className={stateStyles.secondary} disabled={pending !== null || !c.present}
                    onClick={() => decide(item, { link: c.scrobbleId })}>
                    Same play
                  </button>
                </div>
              ))}
              <div className={styles.actions}>
                <button type="button" className={stateStyles.secondary} disabled={pending !== null} onClick={() => decide(item, 'separate')}>
                  A separate play
                </button>
              </div>
            </li>
          ))}
        </ul>
      )}
      {failed && <p className={styles.error} role="alert">That decision didn’t save. Try again.</p>}
    </section>
  );
}

const STATE_TEXT: Record<SpotifySource['state'], string> = {
  not_connected: 'Not connected',
  connected: 'Connected',
  needs_reauth: 'Needs to be connected again',
  disconnected: 'Disconnected',
};

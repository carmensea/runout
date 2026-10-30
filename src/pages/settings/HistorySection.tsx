import { useRef, useState } from 'react';
import stateStyles from '../../components/states/States.module.css';
import { ApiError } from '../../data/api';
import { useAppData } from '../../data/AppDataContext';
import type { ImportStatus, MissingPeriod, ProblemPeriod, SyncHealth } from '../../data/types';
import { usePolling } from '../../hooks/usePolling';
import { ACTIVITY, BUSY, periodLabel, reasonText } from './copy';
import styles from './Settings.module.css';

/** Polling: every 15 s while something is being imported or checked, otherwise every minute. */
const BUSY_INTERVAL = 15_000;
const IDLE_INTERVAL = 60_000;

const ACTION_ERRORS: Record<string, string> = {
  storage_disabled: 'History storage is switched off on this server, so nothing can be imported or changed.',
  busy: 'Something else is already running for your history. Try again when it has finished.',
  not_eligible: 'Sync can’t run yet: the import hasn’t completed.',
  not_active: 'There is nothing to pause or resume right now.',
  not_stopped: 'That period isn’t stopped any more.',
};

function actionError(e: unknown, fmt: (iso: string) => string): string {
  if (e instanceof ApiError && e.code === 'too_soon') {
    const at = (e.body as { retryAfter?: string } | null)?.retryAfter;
    return at ? `Checked moments ago. You can check again at ${fmt(at)}.` : 'Checked moments ago. Try again in a few minutes.';
  }
  const known = e instanceof ApiError && e.code ? ACTION_ERRORS[e.code] : undefined;
  if (known) return known;
  return 'That didn’t work. Check your connection and try again.';
}

/**
 * Settings → Listening history: what Runout is doing, import progress and controls, sync controls,
 * and the periods that are missing or stopped. `onChanged` refreshes the connection banner.
 */
export function HistorySection({ onChanged }: { onChanged(): void }) {
  const { api } = useAppData();
  const pace = (data: { activity: ImportStatus['activity'] } | null) => (data && BUSY.has(data.activity) ? BUSY_INTERVAL : IDLE_INTERVAL);
  const imp = usePolling((signal) => api.history.importStatus(signal), pace);
  const health = usePolling((signal) => api.history.syncHealth(signal), pace);

  const refresh = () => {
    imp.refresh();
    health.refresh();
    onChanged();
  };

  if (imp.status === 'loading' || health.status === 'loading') {
    return <p className={stateStyles.statusText} role="status">Loading your history’s status</p>;
  }
  if (imp.status === 'error' || health.status === 'error') {
    return (
      <div className={styles.panel} role="alert">
        <span>The import and sync status couldn’t be loaded.</span>
        <div className={styles.actions}>
          <button type="button" className={stateStyles.secondary} onClick={refresh}>Try again</button>
        </div>
      </div>
    );
  }
  return (
    <>
      <NowLine imp={imp.data} health={health.data} />
      <ImportPanel imp={imp.data} onChanged={refresh} />
      {health.data.importComplete && <SyncPanel health={health.data} onChanged={refresh} />}
      <PeriodsPanel problems={health.data.problemPeriods} missing={health.data.missingPeriods} onChanged={refresh} />
    </>
  );
}

function NowLine({ imp, health }: { imp: ImportStatus; health: SyncHealth }) {
  const activity = imp.activity === 'idle' ? health.activity : imp.activity;
  const busy = BUSY.has(activity);
  let text = ACTIVITY[activity];
  if (activity === 'idle' && !health.importComplete) text = imp.enabled ? 'Your history hasn’t been imported yet' : 'History storage is switched off';
  const tone = busy ? styles.dotBusy : health.attention.total > 0 || health.connectionState === 'failed' ? styles.dotErr : health.importComplete ? styles.dotOk : '';
  return (
    <p className={styles.now} role="status" aria-live="polite">
      <span className={`${styles.dot} ${tone}`} aria-hidden="true" />
      {text}
    </p>
  );
}

function useAction(onChanged: () => void) {
  const { fmt, timeZone } = useAppData();
  const [pending, setPending] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const inFlight = useRef(false); // set at once, so even a double-click sends one request
  async function run(name: string, action: () => Promise<void>) {
    if (inFlight.current) return;
    inFlight.current = true;
    setPending(name);
    setError(null);
    try {
      await action();
      onChanged();
    } catch (e) {
      setError(actionError(e, (iso) => fmt.time(iso, timeZone)));
    } finally {
      inFlight.current = false;
      setPending(null);
    }
  }
  return { pending, error, run };
}

function ImportPanel({ imp, onChanged }: { imp: ImportStatus; onChanged(): void }) {
  const { api, fmt, timeZone } = useAppData();
  const { pending, error, run } = useAction(onChanged);
  const [confirmCancel, setConfirmCancel] = useState(false);
  // Once a start succeeded, the button stays away until the refreshed status arrives.
  const [started, setStarted] = useState(false);
  if (started && !imp.canStart) setStarted(false); // the status caught up
  const running = imp.state === 'planning' || imp.state === 'running';
  const active = running || imp.state === 'paused' || imp.state === 'needs_review';
  const share = imp.percent === null ? null : imp.percent / 100;

  return (
    <section className={styles.panel} aria-labelledby="import-title">
      <span id="import-title" className={styles.panelTitle}>Import from Last.fm</span>

      {!imp.enabled && !imp.complete && (
        <span>History storage is switched off on this server, so nothing can be imported yet. Nothing has been fetched or stored.</span>
      )}
      {imp.state === 'not_started' && imp.enabled && (
        <span>Runout copies your whole Last.fm history, period by period, and keeps it up to date afterwards. You can pause it at any time.</span>
      )}
      {imp.state === 'cancelled' && <span>The import was cancelled. Scrobbles imported so far are kept; starting again continues from there.</span>}
      {imp.state === 'failed' && <span>The import stopped: {imp.error ?? 'Last.fm refused access.'} Scrobbles imported so far are kept.</span>}

      {active && (
        <>
          <div className={styles.progressHead}>
            <span>{imp.state === 'paused' ? 'Paused' : imp.state === 'needs_review' ? 'Imported everything it could' : 'Importing'}</span>
            <span>{share === null ? 'Starting' : fmt.percent(share)}</span>
          </div>
          <div className={styles.track} role="progressbar" aria-label="Import progress" aria-valuemin={0} aria-valuemax={100} aria-valuenow={imp.percent ?? 0}>
            <div className={styles.fill} style={{ width: `${imp.percent ?? 0}%` }} />
          </div>
          <dl className={styles.facts}>
            <dt>Imported</dt>
            <dd>
              {fmt.count(imp.importedScrobbles)} scrobbles
              {imp.lastfmPlaycount !== null && ` of about ${fmt.count(imp.lastfmPlaycount)} on Last.fm`}
            </dd>
            {imp.currentPeriod && running && (
              <>
                <dt>Now</dt>
                <dd>{periodLabel(imp.currentPeriod, fmt, timeZone)}</dd>
              </>
            )}
            <dt>Periods</dt>
            <dd>{fmt.count(imp.periods.committed)} done, {fmt.count(imp.periods.pending + imp.periods.processing)} to go{imp.periods.failed + imp.periods.review > 0 ? `, ${fmt.count(imp.periods.failed + imp.periods.review)} stopped` : ''}</dd>
          </dl>
          {imp.stalled && <p className={styles.note}>No progress for a while. Runout restarts the import automatically.</p>}
          {imp.state === 'needs_review' && <span>Some periods stopped. They’re listed below; everything else is imported.</span>}
        </>
      )}

      {imp.complete && imp.historyFrom && imp.cutoffAt && (
        <span>
          Imported {fmt.count(imp.importedScrobbles)} scrobbles, from {fmt.monthLong(imp.historyFrom.slice(0, 7))} to {fmt.dateTime(imp.cutoffAt, timeZone)}. Newer listening is added by sync.
        </span>
      )}

      <div className={styles.actions}>
        {imp.canStart && !started && (
          <button type="button" className={stateStyles.primary} disabled={!!pending}
                  onClick={() => run('start', async () => { await api.history.startImport(); setStarted(true); })}>
            {pending === 'start' ? 'Starting' : imp.state === 'not_started' ? 'Start import' : 'Start again'}
          </button>
        )}
        {running && (
          <button type="button" className={stateStyles.secondary} disabled={!!pending} onClick={() => run('pause', api.history.pauseImport)}>
            {pending === 'pause' ? 'Pausing' : 'Pause import'}
          </button>
        )}
        {imp.state === 'paused' && (
          <button type="button" className={stateStyles.primary} disabled={!!pending} onClick={() => run('resume', api.history.resumeImport)}>
            {pending === 'resume' ? 'Resuming' : 'Resume import'}
          </button>
        )}
        {active && !confirmCancel && (
          <button type="button" className={styles.danger} disabled={!!pending} onClick={() => setConfirmCancel(true)}>Cancel import</button>
        )}
      </div>
      {confirmCancel && (
        <div className={styles.confirm} role="group" aria-label="Confirm cancelling the import">
          <span>Cancel the import? Scrobbles imported so far are kept, and you can start again later.</span>
          <div className={styles.actions}>
            <button type="button" className={styles.danger} disabled={!!pending}
                    onClick={() => run('cancel', async () => { await api.history.cancelImport(); setConfirmCancel(false); })}>
              {pending === 'cancel' ? 'Cancelling' : 'Yes, cancel the import'}
            </button>
            <button type="button" className={stateStyles.secondary} disabled={!!pending} onClick={() => setConfirmCancel(false)}>Keep importing</button>
          </div>
        </div>
      )}
      {error && <p role="alert" className={styles.error}>{error}</p>}
    </section>
  );
}

function SyncPanel({ health, onChanged }: { health: SyncHealth; onChanged(): void }) {
  const { api, fmt, timeZone } = useAppData();
  const { pending, error, run } = useAction(onChanged);
  const when = (iso: string | null) => (iso ? fmt.dateTime(iso, timeZone) : 'Not yet');
  const nextChecks = Object.values(health.nextDue).filter((v): v is string => !!v).sort();
  const accountProblem = health.connectionState === 'failed';

  return (
    <section className={styles.panel} aria-labelledby="sync-title">
      <span id="sync-title" className={styles.panelTitle}>Keeping up to date</span>
      <span>
        Runout checks Last.fm for new scrobbles every 30 minutes, looks for late (offline) scrobbles from the last 14 days every day,
        and compares monthly totals once a week.
      </span>
      {accountProblem && (
        <div className={styles.confirm} role="alert">
          <span>Sync stopped: {health.message ?? 'there is a problem with the Last.fm account.'} Your history is kept.</span>
          <span className={styles.note}>Once the account is fixed, resume sync. The account is checked again before anything is fetched.</span>
        </div>
      )}
      {health.syncPaused && <span>Automatic sync is paused. Nothing is checked until you resume it; nothing was cancelled or deleted.</span>}
      <dl className={styles.facts}>
        <dt>Last successful sync</dt>
        <dd>{when(health.lastSuccessfulSyncAt)}</dd>
        <dt>Last attempt</dt>
        <dd>{when(health.lastAttemptedSyncAt)}{health.lastRun?.state === 'failed' ? ', didn’t finish' : ''}</dd>
        <dt>Up to date until</dt>
        <dd>{when(health.syncedThrough)}</dd>
        <dt>New scrobbles</dt>
        <dd>{fmt.count(health.newScrobbles.last24Hours)} in the last 24 hours</dd>
        {!health.syncPaused && nextChecks[0] && (
          <>
            <dt>Next check</dt>
            <dd>{fmt.dateTime(nextChecks[0], timeZone)}</dd>
          </>
        )}
      </dl>
      <div className={styles.actions}>
        {!health.syncPaused && !accountProblem && (
          <button type="button" className={stateStyles.primary} disabled={!!pending} onClick={() => run('refresh', api.history.refreshSync)}>
            {pending === 'refresh' ? 'Checking' : 'Check now'}
          </button>
        )}
        {health.syncPaused || accountProblem ? (
          <button type="button" className={stateStyles.primary} disabled={!!pending} onClick={() => run('resume', api.history.resumeSync)}>
            {pending === 'resume' ? 'Resuming' : 'Resume automatic sync'}
          </button>
        ) : (
          <button type="button" className={stateStyles.secondary} disabled={!!pending} onClick={() => run('pause', api.history.pauseSync)}>
            {pending === 'pause' ? 'Pausing' : 'Pause automatic sync'}
          </button>
        )}
      </div>
      {error && <p role="alert" className={styles.error}>{error}</p>}
    </section>
  );
}

function PeriodsPanel({ problems, missing, onChanged }: { problems: ProblemPeriod[]; missing: MissingPeriod[]; onChanged(): void }) {
  const { api, fmt, timeZone } = useAppData();
  const { pending, error, run } = useAction(onChanged);
  if (problems.length === 0 && missing.length === 0) return null;

  return (
    <section className={styles.panel} aria-labelledby="periods-title">
      <span id="periods-title" className={styles.panelTitle}>Periods that are missing or stopped</span>
      {missing.length > 0 && (
        <span>
          {missing.length === 1 ? 'One period has' : `${missing.length} periods have`} no imported scrobbles. Charts treat them as incomplete;
          everything else carries on.
        </span>
      )}
      <ul className={styles.list}>
        {missing.filter((m) => m.state !== 'needs_review' && m.state !== 'retrying_later').map((m) => (
          <li key={`gap-${m.from}`} className={styles.row}>
            <span className={`${styles.swatch} ${styles.swatchMissing}`} aria-hidden="true" />
            <div className={styles.rowBody}>
              <span className={styles.rowTitle}>{periodLabel(m, fmt, timeZone)}</span>
              <span className={styles.tag}>Being imported</span>
            </div>
          </li>
        ))}
        {problems.map((p) => (
          <li key={p.id} className={styles.row}>
            <span className={`${styles.swatch} ${p.imported ? styles.swatchStopped : styles.swatchMissing}`} aria-hidden="true" />
            <div className={styles.rowBody}>
              <span className={styles.rowTitle}>{periodLabel(p, fmt, timeZone)}</span>
              <span className={`${styles.tag} ${p.retriesAutomatically ? '' : styles.tagAttention}`}>
                {p.retriesAutomatically ? 'Will try again automatically' : 'Needs your attention'}
              </span>
              {p.status === 'inconsistent' ? (
                <span>The scrobbles stored for this period don’t add up to its recorded total. It is checked again at the next weekly comparison.</span>
              ) : (
                <>
                  <span>{reasonText(p.reason)}</span>
                  <span className={styles.note}>
                    {p.imported ? 'Its scrobbles imported earlier are kept and still count.' : 'Not imported yet, so this period is shown as missing.'}
                  </span>
                </>
              )}
              {p.message && (
                <details className={styles.technical}>
                  <summary>Technical details</summary>
                  <pre>{[p.message, p.httpStatus && `HTTP ${p.httpStatus}`, p.lastfmError && `Last.fm error ${p.lastfmError}`, `${p.attempts} attempts`].filter(Boolean).join('\n')}</pre>
                </details>
              )}
            </div>
            {p.status === 'check_stopped' && !p.retriesAutomatically && (
              <button type="button" className={stateStyles.secondary} disabled={!!pending} onClick={() => run(`retry-${p.id}`, () => api.history.retryPeriod(p.id))}>
                {pending === `retry-${p.id}` ? 'Retrying' : 'Try again'}
              </button>
            )}
          </li>
        ))}
      </ul>
      {error && <p role="alert" className={styles.error}>{error}</p>}
    </section>
  );
}

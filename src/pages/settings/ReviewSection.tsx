import { useRef, useState } from 'react';
import stateStyles from '../../components/states/States.module.css';
import { ApiError, ReviewChangedError } from '../../data/api';
import { useAppData } from '../../data/AppDataContext';
import type { PlayNames, ReviewDecisionName, ReviewItem, ReviewPlay } from '../../data/types';
import { usePolling } from '../../hooks/usePolling';
import { REVIEW_KIND } from './copy';
import styles from './Settings.module.css';

/**
 * Settings → To review: listening-history differences that need the owner. Nothing is removed or
 * changed until a decision is confirmed here; removed plays are hidden, never deleted, and can be
 * restored. Each decision names the version shown, so an item that changed meanwhile is shown
 * again instead of being decided blind.
 */
export function ReviewSection({ onChanged }: { onChanged(): void }) {
  const { api } = useAppData();
  const queue = usePolling((signal) => api.history.reviews(signal), () => 60_000);
  const [notice, setNotice] = useState<string | null>(null);

  const decided = (message: string | null) => {
    setNotice(message);
    queue.refresh();
    onChanged();
  };

  if (queue.status === 'loading') return <p className={stateStyles.statusText} role="status">Loading items to review</p>;
  if (queue.status === 'error') {
    return (
      <div className={styles.panel} role="alert">
        <span>Items to review couldn’t be loaded.</span>
        <div className={styles.actions}>
          <button type="button" className={stateStyles.secondary} onClick={queue.refresh}>Try again</button>
        </div>
      </div>
    );
  }
  const { items, total, waiting } = queue.data;
  return (
    <>
      <p className={styles.lede}>
        {total === 0 ? 'Nothing to review.' : `${total} ${total === 1 ? 'difference needs' : 'differences need'} your decision.`}{' '}
        Nothing is removed or changed until you decide. Removed scrobbles are hidden, not deleted, and can be restored.
      </p>
      {waiting > 0 && (
        <p className={styles.note}>
          {waiting} {waiting === 1 ? 'scrobble was' : 'scrobbles were'} missing from Last.fm once. A second, separate check must confirm
          that before you’re asked about {waiting === 1 ? 'it' : 'them'}.
        </p>
      )}
      {notice && <p className={styles.note} role="status">{notice}</p>}
      <div>
        {items.map((item) => <ReviewItemView key={`${item.kind}-${item.id}-${item.version}`} item={item} onDecided={decided} />)}
      </div>
    </>
  );
}

function Play({ play, gone }: { play: PlayNames; gone?: boolean }) {
  return (
    <div className={`${styles.play} ${gone ? styles.playGone : ''}`}>
      {play.track}
      <small>{play.artist}{play.album ? `, ${play.album}` : ''}</small>
    </div>
  );
}

function ReviewItemView({ item, onDecided }: { item: ReviewItem; onDecided(message: string | null): void }) {
  const { api, fmt, timeZone } = useAppData();
  const [pending, setPending] = useState<ReviewDecisionName | null>(null);
  const [confirming, setConfirming] = useState<ReviewDecisionName | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pairs, setPairs] = useState<Record<number, number | null>>({});
  const inFlight = useRef(false); // set at once, so even a double-click sends one decision

  async function decide(decision: ReviewDecisionName, options: { confirm?: boolean; pairs?: Array<[number, number]> } = {}) {
    if (inFlight.current) return;
    inFlight.current = true;
    setPending(decision);
    setError(null);
    try {
      const { result } = await api.history.decide(item, decision, options);
      onDecided(result === 'already' ? 'That decision had already been made.' : null);
    } catch (e) {
      if (e instanceof ReviewChangedError) {
        onDecided('This item changed while it was open, so nothing was decided. It is shown below as it is now.');
      } else if (e instanceof ApiError && e.code === 'invalid') {
        setError((e.body as { message?: string } | null)?.message ?? 'That decision isn’t possible for this item.');
      } else if (e instanceof ApiError && e.code === 'storage_disabled') {
        setError('History storage is switched off on this server, so nothing can be changed.');
      } else {
        setError('The decision wasn’t saved. Check your connection and try again.');
      }
    } finally {
      inFlight.current = false;
      setPending(null);
      setConfirming(null);
    }
  }

  const when = fmt.dateTime(item.playedAt, timeZone);
  const busy = pending !== null;

  return (
    <article className={styles.item} aria-label={`${REVIEW_KIND[item.kind]}, ${when}`}>
      <div className={styles.itemHead}>
        <span className={`${styles.tag} ${styles.tagAttention}`}>{REVIEW_KIND[item.kind]}</span>
        <span className={styles.label}>{when}</span>
      </div>

      {item.kind === 'dispute' ? (
        <Dispute item={item} pairs={pairs} setPairs={setPairs} />
      ) : (
        <div className={styles.compare}>
          <div className={styles.side}>
            <span className={styles.label}>In Runout</span>
            <Play play={item.play} gone={item.kind === 'reappeared'} />
            {item.kind === 'reappeared' && item.removedAt && <span className={styles.note}>Removed by you on {fmt.dateTime(item.removedAt, timeZone)}</span>}
          </div>
          <div className={styles.side}>
            <span className={styles.label}>On Last.fm</span>
            {item.kind === 'removal' ? (
              <div className={`${styles.play} ${styles.playGone}`}>
                Not found in two separate checks
                <small>
                  First on {fmt.dateTime(item.firstMissingAt, timeZone)}
                  {item.confirmedMissingAt ? `, again on ${fmt.dateTime(item.confirmedMissingAt, timeZone)}` : ''}
                </small>
              </div>
            ) : (
              <Play play={item.play} />
            )}
          </div>
        </div>
      )}

      <div className={styles.actions}>
        {item.kind === 'removal' && (
          <>
            <button type="button" className={styles.danger} disabled={busy} onClick={() => setConfirming('approve')}>Remove from history</button>
            <button type="button" className={stateStyles.secondary} disabled={busy} onClick={() => decide('dismiss')}>
              {pending === 'dismiss' ? 'Saving' : 'Keep it'}
            </button>
          </>
        )}
        {item.kind === 'reappeared' && (
          <>
            <button type="button" className={stateStyles.primary} disabled={busy} onClick={() => decide('restore')}>
              {pending === 'restore' ? 'Restoring' : 'Restore it'}
            </button>
            <button type="button" className={styles.danger} disabled={busy} onClick={() => setConfirming('keep')}>Keep it removed</button>
          </>
        )}
        {item.kind === 'dispute' && (
          <>
            <button type="button" className={stateStyles.primary} disabled={busy} onClick={() => setConfirming('resolve')}>Apply</button>
            <button type="button" className={stateStyles.secondary} disabled={busy} onClick={() => decide('dismiss')}>
              {pending === 'dismiss' ? 'Saving' : 'Keep as stored'}
            </button>
          </>
        )}
      </div>

      {confirming && (
        <div className={styles.confirm} role="group" aria-label="Confirm decision">
          <span>
            {confirming === 'approve' && 'Remove this scrobble from your history? It is hidden, not deleted, and can be restored later.'}
            {confirming === 'keep' && 'Keep this scrobble removed, even though Last.fm has it again?'}
            {confirming === 'resolve' && 'Apply these changes to this second of your history? Original names are kept in the history of each change.'}
          </span>
          <div className={styles.actions}>
            <button
              type="button"
              className={confirming === 'resolve' ? stateStyles.primary : styles.danger}
              disabled={busy}
              onClick={() => decide(confirming, {
                confirm: true,
                ...(confirming === 'resolve'
                  ? { pairs: Object.entries(pairs).filter((p): p is [string, number] => p[1] !== null).map(([id, index]) => [Number(id), index] as [number, number]) }
                  : {}),
              })}
            >
              {pending ? 'Saving' : confirming === 'approve' ? 'Confirm removal' : confirming === 'keep' ? 'Confirm' : 'Confirm changes'}
            </button>
            <button type="button" className={stateStyles.secondary} disabled={busy} onClick={() => setConfirming(null)}>Go back</button>
          </div>
        </div>
      )}
      {error && <p role="alert" className={styles.error}>{error}</p>}
    </article>
  );
}

/**
 * Plays in one second differ on both sides. The owner says which stored play is the same play as
 * which Last.fm play (a correction); everything else follows the usual rules, shown before
 * applying.
 */
function Dispute({ item, pairs, setPairs }: {
  item: Extract<ReviewItem, { kind: 'dispute' }>;
  pairs: Record<number, number | null>;
  setPairs(next: Record<number, number | null>): void;
}) {
  const used = new Set(Object.values(pairs).filter((v): v is number => v !== null));
  const paired = (s: ReviewPlay) => pairs[s.id] ?? null;
  const outcome = [
    ...item.stored.map((s) => {
      const match = item.fetched.find((f) => f.index === paired(s));
      return match
        ? `“${s.track}” is renamed to “${match.track}” (${match.artist}).`
        : `“${s.track}” stays, and is checked again; it is only removed if you approve that later.`;
    }),
    ...item.fetched.filter((f) => !used.has(f.index)).map((f) => `“${f.track}” (${f.artist}) is added as a new scrobble.`),
  ];

  return (
    <>
      <div className={styles.compare}>
        <div className={styles.side}>
          <span className={styles.label}>In Runout</span>
          {item.stored.map((s) => (
            <div key={s.id} className={styles.side}>
              <Play play={s} />
              <label className={styles.fieldLabel}>
                Same scrobble on Last.fm
                <select
                  className={styles.select}
                  value={paired(s) ?? ''}
                  onChange={(e) => setPairs({ ...pairs, [s.id]: e.target.value === '' ? null : Number(e.target.value) })}
                >
                  <option value="">Not on Last.fm</option>
                  {item.fetched.map((f) => (
                    <option key={f.index} value={f.index} disabled={used.has(f.index) && paired(s) !== f.index}>
                      {f.track}, {f.artist}
                    </option>
                  ))}
                </select>
              </label>
            </div>
          ))}
        </div>
        <div className={styles.side}>
          <span className={styles.label}>On Last.fm</span>
          {item.fetched.map((f) => <Play key={f.index} play={f} />)}
        </div>
      </div>
      <div>
        <span className={styles.label}>If you apply</span>
        <ul className={styles.outcome}>
          {outcome.map((line) => <li key={line}>{line}</li>)}
        </ul>
      </div>
    </>
  );
}

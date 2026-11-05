import { useEffect, useRef, useState, type PointerEvent, type ReactNode } from 'react';
import { useAppData } from '../../data/AppDataContext';
import type { PlaysPage } from '../../data/types';
import { longDate } from '../../lib/period';
import styles from './TimeMachine.module.css';

const SHOWN = 6;
const DELAY_MS = 200;
// A day's plays rarely change once stored; one fetch per day per page load.
const cache = new Map<string, Promise<PlaysPage>>();

/**
 * Wraps a calendar day: hovering with a mouse shows the first plays of that day. Decorative:
 * the link's own label carries the count, and the play log below lists everything.
 */
export function DayPlaysHover({ date, count, alignRight, children }: { date: string; count: number; alignRight?: boolean; children: ReactNode }) {
  const { api } = useAppData();
  const [open, setOpen] = useState(false);
  const [page, setPage] = useState<PlaysPage | 'error' | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  function enter(e: PointerEvent) {
    if (e.pointerType !== 'mouse' || count === 0) return;
    timer.current = setTimeout(() => setOpen(true), DELAY_MS);
  }
  function leave() {
    if (timer.current) clearTimeout(timer.current);
    setOpen(false);
  }

  useEffect(() => {
    if (!open) return;
    let live = true;
    if (!cache.has(date)) cache.set(date, api.getPlays({ kind: 'day', date }, null));
    cache.get(date)!.then((p) => live && setPage(p), () => {
      cache.delete(date);
      if (live) setPage('error');
    });
    return () => {
      live = false;
    };
  }, [open, date, api]);

  return (
    <span className={styles.hoverWrap} onPointerEnter={enter} onPointerLeave={leave}>
      {children}
      {open && (
        <span className={`${styles.hoverCard} ${alignRight ? styles.hoverCardRight : ''}`} aria-hidden="true" data-testid={`day-plays-${date}`}>
          <span className={styles.hoverTitle}>{longDate(date)}</span>
          {page === null && <span className={styles.hoverMuted}>Loading plays</span>}
          {page === 'error' && <span className={styles.hoverMuted}>Plays could not be loaded.</span>}
          {page !== null && page !== 'error' && (
            <>
              {page.plays.slice(0, SHOWN).map((p) => (
                <span key={p.id} className={styles.hoverPlay}>
                  <span className={`mono ${styles.hoverTime}`}>{p.time.slice(0, 5)}</span>
                  <span className={styles.hoverTrack}>{p.track.name}<span className={styles.hoverMuted}> · {p.artist.name}</span></span>
                </span>
              ))}
              {page.total > Math.min(SHOWN, page.plays.length) && <span className={styles.hoverMuted}>and {page.total - Math.min(SHOWN, page.plays.length)} more</span>}
            </>
          )}
        </span>
      )}
    </span>
  );
}

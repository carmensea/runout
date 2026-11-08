import { useState } from 'react';
import { useNav } from '../../app/useNav';
import { Link } from 'react-router-dom';
import { Heart } from '../../components/ui/Heart';
import { useAppData } from '../../data/AppDataContext';
import type { Play, PlaysPage } from '../../data/types';
import { useAsync } from '../../data/useAsync';
import { addDays } from '../../lib/dates';
import { longDate, serializePeriod, type Period } from '../../lib/period';
import { useLoved } from '../../state/LovedContext';
import { usePeriod } from '../../state/PeriodContext';
import { LEVEL_NOUN, type Focus } from './model';
import styles from './TimeMachine.module.css';

interface Props {
  focus: Exclude<Focus, { kind: 'all' }>;
  /** "Saturday 15 March 2014", "March 2014": used in messages. */
  label: string;
  /** Plays per local day, for the day headings (the list itself arrives a page at a time). */
  dayCounts: Map<string, number>;
  /**
   * The focus is too long for `dayCounts` (over Analytics::Calendar::MAX_DAYS days): each page
   * fetches the counts for its own days instead, so every heading still has its total.
   */
  countsPerPage?: boolean;
}

/** A page of plays, with the day counts it brought (empty unless `countsPerPage`). */
interface Loaded {
  page: PlaysPage;
  counts: Array<{ date: string; scrobbles: number }>;
}

const MAX_COUNT_DAYS = 400;

/**
 * Every scrobble in the focus, in the order it was played, a page at a time (GET /api/plays).
 * Nothing is collapsed: a track played twice is two rows, and plays in the same second are each
 * listed and marked. Strings are shown exactly as they were scrobbled.
 */
export function PlayLog({ focus, label, dayCounts, countsPerPage = false }: Props) {
  const { api, fmt } = useAppData();
  const { withPeriod } = usePeriod();
  const key = serializePeriod(focus);
  const load = async (cursor: string | null, signal?: AbortSignal): Promise<Loaded> => {
    const page = await api.getPlays(focus as Period, cursor, signal);
    if (!countsPerPage || page.plays.length === 0) return { page, counts: [] };
    const from = page.plays[0]!.date;
    const last = page.plays[page.plays.length - 1]!.date;
    const to = last < addDays(from, MAX_COUNT_DAYS - 1) ? last : addDays(from, MAX_COUNT_DAYS - 1);
    return { page, counts: (await api.getCalendarDays(from, to, signal)).days };
  };
  const first = useAsync(`plays:${key}:${countsPerPage}`, (signal) => load(null, signal));
  const [more, setMore] = useState<{ key: string; pages: Loaded[]; loading: boolean; error: string | null }>({ key, pages: [], loading: false, error: null });
  const extra = more.key === key ? more : { key, pages: [], loading: false, error: null };

  if (first.status === 'loading') return <p className={styles.logStatus} role="status">Loading scrobbles for {label}</p>;
  if (first.status === 'error') {
    return (
      <p className={styles.logStatus} role="alert">
        Scrobbles for {label} could not be loaded. <button type="button" className={styles.textButton} onClick={first.retry}>Try again</button>
      </p>
    );
  }

  const loaded = [first.data, ...extra.pages];
  const pages = loaded.map((l) => l.page);
  const plays = pages.flatMap((p) => p.plays);
  const total = first.data.page.total;
  const next = pages[pages.length - 1]!.nextCursor;
  const counts = new Map(dayCounts);
  for (const l of loaded) for (const d of l.counts) counts.set(d.date, d.scrobbles);

  if (total === 0) return <EmptyLog page={first.data.page} focus={focus} label={label} />;

  const loadMore = () => {
    if (!next) return;
    setMore({ ...extra, loading: true, error: null });
    load(next).then(
      (page) => setMore((m) => (m.key === key ? { ...m, pages: [...m.pages, page], loading: false } : m)),
      (e: unknown) => setMore((m) => (m.key === key ? { ...m, loading: false, error: e instanceof Error ? e.message : String(e) } : m)),
    );
  };

  const groups = groupByDate(plays);
  const single = focus.kind === 'day';
  return (
    <div className={styles.log}>
      {first.data.page.coverage.status !== 'complete' && (
        <p className="caption" role="status">
          Part of this {LEVEL_NOUN[focus.kind]} isn’t imported, so there may be scrobbles that aren’t listed.{' '}
          <Link to={withPeriod('/settings#history')}>Import status</Link>
        </p>
      )}
      {groups.map(([date, rows]) => (
        <section key={date} className={styles.logDay} aria-label={single ? undefined : longDate(date)}>
          {!single && (
            <h3 className={styles.logDate}>
              <span>{longDate(date)}</span>
              {counts.has(date) && <span className="mono">{fmt.count(counts.get(date)!)}</span>}
            </h3>
          )}
          <ol className={styles.logList}>
            {rows.map((play, i) => <PlayRow key={play.id} play={play} sameSecond={i > 0 && sameSecond(rows[i - 1]!, play)} />)}
          </ol>
        </section>
      ))}
      <div className={styles.logFooter}>
        <span className="mono" role="status">Showing {fmt.count(plays.length)} of {fmt.count(total)}</span>
        {next && (
          <button type="button" className={styles.moreButton} onClick={loadMore} disabled={extra.loading}>
            {extra.loading ? 'Loading' : `Show ${fmt.count(Math.min(100, total - plays.length))} more`}
          </button>
        )}
        {extra.error && <span role="alert" className={styles.logError}>Could not load more. {extra.error}</span>}
      </div>
    </div>
  );
}

function PlayRow({ play, sameSecond }: { play: Play; sameSecond: boolean }) {
  const { isLoved } = useLoved();
  const { withPeriod } = usePeriod();
  // A catalogue song opens its page (history and memories); a song the catalogue couldn't place has none yet.
  const songHref = useNav().has('memories') && play.track.id.startsWith('t') ? withPeriod(`/tracks/${encodeURIComponent(play.track.id)}`) : null;
  return (
    <li className={styles.play}>
      <time className={`mono ${styles.playTime}`} dateTime={play.playedAt}>{play.time}</time>
      <span className={styles.playWhat}>
        <span className={styles.playTrack}>{songHref ? <Link to={songHref} className={styles.playLink}>{play.track.name}</Link> : play.track.name}{isLoved(play.track.id) && <Heart />}</span>
        <span className={styles.playArtist}>{play.artist.name}</span>
      </span>
      <span className={styles.playAlbum}>{play.album?.name ?? ''}</span>
      {sameSecond && <span className={styles.sameSecond} title="Scrobbled in the same second as the play above">same second</span>}
    </li>
  );
}

function sameSecond(a: Play, b: Play): boolean {
  return a.playedAt.slice(0, 19) === b.playedAt.slice(0, 19);
}

function groupByDate(plays: Play[]): Array<[string, Play[]]> {
  const groups: Array<[string, Play[]]> = [];
  for (const play of plays) {
    const last = groups[groups.length - 1];
    if (last && last[0] === play.date) last[1].push(play);
    else groups.push([play.date, [play]]);
  }
  return groups;
}

/** No plays: a confirmed silence only where the time is imported. */
function EmptyLog({ page, focus, label }: { page: PlaysPage; focus: Props['focus']; label: string }) {
  const { withPeriod } = usePeriod();
  const noun = LEVEL_NOUN[focus.kind];
  const on = focus.kind === 'day' ? 'on' : 'in';
  const message = page.coverage.status === 'none'
    ? `Scrobbles for ${label} haven’t been imported, so nothing is known about this ${noun}.`
    : page.coverage.status === 'partial'
      ? `No scrobbles in the imported part of ${label}. Part of this ${noun} isn’t imported.`
      : `No scrobbles ${on} ${label}.`;
  return (
    <p className={styles.empty} role="status">
      {message}
      {page.coverage.status !== 'complete' && <> <Link to={withPeriod('/settings#history')}>Import status</Link></>}
    </p>
  );
}

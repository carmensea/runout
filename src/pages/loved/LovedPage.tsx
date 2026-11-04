import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { Section } from '../../components/layout/Section';
import { LoadingState, MessageState } from '../../components/states/States';
import stateStyles from '../../components/states/States.module.css';
import { Heart } from '../../components/ui/Heart';
import { NotConnectedError } from '../../data/api';
import { useAppData } from '../../data/AppDataContext';
import type { LovedLibrary, LovedTrack } from '../../data/types';
import { ratio } from '../../lib/scale';
import { useLoved } from '../../state/LovedContext';
import { usePeriod } from '../../state/PeriodContext';
import statStyles from '../overview/sections/ListeningSection.module.css';
import pageStyles from '../overview/OverviewPage.module.css';
import genreStyles from '../genres/GenrePage.module.css';
import styles from './LovedPage.module.css';

type Sort = 'loved-newest' | 'loved-oldest' | 'plays' | 'last-played' | 'artist';
const SORTS: ReadonlyArray<{ id: Sort; label: string }> = [
  { id: 'loved-newest', label: 'Loved, newest first' },
  { id: 'loved-oldest', label: 'Loved, oldest first' },
  { id: 'plays', label: 'Most played' },
  { id: 'last-played', label: 'Last listened' },
  { id: 'artist', label: 'Artist A to Z' },
];
const PAGE = 100;
const YEARS_AWAY = 3; // "not heard in years"
const REDISCOVERY_GAP_YEARS = 2; // "back in rotation": silent at least this long before the recent play

/**
 * Loved songs (GET /api/loved-tracks): every song loved on Last.fm, kept in Runout, with its
 * listening by the shared identity rules. Dates are labelled: "loved on" is when the song was
 * loved; "last listened" and the play counts are plays.
 */
export function LovedPage() {
  const { library } = useLoved();
  useEffect(() => {
    document.title = 'Loved songs · Runout';
  }, []);
  return (
    <main id="main" className={pageStyles.main}>
      <header className={pageStyles.header}>
        <div>
          <div className="eyebrow">05 / Loved{library.status === 'success' && ` · ${library.data.total.toLocaleString('en-GB')} songs`}</div>
          <h1 className={pageStyles.title}>Loved songs</h1>
          <p className={pageStyles.intro}>
            Songs you loved on Last.fm, kept here with your listening. “Loved on” is when you loved a song; plays and “last listened” are
            what you played, counted the same way as everywhere else in Runout.
          </p>
        </div>
      </header>
      {library.status === 'loading' && <LoadingState label="Loading your loved songs" />}
      {library.status === 'error' && <Failure error={library.error} retry={library.retry} />}
      {library.status === 'success' && <Body data={library.data} />}
    </main>
  );
}

function Failure({ error, retry }: { error: Error; retry(): void }) {
  const { withPeriod } = usePeriod();
  if (error instanceof NotConnectedError) {
    return <MessageState icon="link_off" message="Your Last.fm account is no longer connected." detail={<Link to={withPeriod('/settings#lastfm')}>Reconnect in Settings</Link>} />;
  }
  return (
    <MessageState icon="error" tone="error" message="Your loved songs could not be loaded.">
      <div className={stateStyles.actions}><button type="button" className={stateStyles.secondary} onClick={retry}>Try again</button></div>
      <p className={stateStyles.technical}>{error.message}</p>
    </MessageState>
  );
}

const yearOf = (iso: string) => Number(iso.slice(0, 4));
const yearsBetween = (from: string, to: Date) => (to.getTime() - new Date(from).getTime()) / (365.25 * 86_400_000);

function Body({ data }: { data: LovedLibrary }) {
  const { fmt } = useAppData();
  const { withPeriod } = usePeriod();
  const now = useMemo(() => new Date(), []);
  const current = useMemo(() => data.tracks.filter((t) => !t.unlovedAt), [data.tracks]);

  const [query, setQuery] = useState('');
  const [artist, setArtist] = useState('');
  const [year, setYear] = useState('');
  const [sort, setSort] = useState<Sort>('loved-newest');
  const [shown, setShown] = useState(PAGE);

  if (current.length === 0) {
    return <MessageState icon="favorite" message="No loved songs yet." detail="Loved songs are imported from Last.fm by the owner. Once imported, they appear here with your listening." />;
  }

  const played = current.filter((t) => t.plays > 0);
  const elsewhere = current.filter((t) => t.plays === 0 && t.namePlays > 0);
  const never = current.filter((t) => t.plays === 0 && t.namePlays === 0);
  const oldest = [...current].sort((a, b) => a.lovedAt.localeCompare(b.lovedAt));
  const mostPlayed = [...played].sort((a, b) => b.plays - a.plays || a.lovedAt.localeCompare(b.lovedAt));
  const notHeard = played
    .filter((t) => t.lastPlayedAt && yearsBetween(t.lastPlayedAt, now) >= YEARS_AWAY)
    .sort((a, b) => a.lastPlayedAt!.localeCompare(b.lastPlayedAt!));
  const recentCutoff = new Date(now.getTime() - data.recentDays * 86_400_000);
  const rediscovered = played
    .filter((t) => t.lastPlayedAt && new Date(t.lastPlayedAt) >= recentCutoff && t.previousPlayedAt && yearsBetween(t.previousPlayedAt, now) >= REDISCOVERY_GAP_YEARS)
    .sort((a, b) => a.previousPlayedAt!.localeCompare(b.previousPlayedAt!));
  const byYear = Object.entries(current.reduce<Record<number, number>>((acc, t) => ((acc[yearOf(t.lovedAt)] = (acc[yearOf(t.lovedAt)] ?? 0) + 1), acc), {}))
    .map(([y, n]) => ({ year: Number(y), loved: n }))
    .sort((a, b) => a.year - b.year);
  const artists = Object.entries(current.reduce<Record<string, number>>((acc, t) => ((acc[t.artist.name] = (acc[t.artist.name] ?? 0) + 1), acc), {}))
    .sort((a, b) => a[0].localeCompare(b[0], 'en', { sensitivity: 'base' }));

  const q = query.trim().toLocaleLowerCase();
  const filtered = data.tracks
    .filter((t) => !artist || t.artist.name === artist)
    .filter((t) => !year || yearOf(t.lovedAt) === Number(year))
    .filter((t) => !q || `${t.track.name} ${t.artist.name} ${t.asLoved.track} ${t.asLoved.artist}`.toLocaleLowerCase().includes(q))
    .sort(comparator(sort));

  const stats = [
    { label: 'Loved songs', value: fmt.count(current.length), note: `By ${fmt.count(artists.length)} artists, loved between ${fmt.date(oldest[0]!.lovedAt)} and ${fmt.date(oldest[oldest.length - 1]!.lovedAt)}` },
    { label: 'With listening', value: fmt.count(played.length), note: `${fmt.count(played.reduce((n, t) => n + t.plays, 0))} plays of loved songs in all` },
    { label: 'Without linked plays', value: fmt.count(elsewhere.length + never.length), note: `${fmt.count(elsewhere.length)} have plays under another recording of the same name, ${fmt.count(never.length)} were never played` },
    { label: 'Loved most in', value: byYear.length ? String(byYear.reduce((a, b) => (b.loved > a.loved ? b : a)).year) : '—', note: 'The year you loved the most songs. Years are when songs were loved, not played' },
  ];

  const tmHref = (date: string) => withPeriod(`/time-machine?at=${date}&period=day:${date}`);
  const row = (t: LovedTrack) => ({ key: t.id, name: t.track.name, artist: t.artist.name, artistHref: withPeriod(`/artists/${encodeURIComponent(t.artist.id)}`) });

  return (
    <>
      <dl className={statStyles.stats}>
        {stats.map((s) => (
          <div key={s.label} className={statStyles.stat}>
            <dt>{s.label}</dt>
            <dd><span className={statStyles.value}>{s.value}</span><span className={statStyles.note}>{s.note}</span></dd>
          </div>
        ))}
      </dl>

      <Section id="oldest" eyebrow="01 / Oldest loves" title="Loved longest" description="The first songs you loved, by the date you loved them.">
        <Insight items={oldest.slice(0, 10).map((t) => ({ ...row(t), meta: `Loved on ${fmt.date(t.lovedAt)} · ${plays(t, fmt.count)}` }))} caption="Oldest loved songs" />
      </Section>

      <Section id="most-played" eyebrow="02 / Most played" title="Loved and played" description="Loved songs by plays, across your whole history.">
        <Insight items={mostPlayed.slice(0, 10).map((t) => ({ ...row(t), meta: `${fmt.count(t.plays)} plays · loved on ${fmt.date(t.lovedAt)}` }))} caption="Most played loved songs" empty="No loved song has linked plays yet." />
      </Section>

      <Section id="not-heard" eyebrow="03 / Not heard in years" title="Loved, then left" description={`Loved songs you haven’t listened to for ${YEARS_AWAY} years or more, longest silence first.`}>
        <Insight
          items={notHeard.slice(0, 10).map((t) => ({ ...row(t), meta: `Last listened ${fmt.date(t.lastPlayedAt!)} · ${fmt.count(t.plays)} plays · loved on ${fmt.date(t.lovedAt)}`, href: tmHref(t.lastPlayedDate!) }))}
          caption="Loved songs not heard in years"
          empty={`Every loved song with plays was listened to within the last ${YEARS_AWAY} years.`}
        />
        {notHeard.length > 10 && <p className="caption">{fmt.count(notHeard.length)} in all. Sort the library below by last listened to see them.</p>}
      </Section>

      <Section id="rediscovered" eyebrow="04 / Back in rotation" title="Rediscovered" description={`Loved songs played in the last ${data.recentDays} days after ${REDISCOVERY_GAP_YEARS} years or more without a play.`}>
        <Insight
          items={rediscovered.slice(0, 10).map((t) => ({ ...row(t), meta: `Away ${fmt.count(Math.floor(yearsBetween(t.previousPlayedAt!, new Date(t.lastPlayedAt!))))} yr · back ${fmt.date(t.lastPlayedAt!)} · loved on ${fmt.date(t.lovedAt)}`, href: tmHref(t.lastPlayedDate!) }))}
          caption="Loved songs back in rotation"
          empty={`No loved song came back in the last ${data.recentDays} days after ${REDISCOVERY_GAP_YEARS} years away.`}
        />
      </Section>

      <Section id="by-year" eyebrow="05 / Over time" title="Loved by year" description="How many songs you loved each year. Pick a year to see them in the library below.">
        <ol className={genreStyles.bars}>
          {byYear.map((y) => (
            <li key={y.year} className={genreStyles.barRow}>
              <button type="button" className={styles.yearButton} aria-pressed={year === String(y.year)} onClick={() => { setYear(year === String(y.year) ? '' : String(y.year)); setShown(PAGE); }}>
                <span className="mono">{y.year}</span>
              </button>
              <span className={genreStyles.track} aria-hidden="true"><span style={{ width: `${ratio(y.loved, Math.max(...byYear.map((r) => r.loved)) || 1) * 100}%` }} /></span>
              <span className="mono">{fmt.count(y.loved)}</span>
              <span className={`mono ${genreStyles.muted}`}>{y.loved === 1 ? 'song' : 'songs'}</span>
            </li>
          ))}
        </ol>
      </Section>

      <Section id="library" eyebrow="06 / Library" title="All loved songs" description="Search, sort and filter. Each row links to the artist and to the day you last listened.">
        <div className={styles.controls}>
          <label className={styles.control}>
            <span className="sr-only">Search loved songs</span>
            <input type="search" placeholder="Search songs and artists" value={query} onChange={(e) => { setQuery(e.target.value); setShown(PAGE); }} className={styles.input} />
          </label>
          <label className={styles.control}>
            <span className={styles.controlLabel}>Artist</span>
            <select value={artist} onChange={(e) => { setArtist(e.target.value); setShown(PAGE); }} className={styles.select}>
              <option value="">All artists</option>
              {artists.map(([name, n]) => <option key={name} value={name}>{name} ({n})</option>)}
            </select>
          </label>
          <label className={styles.control}>
            <span className={styles.controlLabel}>Year loved</span>
            <select value={year} onChange={(e) => { setYear(e.target.value); setShown(PAGE); }} className={styles.select}>
              <option value="">All years</option>
              {byYear.map((y) => <option key={y.year} value={y.year}>{y.year} ({y.loved})</option>)}
            </select>
          </label>
          <label className={styles.control}>
            <span className={styles.controlLabel}>Sort</span>
            <select value={sort} onChange={(e) => setSort(e.target.value as Sort)} className={styles.select}>
              {SORTS.map((s) => <option key={s.id} value={s.id}>{s.label}</option>)}
            </select>
          </label>
        </div>
        <p className="caption" role="status">
          {filtered.length === data.tracks.length ? `${fmt.count(filtered.length)} songs` : `${fmt.count(filtered.length)} of ${fmt.count(data.tracks.length)} songs`}
          {data.tracks.length > current.length && ` · ${fmt.count(data.tracks.length - current.length)} no longer loved, shown muted`}
        </p>
        {filtered.length === 0 ? (
          <p className="caption" role="status">No loved songs match.</p>
        ) : (
          <div className={styles.tableWrap}>
          <table className={genreStyles.table}>
            <caption className="sr-only">Loved songs</caption>
            <thead>
              <tr>
                <th scope="col">Song</th>
                <th scope="col">Artist</th>
                <th scope="col">Loved on</th>
                <th scope="col" className={genreStyles.num}>Plays</th>
                <th scope="col">Last listened</th>
              </tr>
            </thead>
            <tbody>
              {filtered.slice(0, shown).map((t) => (
                <tr key={t.id} className={t.unlovedAt ? styles.unloved : undefined}>
                  <td>
                    <span className={styles.song}>
                      {t.track.name}
                      {!t.unlovedAt && <Heart />}
                    </span>
                    {(t.asLoved.track !== t.track.name || t.asLoved.artist !== t.artist.name) && (
                      <span className={styles.asLoved}>Loved as “{t.asLoved.track}” by {t.asLoved.artist}</span>
                    )}
                    {t.link === 'review' && <span className={styles.flag} title="This song fits more than one catalogue entry; a review is open.">catalogue review open</span>}
                    {t.unlovedAt && <span className={styles.flag}>no longer loved since {fmt.date(t.unlovedAt)}</span>}
                  </td>
                  <td><Link to={row(t).artistHref}>{t.artist.name}</Link></td>
                  <td className={styles.date}>{fmt.date(t.lovedAt)}</td>
                  <td className={genreStyles.num}>{t.plays > 0 ? fmt.count(t.plays) : <span className={genreStyles.muted}>{t.namePlays > 0 ? `0 linked · ${fmt.count(t.namePlays)} under this name` : 'none found'}</span>}</td>
                  <td className={styles.date}>{t.lastPlayedDate ? <Link to={tmHref(t.lastPlayedDate)}>{fmt.date(t.lastPlayedAt!)}</Link> : <span className={genreStyles.muted}>—</span>}</td>
                </tr>
              ))}
            </tbody>
          </table>
          </div>
        )}
        {filtered.length > shown && (
          <div className={styles.more}><button type="button" className={stateStyles.secondary} onClick={() => setShown(shown + PAGE)}>Show {fmt.count(Math.min(PAGE, filtered.length - shown))} more</button></div>
        )}
      </Section>
    </>
  );
}

function plays(t: LovedTrack, count: (n: number) => string): string {
  if (t.plays > 0) return `${count(t.plays)} plays`;
  return t.namePlays > 0 ? `${count(t.namePlays)} plays under another recording` : 'no plays found';
}

function comparator(sort: Sort): (a: LovedTrack, b: LovedTrack) => number {
  switch (sort) {
    case 'loved-newest': return (a, b) => b.lovedAt.localeCompare(a.lovedAt);
    case 'loved-oldest': return (a, b) => a.lovedAt.localeCompare(b.lovedAt);
    case 'plays': return (a, b) => b.plays - a.plays || b.namePlays - a.namePlays || b.lovedAt.localeCompare(a.lovedAt);
    case 'last-played': return (a, b) => (b.lastPlayedAt ?? '').localeCompare(a.lastPlayedAt ?? '');
    case 'artist': return (a, b) => a.artist.name.localeCompare(b.artist.name, 'en', { sensitivity: 'base' }) || a.track.name.localeCompare(b.track.name, 'en', { sensitivity: 'base' });
  }
}

interface InsightItem { key: number; name: string; artist: string; artistHref: string; meta: string; href?: string }

/** A short ranked list: song and artist over mono meta; the song links where there is a day to open. */
function Insight({ items, caption, empty }: { items: InsightItem[]; caption: string; empty?: string }) {
  if (items.length === 0) return <p className="caption" role="status">{empty ?? 'Nothing here yet.'}</p>;
  return (
    <ol className={styles.insight} aria-label={caption}>
      {items.map((i, n) => (
        <li key={i.key} className={styles.insightRow}>
          <span className={`mono ${styles.rank}`}>{n + 1}</span>
          <span className={styles.insightWhat}>
            <span className={styles.song}>{i.href ? <Link to={i.href}>{i.name}</Link> : i.name}<Heart /></span>
            <Link to={i.artistHref} className={styles.insightArtist}>{i.artist}</Link>
          </span>
          <span className={`mono ${styles.meta}`}>{i.meta}</span>
        </li>
      ))}
    </ol>
  );
}

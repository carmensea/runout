import { useEffect, type ReactNode } from 'react';
import { Link, useParams } from 'react-router-dom';
import { Swatch } from '../../components/charts/Swatch';
import { Section } from '../../components/layout/Section';
import { LoadingState, MessageState } from '../../components/states/States';
import stateStyles from '../../components/states/States.module.css';
import { ApiError, NotConnectedError } from '../../data/api';
import { useAppData } from '../../data/AppDataContext';
import type { GenreDetail } from '../../data/types';
import { useAsync } from '../../data/useAsync';
import { periodLabel, periodShortLabel, serializePeriod } from '../../lib/period';
import { ratio } from '../../lib/scale';
import { usePeriod } from '../../state/PeriodContext';
import statStyles from '../overview/sections/ListeningSection.module.css';
import pageStyles from '../overview/OverviewPage.module.css';
import styles from './GenrePage.module.css';

/**
 * One genre in the selected period (GET /api/genres/:slug), from the Overview's genre list. Same
 * period and comparison as the Overview. Figures are allocated plays (each play split across its
 * artist's genres) and reach (plays by artists with any of this genre), which overlaps between
 * genres and is labelled so.
 */
export function GenrePage() {
  const { slug = '' } = useParams();
  const { api, fmt } = useAppData();
  const { current, compare, today, withPeriod } = usePeriod();
  const main = useAsync(`genre:${slug}:${serializePeriod(current)}`, (signal) => api.getGenre(slug, current, signal));
  const vs = useAsync(compare ? `genre:${slug}:${serializePeriod(compare)}` : null, (signal) => api.getGenre(slug, compare!, signal));
  const name = main.status === 'success' ? main.data.genre.name : 'Genre';
  const currentLabel = periodShortLabel(current, today);
  const compareLabel = compare ? periodShortLabel(compare, today) : null;

  useEffect(() => {
    document.title = `${name} · ${periodLabel(current, today)} · Runout`;
  }, [name, current, today]);

  // Small but not zero never reads as zero.
  const pct = (share: number) => (share > 0 && share < 0.0005 ? '<0.1%' : fmt.percent(share, share > 0 && share < 0.1 ? 1 : 0));
  const other = compare && vs.status === 'success' ? vs.data : null;

  return (
    <main id="main" className={pageStyles.main}>
      <header className={pageStyles.header}>
        <div>
          <div className="eyebrow">
            <Link to={withPeriod('/overview#genres')} className={styles.back}>Genres</Link>
            {main.status === 'success' && main.data.genre.parent && (
              <> · <Link to={withPeriod(`/genres/${main.data.genre.parent.slug}`)} className={styles.back}>{main.data.genre.parent.name}</Link></>
            )}
            {' · '}{compareLabel ? `${currentLabel} compared with ${compareLabel}` : periodLabel(current, today)}
          </div>
          <h1 className={pageStyles.title}>{name}</h1>
          <p className={pageStyles.intro}>
            What you played that MusicBrainz lists as {name.toLowerCase()}, counted by artist. Each play counts once, split across its
            artist’s genres.
          </p>
        </div>
      </header>

      {main.status === 'loading' && <LoadingState label={`Loading ${name.toLowerCase()} for ${periodLabel(current, today)}`} />}
      {main.status === 'error' && <Failure error={main.error} retry={main.retry} />}
      {main.status === 'success' && <Body data={main.data} vs={other} compareLabel={compareLabel} pct={pct} />}
    </main>
  );
}

function Failure({ error, retry }: { error: Error; retry(): void }) {
  const { withPeriod } = usePeriod();
  if (error instanceof ApiError && error.status === 404) {
    return <MessageState icon="search_off" message="Runout has no genre by that name." detail={<Link to={withPeriod('/overview#genres')}>Back to genres</Link>} />;
  }
  if (error instanceof NotConnectedError) {
    return <MessageState icon="link_off" message="Your Last.fm account is no longer connected." detail={<Link to={withPeriod('/settings#lastfm')}>Reconnect in Settings</Link>} />;
  }
  return (
    <MessageState icon="error" tone="error" message="This genre could not be loaded.">
      <div className={stateStyles.actions}><button type="button" className={stateStyles.secondary} onClick={retry}>Try again</button></div>
      <p className={stateStyles.technical}>{error.message}</p>
    </MessageState>
  );
}

function Body({ data, vs, compareLabel, pct }: { data: GenreDetail; vs: GenreDetail | null; compareLabel: string | null; pct(s: number): string }) {
  const { fmt } = useAppData();
  const { withPeriod } = usePeriod();
  const name = data.genre.name.toLowerCase();
  if (data.plays === 0) {
    return <MessageState message="No plays in this period." detail={<Link to={withPeriod('/overview')}>Back to the Overview</Link>} />;
  }

  const stats = [
    {
      label: 'Share of plays', value: pct(data.share), cmp: vs && pct(vs.share),
      note: `Of all ${fmt.count(data.plays)} plays, the unclassified included`,
    },
    {
      label: 'Plays counted here', value: fmt.count(Math.round(data.allocated)), cmp: vs && fmt.count(Math.round(vs.allocated)),
      note: 'A play by an artist with several genres is split between them',
    },
    {
      label: 'Reach', value: pct(data.reach.share), cmp: vs && pct(vs.reach.share),
      note: `Plays by artists with any ${name}. Overlaps with other genres, so reach figures don’t add up`,
    },
    {
      label: 'Unclassified', value: pct(data.unclassifiedShare), cmp: vs && pct(vs.unclassifiedShare),
      note: 'Of this period’s plays, by artists without classified genres',
    },
  ];

  return (
    <>
      <dl className={statStyles.stats}>
        {stats.map((s) => (
          <div key={s.label} className={statStyles.stat}>
            <dt>{s.label}</dt>
            <dd>
              <span className={statStyles.value}>{s.value}</span>
              <span className={statStyles.note}>{s.note}</span>
              {compareLabel && s.cmp && (
                <span className={statStyles.cmp}><Swatch kind="outline" color="var(--fg2)" />{compareLabel}: {s.cmp}</span>
              )}
            </dd>
          </div>
        ))}
      </dl>

      {data.allocated === 0 && (
        <p className="caption" role="status" style={{ marginTop: 24 }}>No plays in this period count towards {name}.</p>
      )}

      {data.byYear.length > 1 && (
        <Section id="years" eyebrow="01 / Over time" title="Share by year" description={`Each year’s plays counted towards ${name}, as a share of that year’s plays.`}>
          <ol className={styles.bars}>
            {data.byYear.map((y) => (
              <li key={y.year} className={styles.barRow}>
                <span className="mono">{y.year}</span>
                <span className={styles.track} aria-hidden="true"><span style={{ width: `${ratio(y.share, Math.max(...data.byYear.map((r) => r.share)) || 1) * 100}%` }} /></span>
                <span className="mono">{pct(y.share)}</span>
                <span className={`mono ${styles.muted}`}>{fmt.count(Math.round(y.allocated))} of {fmt.count(y.plays)}</span>
              </li>
            ))}
          </ol>
        </Section>
      )}

      {data.subgenres.length > 0 && (
        <Section id="subgenres" eyebrow="02 / Subgenres" title="Within it" description={`How the plays counted towards ${name} divide. “Other” is weight given to ${name} itself.`}>
          <ol className={styles.bars}>
            {data.subgenres.map((s) => (
              <li key={s.name} className={styles.barRow}>
                {s.slug ? <Link to={withPeriod(`/genres/${s.slug}`)}>{s.name}</Link> : <span>{s.name}</span>}
                <span className={styles.track} aria-hidden="true"><span style={{ width: `${ratio(s.allocated, data.subgenres[0]!.allocated) * 100}%` }} /></span>
                <span className="mono">{pct(s.share)}</span>
                <span className={`mono ${styles.muted}`}>{s.allocated > 0 && s.allocated < 0.5 ? '<1 play' : `${fmt.count(Math.round(s.allocated))} plays`}</span>
              </li>
            ))}
          </ol>
        </Section>
      )}

      <Section id="artists" eyebrow="03 / Artists" title="Who it comes from" description="Plays counted towards this genre, and the part of each artist’s plays that is.">
        <Table
          caption={`Artists contributing to ${name}`}
          columns={[{ header: '#', numeric: true }, { header: 'Artist' }, { header: 'Plays counted', numeric: true }, { header: 'Of their plays', numeric: true }]}
          rows={data.topArtists.map((a, i) => [i + 1, <Link key={a.id} to={withPeriod(`/artists/${encodeURIComponent(a.id)}`)}>{a.name}</Link>, fmt.count(Math.round(a.allocated)), fmt.percent(a.genreShare)])}
          empty="No artists in this period."
        />
      </Section>

      <Section id="tracks" eyebrow="04 / Tracks" title="What was played" description="Tracks by plays counted towards this genre, with their artist’s genres.">
        <Table
          caption={`Tracks contributing to ${name}`}
          columns={[{ header: '#', numeric: true }, { header: 'Track' }, { header: 'Artist' }, { header: 'Plays counted', numeric: true }]}
          rows={data.topTracks.map((t, i) => [i + 1, t.name, t.artist, fmt.count(Math.round(t.allocated))])}
          empty="No tracks in this period."
        />
      </Section>

      <section className={styles.method} aria-labelledby="method-title">
        <h2 id="method-title" className={styles.methodTitle}>How this is counted</h2>
        <p>
          Genres are the ones MusicBrainz lists for each artist, mapped to Runout’s broad genres and subgenres. A play counts once: by an
          artist with several genres, it is split between them by the weight of each, so the shares across genres add up to 100%. Reach is
          different: it counts every play by an artist with any of this genre, so it overlaps between genres. Classification is by artist,
          which approximates the music played rather than labelling every song.
        </p>
        <p>
          Genres from <a href={data.methodology.url} target="_blank" rel="noreferrer">{data.methodology.provider}</a>, {data.methodology.license}.
        </p>
      </section>
    </>
  );
}

function Table({ caption, columns, rows, empty }: {
  caption: string;
  columns: Array<{ header: string; numeric?: boolean }>;
  rows: ReactNode[][];
  empty: string;
}) {
  if (rows.length === 0) return <p className="caption" role="status">{empty}</p>;
  return (
    <table className={styles.table}>
      <caption className="sr-only">{caption}</caption>
      <thead>
        <tr>{columns.map((c) => <th key={c.header} scope="col" className={c.numeric ? styles.num : undefined}>{c.header}</th>)}</tr>
      </thead>
      <tbody>
        {rows.map((r, i) => (
          <tr key={i}>{r.map((cell, j) => <td key={j} className={columns[j]?.numeric ? styles.num : undefined}>{cell}</td>)}</tr>
        ))}
      </tbody>
    </table>
  );
}

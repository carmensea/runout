import { useState } from 'react';
import { Link } from 'react-router-dom';
import { DataTable } from '../../../components/charts/DataTable';
import { GenrePanel } from '../../../components/charts/GenreList';
import { Swatch } from '../../../components/charts/Swatch';
import { Artwork } from '../../../components/ui/Artwork';
import { Icon } from '../../../components/ui/Icon';
import type { ActivityBucket, OverviewData } from '../../../data/types';
import { MONTH_NAMES, WEEKDAY_SHORT } from '../../../lib/dates';
import { quantileBucketer, ratio } from '../../../lib/scale';
import { artistHref, timeMachineHref, type OverviewView } from '../view';
import styles from './MobileOverview.module.css';

/** Accent opacity per quantile step; zero renders as the empty surface. */
const HEAT_RAMP = [0.12, 0.3, 0.5, 0.75, 1];
const BLOCKS = ['00', '03', '06', '09', '12', '15', '18', '21'];

interface Props {
  data: OverviewData;
  vs: OverviewData | null;
  view: OverviewView;
}

/**
 * Overview below 768px. Charts are re-composed rather than shrunk (Mobile.dc.html):
 * years instead of months, three-hour heatmap blocks, genres as one 100% bar.
 */
export function MobileOverview({ data, vs, view }: Props) {
  return (
    <>
      <Stats data={data} vs={vs} view={view} />
      <Activity data={data} view={view} />
      <Hours values={data.habits.byHour} />
      <DayAndTime values={data.habits.byWeekdayHour} format={view.fmt.count} />
      <Genres data={data} view={view} />
      <TopArtists data={data} view={view} />
      <NewArtists data={data} view={view} />
    </>
  );
}

function Stats({ data, vs, view }: Props) {
  const { fmt } = view;
  const items: Array<[string, number, number | undefined]> = [
    ['Scrobbles', data.stats.scrobbles, vs?.stats.scrobbles],
    ['Artists', data.stats.uniqueArtists, vs?.stats.uniqueArtists],
    ['Tracks', data.stats.uniqueTracks, vs?.stats.uniqueTracks],
    ['Albums', data.stats.uniqueAlbums, vs?.stats.uniqueAlbums],
  ];
  return (
    <dl className={styles.stats}>
      {items.map(([label, value, cmp]) => (
        <div key={label} className={styles.stat}>
          <dt>{label}</dt>
          <dd>
            <span className={styles.statValue}>{fmt.count(value)}</span>
            {view.compareLabel && cmp !== undefined && (
              <span className={styles.cmp}>
                <Swatch kind="outline" color="var(--fg2)" />
                {view.compareLabel}: {fmt.count(cmp)}
              </span>
            )}
          </dd>
        </div>
      ))}
    </dl>
  );
}

/** Scrobbles per year; tapping a bar selects it and offers a link into Time Machine. */
function Activity({ data, view }: { data: OverviewData; view: OverviewView }) {
  const { fmt } = view;
  // Short periods have a single year, so fall back to months.
  const byYear = data.activity.year.length > 1;
  const buckets: ActivityBucket[] = byYear ? data.activity.year : data.activity.month;
  const peak = buckets.reduce((best, b, i) => (b.scrobbles > (buckets[best]?.scrobbles ?? -1) ? i : best), 0);
  const [selected, setSelected] = useState<number | null>(null);
  const sel = Math.min(selected ?? peak, buckets.length - 1);
  const selBucket = buckets[sel];
  const max = Math.max(0, ...buckets.map((b) => b.scrobbles));
  const unit = byYear ? 'year' : 'month';
  const label = (key: string) => (byYear ? key : fmt.monthShort(key));
  const ticks = buckets.length <= 4 ? buckets.map((_, i) => i) : [0, Math.round((buckets.length - 1) / 3), Math.round(((buckets.length - 1) * 2) / 3), buckets.length - 1];

  return (
    <section aria-labelledby="m-activity">
      <h3 id="m-activity" className={`${styles.h3} ${styles.withCaption}`}>Scrobbles per {unit}</h3>
      <p className={styles.caption}>{byYear ? 'Tap a year to open its months.' : 'Tap a month to open it in Time Machine.'}</p>
      {buckets.length === 0 ? (
        <p className={styles.caption} role="status">No scrobbles to chart.</p>
      ) : (
        <>
          <div className={styles.bars} style={{ height: 140, gap: 3 }} role="group" aria-label={`Scrobbles per ${unit}`}>
            {buckets.map((b, i) => (
              <button
                key={b.key}
                type="button"
                className={styles.barButton}
                aria-pressed={i === sel}
                aria-label={`${label(b.key)}, ${fmt.count(b.scrobbles)} scrobbles`}
                onClick={() => setSelected(i)}
              >
                <span style={{ height: `${ratio(b.scrobbles, max) * 95}%`, background: i === sel ? 'var(--fg)' : 'var(--ac)' }} />
              </button>
            ))}
          </div>
          <div className={styles.axis} aria-hidden="true">
            {[...new Set(ticks)].map((i) => <span key={i}>{byYear ? buckets[i]!.key : fmt.monthShort(buckets[i]!.key)}</span>)}
          </div>
          {selBucket && (
            <div className={styles.selection} aria-live="polite">
              <span>
                <span className="mono" style={{ fontSize: 11, color: 'var(--mu)' }}>{label(selBucket.key)}</span>
                {'  '}{fmt.count(selBucket.scrobbles)} scrobbles
              </span>
              <Link to={timeMachineHref(view, selBucket.key)} aria-label={`Open ${label(selBucket.key)} in Time Machine`}>Open</Link>
            </div>
          )}
        </>
      )}
    </section>
  );
}

function Hours({ values }: { values: number[] }) {
  const max = Math.max(0, ...values);
  const peak = values.indexOf(max);
  return (
    <section aria-labelledby="m-hours">
      <h3 id="m-hours" className={styles.h3}>By hour of day</h3>
      <div className={styles.bars} style={{ height: 100, gap: 2 }} role="img" aria-label={`Scrobbles by hour of day. Busiest hour ${String(peak).padStart(2, '0')}:00.`}>
        {values.map((v, h) => (
          <div key={h} style={{ flex: 1, height: `${ratio(v, max) * 95}%`, background: h === peak ? 'var(--fg)' : 'var(--ac)' }} />
        ))}
      </div>
      <div className={styles.axis} aria-hidden="true"><span>00</span><span>06</span><span>12</span><span>18</span><span>23</span></div>
    </section>
  );
}

/** 7 × 8 heatmap of three-hour blocks. */
function DayAndTime({ values, format }: { values: number[][]; format(n: number): string }) {
  const blocks = values.map((row) => BLOCKS.map((_, b) => (row[b * 3] ?? 0) + (row[b * 3 + 1] ?? 0) + (row[b * 3 + 2] ?? 0)));
  const bucket = quantileBucketer(blocks.flat(), HEAT_RAMP.length);
  return (
    <section aria-labelledby="m-heat">
      <h3 id="m-heat" className={`${styles.h3} ${styles.withCaption}`} style={{ marginBottom: 4 }}>Day and time</h3>
      <p className={styles.caption} style={{ marginBottom: 10 }}>Three-hour blocks. Darker means fewer scrobbles.</p>
      <div className={styles.heat} role="img" aria-label="Heatmap of scrobbles by weekday in three-hour blocks">
        <span aria-hidden="true" />
        {BLOCKS.map((b) => <span key={b} className={styles.heatHead} aria-hidden="true">{b}</span>)}
        {WEEKDAY_SHORT.map((d, di) => (
          <div key={d} style={{ display: 'contents' }} aria-hidden="true">
            <span className={styles.heatDay}>{d}</span>
            {(blocks[di] ?? []).map((v, b) => {
              const q = bucket(v);
              return <span key={b} className={styles.heatCell} style={{ background: q < 0 ? 'var(--s1)' : 'var(--ac)', opacity: q < 0 ? 1 : HEAT_RAMP[q] }} />;
            })}
          </div>
        ))}
      </div>
      <DataTable
        hidden
        caption="Scrobbles by weekday in three-hour blocks"
        rows={WEEKDAY_SHORT.map((d, i) => ({ d, cells: blocks[i] ?? [] }))}
        rowKey={(r) => r.d}
        columns={[
          { header: 'Day', cell: (r) => r.d },
          ...BLOCKS.map((b, i) => ({ header: `${b}:00`, numeric: true, cell: (r: { cells: number[] }) => format(r.cells[i] ?? 0) })),
        ]}
      />
    </section>
  );
}

/** One 100% bar plus a list; tapping a genre shows its subgenres and artists. */
function Genres({ data, view }: { data: OverviewData; view: OverviewView }) {
  const { fmt } = view;
  const [open, setOpen] = useState<string | null>(null);
  const breakdown = data.genres.broad;
  const genres = breakdown.categories.slice(0, 7).map((g, i) => ({ ...g, color: `var(--c${i + 1})` }));
  const selected = genres.find((g) => g.id === open);
  return (
    <section aria-labelledby="m-genres">
      <h3 id="m-genres" className={styles.h3} style={{ marginBottom: 10 }}>Genres</h3>
      <div
        className={styles.shareBar}
        role="img"
        aria-label={`Genre share: ${genres.map((g) => `${g.name} ${fmt.percent(g.share)}`).join(', ')}${breakdown.untaggedShare > 0 ? `, untagged ${fmt.percent(breakdown.untaggedShare)}` : ''}.`}
      >
        {genres.map((g) => <span key={g.id} style={{ flex: g.share, background: g.color }} />)}
        {breakdown.untaggedShare > 0 && <span style={{ flex: breakdown.untaggedShare, background: 'var(--hatch)', outline: '1px solid var(--mu)', outlineOffset: -1 }} />}
      </div>
      <div style={{ marginTop: 8 }}>
        {genres.map((g) => (
          <div key={g.id}>
            <button type="button" className={styles.genreRow} aria-expanded={open === g.id} onClick={() => setOpen(open === g.id ? null : g.id)}>
              <span aria-hidden="true" style={{ width: 10, height: 10, background: g.color }} />
              <span>{g.name}</span>
              <span className="mono" style={{ fontSize: 12 }}>{fmt.percent(g.share)}</span>
              <span className={styles.chevron} aria-hidden="true"><Icon name="chevron_right" /></span>
            </button>
            {selected?.id === g.id && (
              <GenrePanel genre={selected} artistHref={(id) => artistHref(view, id)} formatCount={fmt.count} onClear={() => setOpen(null)} />
            )}
          </div>
        ))}
      </div>
    </section>
  );
}

function TopArtists({ data, view }: { data: OverviewData; view: OverviewView }) {
  const { fmt } = view;
  const artists = data.top.artists.slice(0, 5);
  return (
    <section aria-labelledby="m-top">
      <div className={styles.topHead}>
        <h3 id="m-top">Top artists</h3>
        <Link to={view.withPeriod('/artists')}>See all</Link>
      </div>
      {artists.length === 0 ? (
        <p className={styles.caption}>No artists in this period.</p>
      ) : (
        <ol style={{ margin: 0, padding: 0, listStyle: 'none' }}>
          {artists.map((a, i) => (
            <li key={a.id}>
              <Link to={artistHref(view, a.id)} className={styles.artistRow}>
                <span className={styles.rank}>{i + 1}</span>
                <Artwork src={a.imageUrl} name={a.name} size={40} />
                <span className={styles.artistText}>
                  <span className={styles.artistName}>{a.name}</span>
                  <span className={styles.artistMeta}>First {fmt.date(a.firstScrobble)}</span>
                </span>
                <span className={styles.count}>{fmt.count(a.scrobbles)}</span>
              </Link>
            </li>
          ))}
        </ol>
      )}
    </section>
  );
}

function NewArtists({ data, view }: { data: OverviewData; view: OverviewView }) {
  const months = data.discovery.months.slice(-12);
  const max = Math.max(0, ...months.map((m) => m.newArtists));
  const tickIdx = months.length <= 5 ? months.map((_, i) => i) : [0, 3, 6, 9, months.length - 1];
  const monthName = (key: string) => MONTH_NAMES[Number(key.slice(5, 7)) - 1]?.slice(0, 3) ?? key;
  return (
    <section aria-labelledby="m-new">
      <h3 id="m-new" className={styles.h3} style={{ marginBottom: 10 }}>New artists, last 12 months</h3>
      {months.length === 0 ? (
        <p className={styles.caption}>No months to chart in this period.</p>
      ) : (
        <>
          <div className={styles.bars} style={{ height: 80, gap: 4 }} role="img" aria-label={`New artists per month over the last ${months.length} months.`}>
            {months.map((m) => <div key={m.key} style={{ flex: 1, height: `${ratio(m.newArtists, max) * 95}%`, background: 'var(--c3)' }} />)}
          </div>
          <div className={styles.axis} aria-hidden="true">
            {[...new Set(tickIdx)].map((i) => <span key={i}>{monthName(months[i]!.key)}</span>)}
          </div>
          <DataTable
            hidden
            caption="New artists per month"
            rows={months}
            rowKey={(m) => m.key}
            columns={[
              { header: 'Month', cell: (m) => view.fmt.monthLong(m.key) },
              { header: 'New artists', numeric: true, cell: (m) => view.fmt.count(m.newArtists) },
            ]}
          />
        </>
      )}
    </section>
  );
}

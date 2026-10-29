import { useState } from 'react';
import { Link } from 'react-router-dom';
import { ActivityChart, type Granularity } from '../../../components/charts/ActivityChart';
import { DataTable } from '../../../components/charts/DataTable';
import { RankedBars } from '../../../components/charts/RankedBars';
import { Swatch } from '../../../components/charts/Swatch';
import { Module, ModuleRow, SecondaryButton } from '../../../components/layout/Module';
import { SegmentedControl } from '../../../components/ui/SegmentedControl';
import type { ActivityBucket, OverviewStats } from '../../../data/types';
import { isoWeekStart, parseIsoDate } from '../../../lib/dates';
import { longDate, periodLengthDays } from '../../../lib/period';
import { timeMachineHref, type OverviewView, type SectionProps } from '../view';
import styles from './ListeningSection.module.css';

const TWO_YEARS_DAYS = 2 * 366;

export function ListeningSection({ data, vs, view }: SectionProps) {
  return (
    <section id="overview" aria-labelledby="overview-eyebrow" className={styles.section}>
      <h2 id="overview-eyebrow" className="eyebrow">01 / Listening overview</h2>
      <StatGrid stats={data.stats} vs={vs?.stats ?? null} view={view} />
      <Activity data={data.activity} view={view} />
      <ModuleRow layout="rows2">
        <Module title="Most active days" caption="Single calendar days with the most scrobbles." gap={12}>
          <RankedBars
            items={data.mostActiveDays.map((d) => ({
              key: d.key,
              label: view.fmt.date(d.key),
              value: view.fmt.count(d.scrobbles),
              amount: d.scrobbles,
              href: timeMachineHref(view, d.key),
              linkLabel: `${longDate(d.key)}, ${view.fmt.count(d.scrobbles)} scrobbles. Open in Time Machine`,
            }))}
          />
        </Module>
        <Module title="Most active months" caption="Calendar months with the most scrobbles." gap={12}>
          <RankedBars
            items={data.mostActiveMonths.map((m) => ({
              key: m.key,
              label: view.fmt.monthShort(m.key),
              value: view.fmt.count(m.scrobbles),
              amount: m.scrobbles,
              href: timeMachineHref(view, m.key),
              linkLabel: `${view.fmt.monthLong(m.key)}, ${view.fmt.count(m.scrobbles)} scrobbles. Open in Time Machine`,
            }))}
          />
        </Module>
      </ModuleRow>
    </section>
  );
}

function StatGrid({ stats, vs, view }: { stats: OverviewStats; vs: OverviewStats | null; view: OverviewView }) {
  const { fmt } = view;
  const items = [
    {
      label: 'Scrobbles', value: stats.scrobbles, cmp: vs?.scrobbles,
      note: stats.firstScrobbleDate ? `Since first scrobble ${fmt.date(stats.firstScrobbleDate)}` : 'No scrobbles yet',
    },
    { label: 'Unique artists', value: stats.uniqueArtists, cmp: vs?.uniqueArtists, note: `${fmt.count(stats.artistsPlayedOverTen)} played more than 10 times` },
    { label: 'Unique tracks', value: stats.uniqueTracks, cmp: vs?.uniqueTracks, note: `${fmt.count(stats.tracksPlayedOnce)} played only once` },
    { label: 'Unique albums', value: stats.uniqueAlbums, cmp: vs?.uniqueAlbums, note: `${fmt.count(stats.albumsWithoutArtwork)} without artwork` },
  ];
  return (
    <dl className={styles.stats}>
      {items.map((s) => (
        <div key={s.label} className={styles.stat}>
          <dt>{s.label}</dt>
          <dd>
            <span className={styles.value}>{fmt.count(s.value)}</span>
            <span className={styles.note}>{s.note}</span>
            {view.compareLabel && s.cmp !== undefined && (
              <span className={styles.cmp}>
                <Swatch kind="outline" color="var(--fg2)" />
                {view.compareLabel}: {fmt.count(s.cmp)}
              </span>
            )}
          </dd>
        </div>
      ))}
    </dl>
  );
}

function Activity({ data, view }: { data: SectionProps['data']['activity']; view: OverviewView }) {
  const { fmt } = view;
  const length = periodLengthDays(view.current, view.today);
  const weekAllowed = data.week !== null && length !== null && length <= TWO_YEARS_DAYS;
  const [gran, setGran] = useState<Granularity>('month');
  const [asTable, setAsTable] = useState(false);
  const effective: Granularity = gran === 'week' && !weekAllowed ? 'month' : gran;
  const buckets: ActivityBucket[] = (effective === 'week' ? data.week : data[effective]) ?? [];

  const labelFor = (key: string) =>
    effective === 'year' ? fmt.year(key) : effective === 'month' ? fmt.monthLong(key) : `Week of ${fmt.date(isoWeekStart(Number(key.slice(0, 4)), Number(key.slice(6))))}`;

  const yearSpan = buckets.length ? Number(buckets[buckets.length - 1]!.key.slice(0, 4)) - Number(buckets[0]!.key.slice(0, 4)) : 0;
  const yearStep = yearSpan > 12 ? 2 : 1;
  const tickFor = (key: string, i: number): string | null => {
    const year = Number(key.slice(0, 4));
    const first = Number(buckets[0]?.key.slice(0, 4));
    // Axis years are structure, shown as-is even in specimen mode (as in the design).
    if (effective === 'year') return (year - first) % yearStep === 0 ? String(year) : null;
    if (effective === 'month') {
      if (yearSpan === 0) return fmt.monthShort(key).split(' ')[0] ?? null;
      return key.endsWith('-01') && (year - first) % yearStep === 0 ? String(year) : i === 0 && buckets.length < 24 ? fmt.monthShort(key) : null;
    }
    const start = isoWeekStart(year, Number(key.slice(6)));
    const prev = buckets[i - 1];
    const prevStart = prev ? isoWeekStart(Number(prev.key.slice(0, 4)), Number(prev.key.slice(6))) : null;
    const month = parseIsoDate(start).getUTCMonth();
    const newMonth = !prevStart || parseIsoDate(prevStart).getUTCMonth() !== month;
    return newMonth && month % 3 === 0 ? fmt.monthShort(start.slice(0, 7)) : null;
  };

  return (
    <Module
      className={styles.activity}
      title="Listening activity over time"
      caption={`Scrobbles per ${effective}. Select a bar to open that period in Time Machine.`}
      tools={
        <>
          <SegmentedControl
            size="sm"
            label="Granularity"
            value={effective}
            onChange={setGran}
            options={[
              { value: 'week', label: 'Week', disabled: !weekAllowed, title: weekAllowed ? undefined : 'Available for periods up to 2 years' },
              { value: 'month', label: 'Month' },
              { value: 'year', label: 'Year' },
            ]}
          />
          <SecondaryButton aria-pressed={asTable} onClick={() => setAsTable((t) => !t)}>
            {asTable ? 'View as chart' : 'View as table'}
          </SecondaryButton>
        </>
      }
    >
      {asTable ? (
        <DataTable
          caption={`Scrobbles per ${effective}`}
          rows={buckets}
          rowKey={(b) => b.key}
          maxHeight={420}
          columns={[
            { header: effective === 'week' ? 'Week' : effective === 'month' ? 'Month' : 'Year', cell: (b) => <Link to={timeMachineHref(view, b.key)}>{labelFor(b.key)}</Link> },
            { header: 'Scrobbles', numeric: true, cell: (b) => fmt.count(b.scrobbles) },
            { header: 'Top artist', cell: (b) => b.topArtist ?? 'None' },
          ]}
        />
      ) : buckets.length === 0 ? (
        <p className="caption" role="status">No scrobbles at this granularity.</p>
      ) : (
        <ActivityChart
          buckets={buckets}
          granularity={effective}
          fmt={fmt}
          labelFor={labelFor}
          tickFor={tickFor}
          hrefFor={(key) => timeMachineHref(view, key)}
        />
      )}
    </Module>
  );
}

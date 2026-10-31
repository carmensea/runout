import { useState } from 'react';
import { DataTable } from '../../../components/charts/DataTable';
import { GenreList, GenrePanel } from '../../../components/charts/GenreList';
import { StackedShareChart, type ShareSeries } from '../../../components/charts/StackedShareChart';
import { Module, ModuleRow } from '../../../components/layout/Module';
import { Section } from '../../../components/layout/Section';
import { SegmentedControl } from '../../../components/ui/SegmentedControl';
import { wholePercentages } from '../../../lib/shares';
import moreStyles from '../../../components/charts/MoreCharts.module.css';
import { artistHref, genreHref, unclassifiedText, type SectionProps } from '../view';

type Level = 'broad' | 'sub';
const SLOT = (i: number) => `var(--c${(i % 7) + 1})`;

const DESCRIPTION = 'Genres listed for each artist on MusicBrainz, mapped to Runout’s broad genres. Each play counts once, split across its artist’s genres, so the shares add up to 100%. Classified by artist: an approximation of the music played, not a label on every song.';

/** Genres arrive with Milestone 4; until then the section says so instead of showing figures. */
export function GenresSection(props: SectionProps) {
  if (props.data.genres === null) {
    return (
      <Section id="genres" eyebrow="03 / Genres" title="What it sounds like" description={DESCRIPTION}>
        <p className="caption" role="status" style={{ padding: '16px 0' }}>
          Genres aren’t available yet. They come from MusicBrainz once Runout has looked up your artists.
        </p>
      </Section>
    );
  }
  return <GenresContent {...props} genres={props.data.genres} />;
}

function GenresContent({ view, genres: available }: SectionProps & { genres: NonNullable<SectionProps['data']['genres']> }) {
  const { fmt } = view;
  const [level, setLevel] = useState<Level>('broad');
  const breakdown = (level === 'sub' ? available.sub : null) ?? available.broad;
  const genres = breakdown.categories.slice(0, 7).map((g, i) => ({ ...g, color: SLOT(i) }));
  const [chosen, setChosen] = useState<string | null | undefined>(undefined);
  // Default to the top genre until the person picks or clears.
  const selectedId = chosen === undefined ? (genres[0]?.id ?? null) : genres.some((g) => g.id === chosen) ? chosen : null;
  const selected = genres.find((g) => g.id === selectedId);

  const series: ShareSeries[] = [
    ...genres.map((g) => ({ id: g.id, name: g.name, color: g.color })),
    ...(breakdown.untaggedShare > 0 ? [{ id: 'untagged', name: 'Unclassified', color: 'var(--mu)', hatched: true }] : []),
  ];
  const percent = wholePercentages<string>({ ...Object.fromEntries(genres.map((g) => [g.id, g.share])), untagged: breakdown.untaggedShare });
  const shown = (id: string) => `${percent[id] ?? 0}%`;

  return (
    <Section
      id="genres"
      eyebrow="03 / Genres"
      title="What it sounds like"
      description={DESCRIPTION}
      actions={
        <SegmentedControl
          label="Genre level"
          value={level}
          onChange={(l) => {
            setLevel(l);
            setChosen(undefined);
          }}
          options={[
            { value: 'broad', label: 'Broad categories' },
            { value: 'sub', label: 'Subgenres', disabled: available.sub === null, title: available.sub === null ? 'Subgenre data is not available for this period yet' : undefined },
          ]}
        />
      }
    >
      <ModuleRow layout="rows75" first>
        <Module title="Genre share over time" caption="Share of each year's scrobbles. Bands are labelled directly; hover or tab to a year for exact shares.">
          {breakdown.byYear.length === 0 ? (
            <p className="caption" role="status">No tagged scrobbles in this period.</p>
          ) : breakdown.byYear.length === 1 ? (
            // One year: there is no change over time to draw, so the period's shares as one bar.
            <>
              <div
                className={moreStyles.shareBar}
                role="img"
                aria-label={`Genre share in ${breakdown.byYear[0]!.year}: ${series.map((s) => `${s.name} ${shown(s.id)}`).join(', ')}.`}
              >
                {series.map((s) => {
                  const share = s.id === 'untagged' ? breakdown.untaggedShare : genres.find((g) => g.id === s.id)?.share ?? 0;
                  return share > 0 ? <div key={s.id} className={s.hatched ? moreStyles.hatch : undefined} style={{ flex: share, background: s.hatched ? undefined : s.color }} /> : null;
                })}
              </div>
              <p className="caption" style={{ marginTop: 8 }}>Change over time shows for periods spanning two years or more.</p>
            </>
          ) : (
            <StackedShareChart
              series={series}
              rows={breakdown.byYear}
              formatShare={(s) => fmt.percent(s)}
              summary={`Stacked area chart of genre share per year, ${breakdown.byYear[0]!.year} to ${breakdown.byYear[breakdown.byYear.length - 1]!.year}.`}
            />
          )}
          <DataTable
            hidden
            caption="Genre share per year"
            rows={breakdown.byYear}
            rowKey={(r) => String(r.year)}
            columns={[
              { header: 'Year', cell: (r) => r.year },
              ...series.map((s) => ({ header: s.name, numeric: true, cell: (r: { shares: Record<string, number> }) => fmt.percent(r.shares[s.id] ?? 0) })),
            ]}
          />
        </Module>
        <Module title="Most listened genres" caption="Select a genre to see the artists behind it." gap={12}>
          <GenreList genres={genres} selectedId={selectedId} onSelect={setChosen} formatShare={(_, id) => shown(id)} />
          {breakdown.untaggedShare > 0 && (
            <p className="caption" style={{ marginTop: 12 }}>{unclassifiedText(breakdown, (s) => fmt.percent(s))}</p>
          )}
          <p className="caption" style={{ marginTop: 8 }}>
            Genres from <a href={available.source.url} target="_blank" rel="noreferrer">{available.source.provider}</a> ({available.source.license}).
          </p>
          {selected && (
            <GenrePanel
              genre={selected}
              genreHref={genreHref(view, selected.id)}
              artistHref={(id) => artistHref(view, id)}
              formatCount={fmt.count}
              onClear={() => setChosen(null)}
            />
          )}
        </Module>
      </ModuleRow>
    </Section>
  );
}

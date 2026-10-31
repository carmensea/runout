import { useState } from 'react';
import { Link } from 'react-router-dom';
import { DataTable } from '../../../components/charts/DataTable';
import { GenreList, GenrePanel } from '../../../components/charts/GenreList';
import { StackedShareChart, type ShareSeries } from '../../../components/charts/StackedShareChart';
import { Module, ModuleRow } from '../../../components/layout/Module';
import { Section } from '../../../components/layout/Section';
import { SegmentedControl } from '../../../components/ui/SegmentedControl';
import { artistHref, type SectionProps } from '../view';

type Level = 'broad' | 'sub';
const SLOT = (i: number) => `var(--c${(i % 7) + 1})`;

const DESCRIPTION = 'Genres come from Last.fm artist tags, mapped to seven broad categories. Tags with very few votes are ignored.';

/** Genres arrive with Milestone 4; until then the section says so instead of showing figures. */
export function GenresSection(props: SectionProps) {
  if (props.data.genres === null) {
    return (
      <Section id="genres" eyebrow="03 / Genres" title="What it sounds like" description={DESCRIPTION}>
        <p className="caption" role="status" style={{ padding: '16px 0' }}>
          Genres aren’t available yet. They need artist tags, which Runout doesn’t collect yet.
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
    ...(breakdown.untaggedShare > 0 ? [{ id: 'untagged', name: 'Untagged', color: 'var(--mu)', hatched: true }] : []),
  ];

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
          <GenreList genres={genres} selectedId={selectedId} onSelect={setChosen} formatShare={(s) => fmt.percent(s)} />
          {breakdown.untaggedShare > 0 && (
            <p className="caption" style={{ marginTop: 12 }}>
              {fmt.percent(breakdown.untaggedShare)} of scrobbles are from untagged artists. <Link to={view.withPeriod('/settings#metadata')}>Metadata coverage</Link>
            </p>
          )}
          {selected && (
            <GenrePanel
              genre={selected}
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

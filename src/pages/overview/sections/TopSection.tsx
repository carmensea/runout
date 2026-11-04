import { useState } from 'react';
import { BumpChart } from '../../../components/charts/BumpChart';
import { DataTable } from '../../../components/charts/DataTable';
import { LinkList } from '../../../components/charts/LinkList';
import { TopTable } from '../../../components/charts/TopTable';
import { Module, ModuleRow } from '../../../components/layout/Module';
import { Section } from '../../../components/layout/Section';
import { Tabs } from '../../../components/ui/Tabs';
import type { TopEntry, TopKind } from '../../../data/types';
import { useLoved } from '../../../state/LovedContext';
import { albumHref, artistHref, trackHref, type SectionProps } from '../view';

const TABS: ReadonlyArray<{ id: TopKind; label: string }> = [
  { id: 'artists', label: 'Artists' },
  { id: 'albums', label: 'Albums' },
  { id: 'tracks', label: 'Tracks' },
];

export function TopSection({ data, view }: SectionProps) {
  const { fmt } = view;
  const [tab, setTab] = useState<TopKind>('artists');
  const { isLoved } = useLoved();
  const hrefFor = (e: TopEntry) => (tab === 'artists' ? artistHref(view, e.id) : tab === 'tracks' ? trackHref(view, e.id) : albumHref(view, e.id));
  const entries = data.top[tab];

  return (
    <Section id="top" eyebrow="04 / Artists and tracks" title="Who you played most" description="Ranked by scrobbles in the selected period. Each row opens the full listening history.">
      <div style={{ marginTop: -4 }}>
        <Tabs idBase="top" label="Ranking" tabs={TABS} value={tab} onChange={setTab} />
      </div>
      {entries.length === 0 ? (
        <div id="top-panel" role="tabpanel" aria-labelledby={`top-tab-${tab}`}>
          <p className="caption" style={{ padding: '16px 0' }}>No {tab} in this period.</p>
        </div>
      ) : (
        <TopTable
          kind={tab}
          entries={entries.slice(0, 10)}
          total={data.top.totals[tab]}
          fmt={fmt}
          hrefFor={hrefFor}
          viewAllHref={view.withPeriod(tab === 'tracks' ? '/tracks' : '/artists')}
          panelId="top-panel"
          labelledBy={`top-tab-${tab}`}
        />
      )}

      <ModuleRow layout="rows633">
        <Module title="Rank of your top five artists, by year" caption="Position among all artists you played that year. Lower is higher.">
          {data.rankHistory.years.length < 2 ? (
            <p className="caption">Rank history needs at least two years of scrobbles.</p>
          ) : (
            <>
              <BumpChart
                years={data.rankHistory.years}
                series={data.rankHistory.series.slice(0, 5)}
                summary={`Yearly rank of your top five artists from ${data.rankHistory.years[0]} to ${data.rankHistory.years[data.rankHistory.years.length - 1]}.`}
              />
              <DataTable
                hidden
                caption="Yearly rank of top five artists"
                rows={data.rankHistory.series.slice(0, 5)}
                rowKey={(s) => s.id}
                columns={[
                  { header: 'Artist', cell: (s) => s.name },
                  ...data.rankHistory.years.map((y, i) => ({ header: String(y), numeric: true, cell: (s: { ranks: Array<number | null> }) => s.ranks[i] ?? 'Outside top 10' })),
                ]}
              />
            </>
          )}
        </Module>
        <Module title="On repeat" caption="Most plays of one track in a single day." gap={12}>
          <LinkList
            empty="No track was played more than once in a day."
            items={data.onRepeat.map((r) => ({
              key: r.trackId + r.date,
              href: trackHref(view, r.trackId),
              primary: r.name,
              loved: isLoved(r.trackId),
              meta: `${fmt.count(r.plays)} plays · ${fmt.date(r.date)}`,
            }))}
          />
        </Module>
        <Module title="Back in rotation" caption="Artists played again after a year or more away." gap={12}>
          <LinkList
            empty="No artists returned after a year away."
            items={data.backInRotation.map((r) => ({
              key: r.id,
              href: artistHref(view, r.id),
              primary: r.name,
              meta: `Away ${fmt.count(Math.floor(r.awayMonths / 12))} yr ${fmt.count(r.awayMonths % 12)} mo · back ${fmt.yearMonth(r.backMonth)}`,
            }))}
          />
        </Module>
      </ModuleRow>
    </Section>
  );
}

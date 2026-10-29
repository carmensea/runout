import { DataTable } from '../../../components/charts/DataTable';
import { DiscoveryChart } from '../../../components/charts/DiscoveryChart';
import { LinkList } from '../../../components/charts/LinkList';
import { Swatch } from '../../../components/charts/Swatch';
import { Legend, Module, ModuleRow } from '../../../components/layout/Module';
import { Section } from '../../../components/layout/Section';
import { artistHref, type SectionProps } from '../view';

export function DiscoverySection({ data, view }: SectionProps) {
  const { fmt } = view;
  const d = data.discovery;
  return (
    <Section
      id="discovery"
      eyebrow="05 / Discovery"
      title="What was new to you"
      description="An artist counts as new in the month of your first scrobble of them. Exploration is the share of a month's scrobbles going to artists first heard in the previous 90 days."
    >
      <ModuleRow layout="rows84" first>
        <Module
          title="New artists by month"
          baseline
          tools={<Legend items={[{ label: 'New artists', swatch: <Swatch color="var(--c3)" /> }, { label: 'Exploration share', swatch: <Swatch kind="line" /> }]} />}
        >
          {d.months.length === 0 ? (
            <p className="caption" role="status">No months to chart in this period.</p>
          ) : (
            <>
              <DiscoveryChart
                months={d.months}
                formatCount={fmt.count}
                formatShare={(s) => fmt.percent(s)}
                formatMonth={fmt.monthShort}
                summary={`New artists per month with exploration share, ${d.months.length} months.`}
              />
              <DataTable
                hidden
                caption="New artists and exploration share by month"
                rows={d.months}
                rowKey={(m) => m.key}
                columns={[
                  { header: 'Month', cell: (m) => fmt.monthLong(m.key) },
                  { header: 'New artists', numeric: true, cell: (m) => fmt.count(m.newArtists) },
                  { header: 'Exploration share', numeric: true, cell: (m) => fmt.percent(m.explorationShare) },
                ]}
              />
            </>
          )}
        </Module>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 32 }}>
          <Module title="First heard in this period" caption="Sorted by scrobbles since discovery." gap={8}>
            <LinkList
              inline
              empty="No new artists in this period."
              items={d.firstHeard.map((a) => ({ key: a.id, href: artistHref(view, a.id), primary: a.name, meta: fmt.date(a.firstScrobble) }))}
            />
          </Module>
          <Module title="Rediscovered" caption="Not played for two years or more, then back this period." gap={8}>
            <LinkList
              inline
              empty="No artists came back after two years away."
              items={d.rediscovered.map((a) => ({ key: a.id, href: artistHref(view, a.id), primary: a.name, meta: `Last ${fmt.year(String(a.lastYearBefore))}` }))}
            />
          </Module>
        </div>
      </ModuleRow>
    </Section>
  );
}

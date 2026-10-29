import { DataTable } from '../../../components/charts/DataTable';
import { HeatRamp, Heatmap } from '../../../components/charts/Heatmap';
import { HourChart } from '../../../components/charts/HourChart';
import { SeasonalChart } from '../../../components/charts/SeasonalChart';
import { Swatch } from '../../../components/charts/Swatch';
import { WeekdayBars } from '../../../components/charts/WeekdayBars';
import { Section } from '../../../components/layout/Section';
import { Legend, Module, ModuleRow } from '../../../components/layout/Module';
import { MONTH_NAMES, WEEKDAY_SHORT, hemisphereOf } from '../../../lib/dates';
import type { SectionProps } from '../view';

const hh = (h: number) => String(h).padStart(2, '0');

export function HabitsSection({ data, vs, view }: SectionProps) {
  const { fmt } = view;
  const h = data.habits;
  const total = h.byHour.reduce((a, b) => a + b, 0);
  const busiest = h.byHour.indexOf(Math.max(...h.byHour));
  const busiestDay = h.byWeekday.indexOf(Math.max(...h.byWeekday));
  const hemisphere = hemisphereOf(view.timeZone);
  const peakMonth = h.avgPerDayByMonth.indexOf(Math.max(...h.avgPerDayByMonth));
  const compareLegend = view.compareLabel && vs
    ? <Legend items={[{ label: view.currentLabel, swatch: <Swatch /> }, { label: view.compareLabel, swatch: <Swatch kind="outline" color="var(--fg2)" /> }]} />
    : undefined;

  return (
    <Section
      id="habits"
      eyebrow="02 / Listening habits"
      title="When you listen"
      description="Patterns by hour, weekday and season. Counts are scrobbles, not minutes listened."
    >
      <ModuleRow layout="rows75" first>
        <Module title="Scrobbles by hour of day" tools={compareLegend} baseline>
          <HourChart
            values={h.byHour}
            compare={vs?.habits.byHour ?? null}
            summary={`Scrobbles for each hour of the day in ${view.timeZone}. Busiest hour ${hh(busiest)}:00.`}
          />
          <p style={{ marginTop: 12, fontSize: 13, color: 'var(--fg2)' }}>
            Busiest hour: <strong style={{ fontWeight: 600 }}>{hh(busiest)}:00 to {hh(busiest)}:59</strong>, {fmt.percent(total ? (h.byHour[busiest] ?? 0) / total : 0, 1)} of scrobbles.
          </p>
          <DataTable
            hidden
            caption="Scrobbles by hour of day"
            rows={h.byHour.map((v, i) => ({ i, v, c: vs?.habits.byHour[i] }))}
            rowKey={(r) => String(r.i)}
            columns={[
              { header: 'Hour', cell: (r) => `${hh(r.i)}:00` },
              { header: view.currentLabel, numeric: true, cell: (r) => fmt.count(r.v) },
              ...(vs && view.compareLabel ? [{ header: view.compareLabel, numeric: true, cell: (r: { c?: number }) => fmt.count(r.c ?? 0) }] : []),
            ]}
          />
        </Module>
        <Module title="Day of week">
          <WeekdayBars
            values={h.byWeekday}
            compare={vs?.habits.byWeekday ?? null}
            format={fmt.count}
            summary={`Scrobbles by day of week, Monday first. Busiest: ${WEEKDAY_SHORT[busiestDay]}.`}
          />
          <DataTable
            hidden
            caption="Scrobbles by day of week"
            rows={WEEKDAY_SHORT.map((d, i) => ({ d, v: h.byWeekday[i] ?? 0, c: vs?.habits.byWeekday[i] }))}
            rowKey={(r) => r.d}
            columns={[
              { header: 'Day', cell: (r) => r.d },
              { header: view.currentLabel, numeric: true, cell: (r) => fmt.count(r.v) },
              ...(vs && view.compareLabel ? [{ header: view.compareLabel, numeric: true, cell: (r: { c?: number }) => fmt.count(r.c ?? 0) }] : []),
            ]}
          />
        </Module>
      </ModuleRow>

      <ModuleRow layout="rows84">
        <Module title="Day and hour" tools={<HeatRamp />} baseline>
          <Heatmap values={h.byWeekdayHour} format={fmt.count} summary="Heatmap of scrobbles by weekday and hour, darker cells have fewer scrobbles." />
          <DataTable
            hidden
            caption="Scrobbles by weekday and hour"
            rows={WEEKDAY_SHORT.map((d, i) => ({ d, cells: h.byWeekdayHour[i] ?? [] }))}
            rowKey={(r) => r.d}
            columns={[
              { header: 'Day', cell: (r) => r.d },
              ...Array.from({ length: 24 }, (_, hour) => ({ header: `${hh(hour)}:00`, numeric: true, cell: (r: { cells: number[] }) => fmt.count(r.cells[hour] ?? 0) })),
            ]}
          />
        </Module>
        <Module
          title="Seasonal pattern"
          caption={`Average scrobbles per day, by month. Seasons follow the ${hemisphere} hemisphere from your timezone.`}
        >
          <SeasonalChart
            values={h.avgPerDayByMonth}
            hemisphere={hemisphere}
            summary={`Average scrobbles per day for each month. Highest in ${MONTH_NAMES[peakMonth]}.`}
          />
          <DataTable
            hidden
            caption="Average scrobbles per day by month"
            rows={MONTH_NAMES.map((m, i) => ({ m, v: h.avgPerDayByMonth[i] ?? 0 }))}
            rowKey={(r) => r.m}
            columns={[
              { header: 'Month', cell: (r) => r.m },
              { header: 'Scrobbles per day', numeric: true, cell: (r) => fmt.count(r.v) },
            ]}
          />
        </Module>
      </ModuleRow>
    </Section>
  );
}

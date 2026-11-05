import type { CSSProperties } from 'react';
import { Link } from 'react-router-dom';
import { MONTH_NAMES, WEEKDAY_SHORT, addDays, isoWeekOf, monthEnd, monthStart, parseIsoDate } from '../../lib/dates';
import type { Formatter } from '../../lib/format';
import { longDate } from '../../lib/period';
import { HEAT_RAMP, quantileBucketer, ratio } from '../../lib/scale';
import { STATUS_TEXT, monthShort, monthWeeks, weekDates, type DayStatus, type Focus } from './model';
import { calendarMove, gridMove, useRoving } from './useRovingGrid';
import { DayPlaysHover } from './DayPlaysHover';
import styles from './TimeMachine.module.css';

interface Common {
  fmt: Formatter;
  hrefFor(f: Focus): string;
}

const pad = (n: number) => String(n).padStart(2, '0');

/** Cell colour for a quantile step: the Overview's accent ramp, mixed into the surface so labels stay legible. */
function heat(q: number): CSSProperties | undefined {
  if (q < 0) return undefined;
  return { background: `color-mix(in srgb, var(--ac) ${Math.round(HEAT_RAMP[q]! * 100)}%, var(--s1))`, color: q >= 3 ? 'var(--acfg)' : undefined };
}

function statusClass(status: DayStatus): string | undefined {
  return status === 'none' ? styles.missing : status === 'partial' ? styles.partial : status === 'future' ? styles.future : undefined;
}

/** "33 scrobbles", "no scrobbles", or what is known about a day without any. */
function countText(fmt: Formatter, n: number, status: DayStatus): string {
  if (n > 0) return `${fmt.count(n)} ${n === 1 ? 'scrobble' : 'scrobbles'}${status === 'partial' ? ', partly imported' : ''}`;
  return status === 'complete' ? 'no scrobbles' : STATUS_TEXT[status];
}

// ---------- The timeline: every year, then the months of the year in focus ----------

export function YearsStrip({ years, selected, fmt, hrefFor }: Common & { years: Array<{ key: string; scrobbles: number }>; selected: number | null }) {
  const keys = years.map((y) => y.key);
  const max = Math.max(0, ...years.map((y) => y.scrobbles));
  const { onKeyDown, itemProps } = useRoving(keys, selected === null ? null : String(selected), gridMove(keys, keys.length));
  return (
    <nav className={styles.strip} aria-label="Years" onKeyDown={onKeyDown}>
      {years.map((y) => (
        <Link
          key={y.key}
          to={hrefFor({ kind: 'year', year: Number(y.key) })}
          className={styles.stripItem}
          aria-current={String(selected) === y.key ? 'true' : undefined}
          aria-label={`${y.key}, ${countText(fmt, y.scrobbles, 'complete')}`}
          {...itemProps(y.key)}
        >
          <span className={styles.stripTrack} aria-hidden="true"><span className={styles.stripBar} style={{ height: `${Math.max(y.scrobbles ? 4 : 0, ratio(y.scrobbles, max) * 100)}%` }} /></span>
          <span className={styles.stripLabel} aria-hidden="true">{`’${y.key.slice(2)}`}</span>
        </Link>
      ))}
    </nav>
  );
}

export function MonthsStrip({ year, months, selected, statusOf, fmt, hrefFor }: Common & {
  year: number;
  months: Map<string, number>;
  selected: number | null;
  statusOf(key: string): DayStatus;
}) {
  const keys = Array.from({ length: 12 }, (_, i) => `${year}-${pad(i + 1)}`);
  const max = Math.max(0, ...keys.map((k) => months.get(k) ?? 0));
  const { onKeyDown, itemProps } = useRoving(keys, selected === null ? null : `${year}-${pad(selected)}`, gridMove(keys, 12));
  return (
    <nav className={`${styles.strip} ${styles.months}`} aria-label={`Months of ${year}`} onKeyDown={onKeyDown}>
      {keys.map((key, i) => {
        const n = months.get(key) ?? 0;
        const status = statusOf(key);
        return (
          <Link
            key={key}
            to={hrefFor({ kind: 'month', year, month: i + 1 })}
            className={`${styles.stripItem} ${statusClass(status) ?? ''}`}
            aria-current={selected === i + 1 ? 'true' : undefined}
            aria-label={`${MONTH_NAMES[i]} ${year}, ${countText(fmt, n, status)}`}
            {...itemProps(key)}
          >
            <span className={styles.stripTrack} aria-hidden="true"><span className={styles.stripBar} style={{ height: `${Math.max(n ? 4 : 0, ratio(n, max) * 100)}%` }} /></span>
            <span className={styles.stripLabel} aria-hidden="true">{monthShort(i + 1)}</span>
          </Link>
        );
      })}
    </nav>
  );
}

// ---------- The whole history: a row of months for every year ----------

export function HistoryGrid({ years, months, statusOf, fmt, hrefFor }: Common & {
  years: string[];
  months: Map<string, number>;
  statusOf(key: string): DayStatus;
}) {
  const keys = years.flatMap((y) => Array.from({ length: 12 }, (_, i) => `${y}-${pad(i + 1)}`));
  const bucket = quantileBucketer(keys.map((k) => months.get(k) ?? 0), HEAT_RAMP.length);
  const { onKeyDown, itemProps } = useRoving(keys, null, gridMove(keys, 12));
  return (
    <div className={styles.historyGrid} role="grid" aria-label="Scrobbles per month, every year" onKeyDown={onKeyDown}>
      <div className={styles.historyRow} role="row" aria-hidden="true">
        <span />
        {MONTH_NAMES.map((m) => <span key={m} className={styles.colHead}>{m.slice(0, 1)}<span className={styles.wideOnly}>{m.slice(1, 3)}</span></span>)}
      </div>
      {years.map((y) => (
        <div key={y} className={styles.historyRow} role="row">
          <span role="rowheader" className={styles.rowHead}>
            <Link to={hrefFor({ kind: 'year', year: Number(y) })} tabIndex={-1}>{y}</Link>
          </span>
          {Array.from({ length: 12 }, (_, i) => {
            const key = `${y}-${pad(i + 1)}`;
            const n = months.get(key) ?? 0;
            const status = statusOf(key);
            return (
              <span key={key} role="gridcell">
                <Link
                  to={hrefFor({ kind: 'month', year: Number(y), month: i + 1 })}
                  className={`${styles.heatCell} ${statusClass(status) ?? ''}`}
                  style={status === 'future' ? undefined : heat(bucket(n))}
                  aria-label={`${MONTH_NAMES[i]} ${y}, ${countText(fmt, n, status)}`}
                  title={`${MONTH_NAMES[i]} ${y}: ${countText(fmt, n, status)}`}
                  {...itemProps(key)}
                />
              </span>
            );
          })}
        </div>
      ))}
    </div>
  );
}

// ---------- A year: twelve small months ----------

export function YearCalendar({ year, days, statusOf, fmt, hrefFor }: Common & {
  year: number;
  days: Map<string, number>;
  statusOf(date: string): DayStatus;
}) {
  const bucket = quantileBucketer([...days.values()], HEAT_RAMP.length);
  return (
    <div className={styles.yearGrid}>
      {Array.from({ length: 12 }, (_, i) => (
        <MiniMonth key={i} year={year} month={i + 1} days={days} bucket={bucket} statusOf={statusOf} fmt={fmt} hrefFor={hrefFor} />
      ))}
    </div>
  );
}

function MiniMonth({ year, month, days, bucket, statusOf, fmt, hrefFor }: Common & {
  year: number;
  month: number;
  days: Map<string, number>;
  bucket(n: number): number;
  statusOf(date: string): DayStatus;
}) {
  const from = monthStart(year, month);
  const to = monthEnd(year, month);
  const weeks = monthWeeks(year, month);
  const dates = weeks.flat().filter((d) => d >= from && d <= to);
  const { onKeyDown, itemProps } = useRoving(dates, null, calendarMove);
  const total = dates.reduce((sum, d) => sum + (days.get(d) ?? 0), 0);
  return (
    <section className={styles.miniMonth} aria-label={`${MONTH_NAMES[month - 1]} ${year}`}>
      <Link to={hrefFor({ kind: 'month', year, month })} className={styles.miniTitle}>
        <span>{MONTH_NAMES[month - 1]}</span>
        <span className="mono">{fmt.count(total)}</span>
      </Link>
      <div className={styles.miniGrid} role="grid" onKeyDown={onKeyDown}>
        {weeks.map((week) => (
          <div key={week[0]} role="row" className={styles.miniRow}>
            {week.map((date) => {
              if (date < from || date > to) return <span key={date} role="gridcell" className={styles.miniBlank} />;
              const n = days.get(date) ?? 0;
              const status = statusOf(date);
              return (
                <span key={date} role="gridcell">
                  <Link
                    to={hrefFor({ kind: 'day', date })}
                    className={`${styles.miniDay} ${statusClass(status) ?? ''}`}
                    style={status === 'future' ? undefined : heat(bucket(n))}
                    aria-label={`${longDate(date)}, ${countText(fmt, n, status)}`}
                    title={`${longDate(date)}: ${countText(fmt, n, status)}`}
                    {...itemProps(date)}
                  />
                </span>
              );
            })}
          </div>
        ))}
      </div>
    </section>
  );
}

// ---------- A month: the calendar, with week numbers ----------

export function MonthCalendar({ year, month, days, statusOf, selectedDate, fmt, hrefFor }: Common & {
  year: number;
  month: number;
  days: Map<string, number>;
  statusOf(date: string): DayStatus;
  selectedDate?: string;
}) {
  const weeks = monthWeeks(year, month);
  const dates = weeks.flat();
  const from = monthStart(year, month);
  const to = monthEnd(year, month);
  const bucket = quantileBucketer(dates.map((d) => days.get(d) ?? 0), HEAT_RAMP.length);
  const { onKeyDown, itemProps } = useRoving(dates, selectedDate ?? null, calendarMove);
  return (
    <div className={styles.calendar} role="grid" aria-label={`${MONTH_NAMES[month - 1]} ${year}`} onKeyDown={onKeyDown}>
      <div className={styles.calRow} role="row">
        <span className={styles.colHead} role="columnheader">Wk</span>
        {WEEKDAY_SHORT.map((d) => <span key={d} className={styles.colHead} role="columnheader">{d}</span>)}
      </div>
      {weeks.map((week) => {
        const w = isoWeekOf(week[0]!);
        return (
          <div key={week[0]} className={styles.calRow} role="row">
            <span role="rowheader" className={styles.weekHead}>
              <Link to={hrefFor({ kind: 'week', ...w })} className={styles.weekLink} aria-label={`Week ${w.week}, ${w.isoYear}`}>{w.week}</Link>
            </span>
            {week.map((date, col) => {
              const n = days.get(date) ?? 0;
              const status = statusOf(date);
              const outside = date < from || date > to;
              return (
                <span key={date} role="gridcell" aria-selected={date === selectedDate ? 'true' : undefined}>
                  <DayPlaysHover date={date} count={n} label={countText(fmt, n, status)} alignRight={col >= 4}>
                  <Link
                    to={hrefFor({ kind: 'day', date })}
                    className={`${styles.calDay} ${outside ? styles.outside : ''} ${statusClass(status) ?? ''} ${date === selectedDate ? styles.selected : ''}`}
                    style={status === 'future' || outside ? undefined : heat(bucket(n))}
                    aria-label={`${longDate(date)}, ${countText(fmt, n, status)}`}
                    {...itemProps(date)}
                  >
                    <span className={styles.calDate}>{parseIsoDate(date).getUTCDate()}</span>
                  </Link>
                  </DayPlaysHover>
                </span>
              );
            })}
          </div>
        );
      })}
    </div>
  );
}

// ---------- A week: seven days ----------

export function WeekDays({ week, days, statusOf, fmt, hrefFor }: Common & {
  week: Extract<Focus, { kind: 'week' }>;
  days: Map<string, number>;
  statusOf(date: string): DayStatus;
}) {
  const dates = weekDates(week);
  const max = Math.max(0, ...dates.map((d) => days.get(d) ?? 0));
  const { onKeyDown, itemProps } = useRoving(dates, null, gridMove(dates, 7));
  return (
    <nav className={styles.weekDays} aria-label={`Days of week ${week.week}`} onKeyDown={onKeyDown}>
      {dates.map((date, i) => {
        const n = days.get(date) ?? 0;
        const status = statusOf(date);
        const d = parseIsoDate(date);
        return (
          <DayPlaysHover key={date} date={date} count={n} label={countText(fmt, n, status)} alignRight={i >= 4}>
          <Link to={hrefFor({ kind: 'day', date })} className={`${styles.weekDay} ${statusClass(status) ?? ''}`}
                aria-label={`${longDate(date)}, ${countText(fmt, n, status)}`} {...itemProps(date)}>
            <span className="eyebrow" aria-hidden="true">{WEEKDAY_SHORT[i]}</span>
            <span className={styles.weekDate} aria-hidden="true">{d.getUTCDate()} {monthShort(d.getUTCMonth() + 1)}</span>
            <span className={`mono ${styles.weekCount}`} aria-hidden="true">{n > 0 ? fmt.count(n) : status === 'complete' ? '0' : STATUS_TEXT[status]}</span>
            <span className={styles.weekBar} aria-hidden="true"><span style={{ width: `${ratio(n, max) * 100}%` }} /></span>
          </Link>
          </DayPlaysHover>
        );
      })}
    </nav>
  );
}

// ---------- A custom range: a bar per day, or per month when it is long ----------

export function RangeBars({ from, to, days, months, statusOf, fmt, hrefFor }: Common & {
  from: string;
  to: string;
  days: Map<string, number> | null;
  months: Map<string, number>;
  statusOf(date: string): DayStatus;
}) {
  const byDay = days !== null && (parseIsoDate(to).getTime() - parseIsoDate(from).getTime()) / 86_400_000 < 62;
  const items: Array<{ key: string; label: string; n: number; focus: Focus; status: DayStatus }> = [];
  if (byDay) {
    for (let d = from; d <= to; d = addDays(d, 1)) items.push({ key: d, label: longDate(d), n: days!.get(d) ?? 0, focus: { kind: 'day', date: d }, status: statusOf(d) });
  } else {
    for (let m = from.slice(0, 7); m <= to.slice(0, 7);) {
      const [y, mo] = m.split('-').map(Number);
      items.push({ key: m, label: `${MONTH_NAMES[mo! - 1]} ${y}`, n: months.get(m) ?? 0, focus: { kind: 'month', year: y!, month: mo! }, status: 'complete' });
      m = mo === 12 ? `${y! + 1}-01` : `${y}-${pad(mo! + 1)}`;
    }
  }
  const keys = items.map((i) => i.key);
  const max = Math.max(0, ...items.map((i) => i.n));
  const { onKeyDown, itemProps } = useRoving(keys, null, gridMove(keys, keys.length));
  return (
    <div>
      <nav className={styles.rangeBars} aria-label={byDay ? 'Days in the range' : 'Months in the range'} onKeyDown={onKeyDown}>
        {items.map((i) => (
          <Link key={i.key} to={hrefFor(i.focus)} className={`${styles.rangeBar} ${statusClass(i.status) ?? ''}`}
                aria-label={`${i.label}, ${countText(fmt, i.n, i.status)}`} title={`${i.label}: ${countText(fmt, i.n, i.status)}`} {...itemProps(i.key)}>
            <span style={{ height: `${Math.max(i.n ? 3 : 0, ratio(i.n, max) * 100)}%` }} />
          </Link>
        ))}
      </nav>
      <div className={styles.rangeAxis} aria-hidden="true">
        <span>{items[0]?.label}</span>
        <span>{items[items.length - 1]?.label}</span>
      </div>
    </div>
  );
}

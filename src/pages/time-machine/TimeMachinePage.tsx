import { useEffect, useMemo, useRef, type KeyboardEvent } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { LoadingState, MessageState } from '../../components/states/States';
import stateStyles from '../../components/states/States.module.css';
import { Icon } from '../../components/ui/Icon';
import { NotConnectedError } from '../../data/api';
import { useAppData } from '../../data/AppDataContext';
import type { HistoryCalendar } from '../../data/types';
import { useAsync } from '../../data/useAsync';
import { useMediaQuery } from '../../hooks/useMediaQuery';
import { addDays, isoWeekStart } from '../../lib/dates';
import { parsePeriod, periodRange, serializePeriod } from '../../lib/period';
import { usePeriod } from '../../state/PeriodContext';
import { HistoryGrid, MonthCalendar, MonthsStrip, RangeBars, WeekDays, YearCalendar, YearsStrip } from './Navigator';
import { OnThisDayPanel } from './OnThisDayPanel';
import { PlayLog } from './PlayLog';
import {
  LEVEL_NOUN, atFor, crumbLabel, dayStatusOf, focusFromAt, focusTitle, monthStatusOf, neighbour, overviewHref, parentOf, rangeText,
  timeMachineHref, toFocus, trailOf, type Focus,
} from './model';
import styles from './TimeMachine.module.css';

/**
 * Time Machine: exactly what was played, when. A timeline of the whole history, then a year, a
 * month (calendar), an ISO week, a day (every scrobble, with "On this day") or a custom range.
 *
 * The focus is the shared period, so the Overview follows it; moving around here adds browser
 * history entries, so Back and Forward retrace the way. Arriving without a deep link (`?at=`) or a
 * custom range opens the latest day with listening.
 */
export function TimeMachinePage() {
  const { api, connection, timeZone } = useAppData();
  const { current, compare, today } = usePeriod();
  const [params, setParams] = useSearchParams();
  const navigate = useNavigate();
  // A signed-in account can hold plays without a Last.fm import: Spotify records them directly.
  const connected = connection.status === 'success' && connection.data.status !== 'signed_out';
  const history = useAsync(connected ? 'time-machine:calendar' : null, (signal) => api.getCalendar(signal));

  // The URL is consistent when `at` matches the period; only then is a place shown. Arriving, the
  // effect below makes it so: the deep link, a custom range, or the latest day with listening.
  // Afterwards the period bar may change the period, and `at` is brought back in step.
  const urlPeriod = parsePeriod(params.get('period'));
  const at = params.get('at');
  const consistent = urlPeriod !== null && at === atFor(toFocus(urlPeriod, today));
  const focus: Focus | null = consistent ? toFocus(urlPeriod, today) : null;
  const arrived = useRef(false);
  const lastDay = history.status === 'success' ? history.data.lastDay : undefined;

  useEffect(() => {
    if (consistent) {
      arrived.current = true;
      return;
    }
    if (!urlPeriod) return; // the period provider puts one in the URL first
    if (arrived.current) {
      setParams((prev) => {
        const next = new URLSearchParams(prev);
        const want = atFor(toFocus(urlPeriod, today));
        if (want) next.set('at', want);
        else next.delete('at');
        return next;
      }, { replace: true });
      return;
    }
    const target = focusFromAt(at) ?? (urlPeriod.kind === 'custom' ? urlPeriod : lastDay !== undefined ? (lastDay ? { kind: 'day' as const, date: lastDay } : { kind: 'all' as const }) : null);
    if (!target) return; // waiting for the history
    arrived.current = true;
    navigate(timeMachineHref(target, current, compare, today), { replace: true });
  });

  useEffect(() => {
    document.title = `Time Machine${focus ? ` · ${focusTitle(focus)}` : ''} · Runout`;
  }, [focus]);

  const hrefFor = (f: Focus) => timeMachineHref(f, current, compare, today);

  // Escape goes up a level, unless something else (a field, an open menu or dialog) needs it.
  const onKeyDown = (e: KeyboardEvent) => {
    if (e.key !== 'Escape' || e.defaultPrevented || !focus || isTyping(e.target) || somethingOpen()) return;
    const up = parentOf(focus);
    if (!up) return;
    e.preventDefault();
    navigate(hrefFor(up));
  };

  return (
    <main id="main" className={styles.main} onKeyDown={onKeyDown}>
      {focus ? <Header focus={focus} history={history.status === 'success' ? history.data : null} hrefFor={hrefFor} /> : (
        <header className={styles.header}>
          <div className="eyebrow">Time Machine</div>
          <h1 className={styles.title}>Time Machine</h1>
        </header>
      )}
      <Body connected={connected} history={history} focus={focus} hrefFor={hrefFor} />
      {focus && (
        <p className={styles.footnote}>
          Every scrobble in the order it was played. Times use your timezone, {timeZone.replace(/_/g, ' ')}.
        </p>
      )}
    </main>
  );
}

function isTyping(target: EventTarget | null): boolean {
  const el = target as HTMLElement | null;
  return !!el && (el.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(el.tagName));
}

function somethingOpen(): boolean {
  return !!document.querySelector('[role="dialog"], [aria-modal="true"], [aria-expanded="true"]');
}

// ---------- Header: where you are, and the way around ----------

function Header({ focus, history, hrefFor }: { focus: Focus; history: HistoryCalendar | null; hrefFor(f: Focus): string }) {
  const { current, compare, today } = usePeriod();
  const trail = trailOf(focus);
  const prev = neighbour(focus, -1, today, history?.firstDay ?? null);
  const next = neighbour(focus, 1, today, history?.firstDay ?? null);
  const noun = LEVEL_NOUN[focus.kind];
  const range = focus.kind === 'week' ? periodRange(focus, today) : null;

  return (
    <header className={styles.header}>
      <nav aria-label="Time Machine levels" className={styles.trail}>
        <ol>
          {trail.map((f, i) => (
            <li key={serializePeriod(f)}>
              {i === trail.length - 1
                ? <span aria-current="page">{crumbLabel(f)}</span>
                : <Link to={hrefFor(f)}>{crumbLabel(f)}</Link>}
            </li>
          ))}
        </ol>
      </nav>
      <div className={styles.titleRow}>
        <div>
          <h1 className={styles.title}>{focusTitle(focus)}</h1>
          {range && <p className={styles.subtitle}>{rangeText(range.from, range.to)}</p>}
        </div>
        <div className={styles.headerActions}>
          {focus.kind !== 'all' && (
            <div className={styles.stepper} role="group" aria-label={`Previous or next ${noun}`}>
              <StepLink to={prev && hrefFor(prev)} label={prev ? `Previous ${noun}: ${focusTitle(prev)}` : `No earlier ${noun}`} icon="chevron_left" />
              <StepLink to={next && hrefFor(next)} label={next ? `Next ${noun}: ${focusTitle(next)}` : `No later ${noun}`} icon="chevron_right" />
            </div>
          )}
          <Link to={overviewHref(focus, current, compare, today)} className={styles.overviewLink}>
            <Icon name="monitoring" size={16} /> Open in Overview
          </Link>
        </div>
      </div>
    </header>
  );
}

function StepLink({ to, label, icon }: { to: string | null; label: string; icon: string }) {
  if (!to) return <span className={`${styles.stepButton} ${styles.stepDisabled}`} aria-label={label} role="link" aria-disabled="true"><Icon name={icon} /></span>;
  return <Link to={to} className={styles.stepButton} aria-label={label} title={label}><Icon name={icon} /></Link>;
}

// ---------- Body: connection states, then the timeline and the level in focus ----------

function Body({ connected, history, focus, hrefFor }: {
  connected: boolean;
  history: ReturnType<typeof useAsync<HistoryCalendar>>;
  focus: Focus | null;
  hrefFor(f: Focus): string;
}) {
  const { connection } = useAppData();
  const { withPeriod } = usePeriod();

  if (connection.status === 'loading') return <LoadingState label="Checking your account" />;
  if (connection.status === 'error') {
    return (
      <MessageState icon="error" tone="error" message="Runout could not be reached." detail="Your listening data is safe. Check your connection and try again.">
        <div className={stateStyles.actions}><button type="button" className={stateStyles.secondary} onClick={connection.retry}>Try again</button></div>
      </MessageState>
    );
  }
  if (!connected) {
    return <MessageState icon="lock" message="Sign in to see your listening." detail={<Link to={withPeriod('/overview')}>Sign in on the Overview</Link>} />;
  }
  if (history.status === 'error') {
    if (history.error instanceof NotConnectedError) {
      return <MessageState icon="link_off" message="No listening history is stored yet." detail={<Link to={withPeriod('/settings#sources')}>Connect Last.fm in Settings</Link>} />;
    }
    return (
      <MessageState icon="error" tone="error" message="Your listening history could not be loaded.">
        <div className={stateStyles.actions}><button type="button" className={stateStyles.secondary} onClick={history.retry}>Try again</button></div>
        <p className={stateStyles.technical}>{history.error.message}</p>
      </MessageState>
    );
  }
  if (history.status === 'loading' || !focus) return <LoadingState label="Loading your listening history" />;
  if (!history.data.lastDay && connection.data.status === 'connected') {
    return (
      <MessageState
        icon="link"
        message="Your listening history hasn’t been imported yet."
        detail={<><Link to={withPeriod('/settings#history')}>Start the import in Settings</Link>. Time Machine fills in once it has.</>}
      />
    );
  }
  if (!history.data.lastDay) {
    return (
      <MessageState
        icon="history"
        message="There are no scrobbles in your history yet."
        detail={<>Time Machine shows every scrobble once some are imported. <Link to={withPeriod('/settings#history')}>Import status</Link></>}
      />
    );
  }
  return <Explorer history={history.data} focus={focus} hrefFor={hrefFor} />;
}

/** The days fetched for a focus: its whole year for a year, month or day (moving around a year costs nothing more). */
function daysRange(focus: Focus): { from: string; to: string } | null {
  switch (focus.kind) {
    case 'all': return null;
    case 'year': return { from: `${focus.year}-01-01`, to: `${focus.year}-12-31` };
    case 'month': return { from: `${focus.year}-01-01`, to: `${focus.year}-12-31` };
    case 'day': return { from: `${focus.date.slice(0, 4)}-01-01`, to: `${focus.date.slice(0, 4)}-12-31` };
    case 'week': {
      const from = isoWeekStart(focus.isoYear, focus.week);
      return { from, to: addDays(from, 6) };
    }
    // Up to the calendar's limit (Analytics::Calendar::MAX_DAYS); longer ranges count per page of plays.
    case 'custom': return focus.to < addDays(focus.from, 400) ? { from: focus.from, to: focus.to } : null;
  }
}

function focusYear(focus: Focus): number | null {
  switch (focus.kind) {
    case 'year': case 'month': return focus.year;
    case 'day': return Number(focus.date.slice(0, 4));
    case 'week': return Number(addDays(isoWeekStart(focus.isoYear, focus.week), 3).slice(0, 4));
    default: return null;
  }
}

/** The month to mark in the strip: the month itself, a day's month, a week's by its Thursday. */
function focusMonth(focus: Focus): number | null {
  switch (focus.kind) {
    case 'month': return focus.month;
    case 'day': return Number(focus.date.slice(5, 7));
    case 'week': return Number(addDays(isoWeekStart(focus.isoYear, focus.week), 3).slice(5, 7));
    default: return null;
  }
}

function Explorer({ history, focus, hrefFor }: { history: HistoryCalendar; focus: Focus; hrefFor(f: Focus): string }) {
  const { api, fmt } = useAppData();
  const { today } = usePeriod();
  const range = daysRange(focus);
  const days = useAsync(range ? `days:${range.from}..${range.to}` : null, (signal) => api.getCalendarDays(range!.from, range!.to, signal));
  const dayCounts = useMemo(() => new Map(days.status === 'success' ? days.data.days.map((d) => [d.date, d.scrobbles]) : []), [days]);
  const months = useMemo(() => new Map(history.months.map((m) => [m.key, m.scrobbles])), [history]);
  const monthStatus = monthStatusOf(history.coverage.missing, today);
  const dayStatus = dayStatusOf(days.status === 'success' ? days.data.coverage.missing : [], today);

  // Every year from the first to today, so a silent year shows as silent rather than vanishing.
  const firstYear = Number(history.firstDay!.slice(0, 4));
  const lastYear = Number(today.slice(0, 4));
  const yearCounts = new Map(history.years.map((y) => [y.key, y.scrobbles]));
  const years = Array.from({ length: lastYear - firstYear + 1 }, (_, i) => String(firstYear + i))
    .map((key) => ({ key, scrobbles: yearCounts.get(key) ?? 0 }));
  const year = focusYear(focus);
  const common = { fmt, hrefFor };
  const daysReady = !range || days.status === 'success';
  const compact = useMediaQuery('(max-width: 767px)');

  return (
    <>
      <section className={styles.timeline} aria-label="Timeline">
        <YearsStrip years={years} selected={year} {...common} />
        {year !== null && (
          <MonthsStrip year={year} months={months} selected={focusMonth(focus)}
                       statusOf={monthStatus} {...common} />
        )}
      </section>

      {range && days.status === 'error' && (
        <p className={styles.logStatus} role="alert">
          The calendar could not be loaded. <button type="button" className={styles.textButton} onClick={days.retry}>Try again</button>
        </p>
      )}

      <div className={focus.kind === 'day' ? styles.dayLayout : undefined}>
        <section className={styles.panel} aria-label={focusTitle(focus)} aria-busy={!daysReady}>
          {focus.kind === 'all' && <HistoryGrid years={years.map((y) => y.key).reverse()} months={months} statusOf={monthStatus} {...common} />}
          {focus.kind === 'year' && daysReady && <YearCalendar year={focus.year} days={dayCounts} statusOf={dayStatus} {...common} />}
          {focus.kind === 'month' && daysReady && (
            <MonthCalendar year={focus.year} month={focus.month} days={dayCounts} statusOf={dayStatus} {...common} />
          )}
          {focus.kind === 'week' && daysReady && <WeekDays week={focus} days={dayCounts} statusOf={dayStatus} {...common} />}
          {focus.kind === 'custom' && daysReady && (
            <RangeBars from={focus.from} to={focus.to} days={range ? dayCounts : null} months={months} statusOf={dayStatus} {...common} />
          )}
          {focus.kind === 'day' && daysReady && (
            <div className={styles.dayMonth}>
              <MonthCalendar year={Number(focus.date.slice(0, 4))} month={Number(focus.date.slice(5, 7))} days={dayCounts} statusOf={dayStatus}
                             selectedDate={focus.date} {...common} />
            </div>
          )}
          {range && !daysReady && days.status === 'loading' && <p className={styles.logStatus} role="status">Loading the calendar</p>}

          {focus.kind === 'day' && compact && <OnThisDayPanel date={focus.date} hrefFor={hrefFor} compact />}

          {focus.kind === 'all'
            ? <p className={styles.hint}>Choose a year, or a month in the grid, to see what you played.</p>
            : (
              <>
                <h2 className={styles.logTitle}>
                  {focus.kind === 'day' ? 'Every scrobble' : `Every scrobble in this ${LEVEL_NOUN[focus.kind]}`}
                  {focus.kind === 'day' && dayCounts.has(focus.date) && <span className="mono">{fmt.count(dayCounts.get(focus.date)!)}</span>}
                </h2>
                <PlayLog focus={focus} label={focusTitle(focus)} dayCounts={dayCounts} countsPerPage={focus.kind === 'custom' && !range} />
              </>
            )}
        </section>
        {focus.kind === 'day' && !compact && <OnThisDayPanel date={focus.date} hrefFor={hrefFor} />}
      </div>
    </>
  );
}


import { Link } from 'react-router-dom';
import { useAppData } from '../../data/AppDataContext';
import type { OnThisDayYear } from '../../data/types';
import { useAsync } from '../../data/useAsync';
import { MONTH_NAMES, WEEKDAY_SHORT, parseIsoDate } from '../../lib/dates';
import type { Focus } from './model';
import styles from './TimeMachine.module.css';

/**
 * The same calendar date in the other years of the history (GET /api/on-this-day): real counts and
 * the most played artists, each linking to that day. Secondary to the day's own plays.
 */
export function OnThisDayPanel({ date, hrefFor }: { date: string; hrefFor(f: Focus): string }) {
  const { api } = useAppData();
  const data = useAsync(`on-this-day:${date}`, (signal) => api.getOnThisDay(date, signal));
  const d = parseIsoDate(date);
  const day = `${d.getUTCDate()} ${MONTH_NAMES[d.getUTCMonth()]}`;

  return (
    <aside className={styles.onThisDay} aria-labelledby="on-this-day-title">
      <h2 id="on-this-day-title" className={styles.asideTitle}>On this day</h2>
      <p className={styles.asideIntro}>{day} in your other years.</p>
      {data.status === 'loading' && <p className={styles.logStatus} role="status">Loading</p>}
      {data.status === 'error' && (
        <p className={styles.logStatus} role="alert">
          Could not be loaded. <button type="button" className={styles.textButton} onClick={data.retry}>Try again</button>
        </p>
      )}
      {data.status === 'success' && (
        <>
          {data.data.leapDay && <p className={styles.asideIntro}>29 February comes round only in leap years, so only those are listed.</p>}
          {data.data.years.length === 0
            ? <p className={styles.asideIntro}>No other years in your history yet.</p>
            : (
              <ol className={styles.otdList}>
                {data.data.years.map((y) => <YearRow key={y.date} year={y} hrefFor={hrefFor} />)}
              </ol>
            )}
        </>
      )}
    </aside>
  );
}

function YearRow({ year, hrefFor }: { year: OnThisDayYear; hrefFor(f: Focus): string }) {
  const { fmt } = useAppData();
  const d = parseIsoDate(year.date);
  const weekday = WEEKDAY_SHORT[(d.getUTCDay() + 6) % 7];
  const status = year.scrobbles > 0
    ? `${fmt.count(year.scrobbles)} ${year.scrobbles === 1 ? 'scrobble' : 'scrobbles'}${year.coverage === 'partial' ? ', partly imported' : ''}`
    : year.coverage === 'complete' ? 'No listening' : year.coverage === 'partial' ? 'None in the imported part' : 'Not imported';
  return (
    <li className={`${styles.otdYear} ${year.scrobbles === 0 && year.coverage !== 'complete' ? styles.otdMissing : ''}`}>
      <Link to={hrefFor({ kind: 'day', date: year.date })} className={styles.otdLink} aria-label={`${d.getUTCFullYear()}, ${weekday}: ${status}`}>
        <span className={styles.otdHead}>
          <span className={styles.otdYearNum}>{d.getUTCFullYear()}</span>
          <span className="mono">{weekday}</span>
          <span className={`mono ${styles.otdCount}`}>{status}</span>
        </span>
        {year.topArtists.length > 0 && (
          <span className={styles.otdArtists}>{year.topArtists.map((a) => a.name).join(', ')}</span>
        )}
        {year.topTrack && year.topTrack.scrobbles > 1 && (
          <span className={styles.otdTrack}>{year.topTrack.name} by {year.topTrack.artist}, {fmt.count(year.topTrack.scrobbles)} plays</span>
        )}
      </Link>
    </li>
  );
}

import { Link, useNavigate } from 'react-router-dom';
import type { TopEntry, TopKind } from '../../data/types';
import type { Formatter } from '../../lib/format';
import { approvedImage } from '../../lib/artwork';
import { Artwork } from '../ui/Artwork';
import { Sparkline } from './Sparkline';
import styles from './TopTable.module.css';

const SINGULAR: Record<TopKind, string> = { artists: 'Artist', albums: 'Album', tracks: 'Track' };

interface Props {
  kind: TopKind;
  entries: TopEntry[];
  total: number;
  fmt: Formatter;
  hrefFor(entry: TopEntry): string;
  viewAllHref: string;
  panelId: string;
  labelledBy: string;
}

/** Ranked table; the whole row opens the detail page, the name is the real link. */
export function TopTable({ kind, entries, total, fmt, hrefFor, viewAllHref, panelId, labelledBy }: Props) {
  const navigate = useNavigate();
  return (
    <div id={panelId} role="tabpanel" aria-labelledby={labelledBy}>
      <div className={styles.wrap}>
        <table className={styles.table}>
          <thead>
            <tr>
              <th scope="col" style={{ width: 36 }} className={styles.sticky}>#</th>
              <th scope="col" colSpan={2}>{SINGULAR[kind]}</th>
              <th scope="col" style={{ width: 110 }}>Trend</th>
              <th scope="col" style={{ width: 96 }} className={styles.num}>Scrobbles</th>
              <th scope="col" style={{ width: 120, paddingLeft: 24 }}>First scrobble</th>
              <th scope="col" style={{ width: 120 }}>Latest</th>
            </tr>
          </thead>
          <tbody>
            {entries.map((e, i) => {
              const href = hrefFor(e);
              const sub = kind === 'artists' ? `${fmt.count(e.tracksPlayed ?? 0)} tracks played` : e.artist;
              return (
                <tr key={e.id} className={styles.row} onClick={(ev) => !(ev.target as HTMLElement).closest('a') && navigate(href)}>
                  <td className={`${styles.rank} ${styles.sticky}`}>{i + 1}</td>
                  <td style={{ width: 48 }}><Artwork src={e.imageUrl} name={e.name} /></td>
                  <td>
                    <Link to={href} className={styles.nameLink}>
                      <span className={styles.name}>{e.name}</span>
                      {sub && <span className={styles.sub}>{sub}</span>}
                    </Link>
                  </td>
                  <td><Sparkline values={e.trend} /></td>
                  <td className={styles.num}>{fmt.count(e.scrobbles)}</td>
                  <td className={styles.date} style={{ paddingLeft: 24 }}>{fmt.date(e.firstScrobble)}</td>
                  <td className={styles.date}>{fmt.date(e.latestScrobble)}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      <div className={styles.foot}>
        <span>
          Showing 1 to {entries.length} of {fmt.count(total)}
          {entries.some((e) => approvedImage(e.imageUrl)) && (
            <> · Artwork from the <a href="https://coverartarchive.org" target="_blank" rel="noreferrer">Cover Art Archive</a></>
          )}
        </span>
        <Link to={viewAllHref}>View all {kind}</Link>
      </div>
    </div>
  );
}

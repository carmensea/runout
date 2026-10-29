import { niceCeil, ratio } from '../../lib/scale';
import styles from './MoreCharts.module.css';

interface Props {
  months: Array<{ key: string; newArtists: number; explorationShare: number }>;
  formatCount(n: number): string;
  formatShare(share: number): string;
  formatMonth(key: string): string;
  summary: string;
}

const H = 200;
const W = 240;

/** New artists per month (bars, left axis) and exploration share (accent line, right axis). */
export function DiscoveryChart({ months, formatCount, formatShare, formatMonth, summary }: Props) {
  const n = months.length;
  const countCeil = niceCeil(Math.max(0, ...months.map((m) => m.newArtists)));
  const shareCeil = Math.min(1, Math.ceil(Math.max(0.01, ...months.map((m) => m.explorationShare)) * 10) / 10);
  const line = months
    .map((m, i) => `${i ? 'L' : 'M'}${(((i + 0.5) / n) * W).toFixed(1)},${(H - ratio(m.explorationShare, shareCeil) * H).toFixed(1)}`)
    .join(' ');
  const tickIdx = n <= 5 ? months.map((_, i) => i) : [0, 1, 2, 3].map((k) => Math.round((k * (n - 1)) / 4)).concat(n - 1);

  return (
    <div role="img" aria-label={summary}>
      <div className={styles.discFrame} aria-hidden="true">
        <div className={styles.discAxis} style={{ textAlign: 'right' }}>
          <span style={{ right: 0, top: '0%' }}>{formatCount(countCeil)}</span>
          <span style={{ right: 0, top: '50%' }}>{formatCount(countCeil / 2)}</span>
          <span style={{ right: 0, top: '100%' }}>{formatCount(0)}</span>
        </div>
        <div className={styles.discPlot}>
          <div className={styles.discBars}>
            {months.map((m) => <div key={m.key} style={{ height: `${ratio(m.newArtists, countCeil) * 100}%` }} />)}
          </div>
          <svg viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" width="100%" height={H} style={{ position: 'absolute', inset: 0 }}>
            <path d={line} fill="none" stroke="var(--ac)" strokeWidth="2" vectorEffect="non-scaling-stroke" />
          </svg>
        </div>
        <div className={styles.discAxis}>
          <span style={{ top: '0%' }}>{formatShare(shareCeil)}</span>
          <span style={{ top: '50%' }}>{formatShare(shareCeil / 2)}</span>
          <span style={{ top: '100%' }}>{formatShare(0)}</span>
        </div>
        <span />
        <div className={styles.discX}>
          {[...new Set(tickIdx)].map((i) => <span key={i}>{formatMonth(months[i]!.key)}</span>)}
        </div>
      </div>
    </div>
  );
}

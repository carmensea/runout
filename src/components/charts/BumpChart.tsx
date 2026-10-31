import { spreadLabels } from '../../lib/scale';
import styles from './MoreCharts.module.css';

export interface BumpSeries {
  id: string;
  name: string;
  ranks: Array<number | null>;
}

/** Categorical slots in order, each with its own dash style (HANDOFF.md "Encoding rules"). */
const STYLES = [
  { color: 'var(--c1)', width: 2.5, dash: undefined },
  { color: 'var(--c2)', width: 2, dash: '6 3' },
  { color: 'var(--c3)', width: 2, dash: undefined },
  { color: 'var(--c4)', width: 2, dash: '2 3' },
  { color: 'var(--c5)', width: 2, dash: undefined },
];

const W = 600;
const H = 200;
const MAX_RANK = 10;
const y = (rank: number) => ((Math.min(rank, MAX_RANK) - 1) / (MAX_RANK - 1)) * 190 + 5;

/** At most about eight year labels fit under the chart. */
const yearStep = (n: number) => Math.max(1, Math.ceil(n / 8));

/** Rank lines (1 at top), direct labels at the right end. Gaps where an artist left the top 10. */
export function BumpChart({ years, series, summary }: { years: number[]; series: BumpSeries[]; summary: string }) {
  const n = years.length;
  const x = (i: number) => (n > 1 ? (i / (n - 1)) * W : W / 2);

  const paths = series.map((s) => {
    let d = '';
    let pen = false;
    s.ranks.forEach((r, i) => {
      if (r === null) {
        pen = false;
        return;
      }
      d += `${pen ? 'L' : 'M'}${x(i).toFixed(1)},${y(r).toFixed(1)} `;
      pen = true;
    });
    return d.trim();
  });

  const lastY = series.map((s) => {
    const last = [...s.ranks].reverse().find((r) => r !== null);
    return last == null ? 100 : (y(last) / H) * 100;
  });
  const labelTop = spreadLabels(lastY, 8);

  return (
    <div role="img" aria-label={summary}>
      <div className={styles.bumpFrame} aria-hidden="true">
        <div className={styles.yRanks}>
          <span style={{ top: `${(y(1) / H) * 100}%` }}>1</span>
          <span style={{ top: `${(y(5) / H) * 100}%` }}>5</span>
          <span style={{ top: `${(y(10) / H) * 100}%` }}>10</span>
        </div>
        <svg className={styles.bumpSvg} viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" width="100%" height={H}>
          {paths.map((d, i) => {
            const st = STYLES[i % STYLES.length]!;
            return <path key={series[i]!.id} d={d} fill="none" stroke={st.color} strokeWidth={st.width} strokeDasharray={st.dash} vectorEffect="non-scaling-stroke" />;
          })}
        </svg>
        <div className={styles.bumpLabels}>
          {series.map((s, i) => (
            <span key={s.id} style={{ top: `${labelTop[i]}%`, color: STYLES[i % STYLES.length]!.color }}>{s.name}</span>
          ))}
        </div>
      </div>
      <div className={styles.bumpYears} aria-hidden="true">
        {/* A long history would run the years together: label every `step`th, keeping each slot. */}
        {years.map((yr, i) => <span key={yr}>{i % yearStep(n) === 0 ? yr : ''}</span>)}
      </div>
    </div>
  );
}

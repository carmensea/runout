import { useEffect, type ReactNode } from 'react';
import { Link, useParams, useSearchParams } from 'react-router-dom';
import { usePeriod } from '../state/PeriodContext';
import styles from './PendingScreen.module.css';

interface Props {
  eyebrow: string;
  title: string;
  /** What the screen will do, stated plainly. */
  description: string;
  /** Planned features (Lyrics, Mood) versus designed screens awaiting implementation. */
  planned?: boolean;
  /** Working controls that exist before the full screen is built. */
  children?: ReactNode;
}

/**
 * Integration point for routes whose screens are designed but not built in this codebase yet.
 * States that plainly and shows the parameters the screen received, so links into it
 * (for example from a chart bar into Time Machine) can be verified end to end.
 */
export function PendingScreen({ eyebrow, title, description, planned = false, children }: Props) {
  const params = useParams();
  const [search] = useSearchParams();
  const { withPeriod } = usePeriod();

  useEffect(() => {
    document.title = `${title} · Runout`;
  }, [title]);

  const received = [
    ...Object.entries(params).map(([k, v]) => [k, v ?? ''] as const),
    ...[...search.entries()].filter(([k]) => k === 'at'),
  ];

  return (
    <main id="main" className={styles.main}>
      <div className="eyebrow">{eyebrow}</div>
      <h1 className={styles.title}>{title}</h1>
      <p className={styles.body}>{description}</p>
      <div className={styles.panel} role="note">
        <strong style={{ color: 'var(--fg)', fontWeight: 600 }}>
          {planned ? 'Planned feature. Not available yet.' : 'This screen is designed but not built in this version of Runout.'}
        </strong>
        {received.length > 0 && (
          <dl>
            {received.map(([k, v]) => (
              <div key={k} style={{ display: 'contents' }}>
                <dt>{k}</dt>
                <dd>{v}</dd>
              </div>
            ))}
          </dl>
        )}
      </div>
      {children}
      <Link to={withPeriod('/overview')} className={styles.back}>Back to Overview</Link>
    </main>
  );
}

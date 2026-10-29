import type { ReactNode } from 'react';
import { Icon } from '../ui/Icon';
import styles from './States.module.css';

const SKELETON_BARS = [38, 52, 44, 61, 70, 58, 47, 66, 74, 63, 55, 49, 60, 68, 57, 45, 52, 64, 71, 59];

/** Keeps the frame of the page while data loads. No shimmer. */
export function LoadingState({ label }: { label: string }) {
  return (
    <div className={styles.loading} aria-busy="true">
      <p className={styles.statusText} role="status">{label}</p>
      <div className={styles.skelStats} aria-hidden="true">
        <div /><div /><div /><div />
      </div>
      <div className={styles.skelBars} aria-hidden="true">
        {SKELETON_BARS.map((h, i) => <div key={i} style={{ height: `${h}%` }} />)}
      </div>
    </div>
  );
}

export function MessageState({ icon, message, detail, children, tone }: { icon?: string; message: string; detail?: ReactNode; children?: ReactNode; tone?: 'error' }) {
  return (
    <div className={styles.centered} role={tone === 'error' ? 'alert' : 'status'}>
      {icon && <Icon name={icon} size={24} className={tone === 'error' ? styles.err : undefined} />}
      <p className={styles.message}>{message}</p>
      {detail && <div className={styles.detail}>{detail}</div>}
      {children}
    </div>
  );
}

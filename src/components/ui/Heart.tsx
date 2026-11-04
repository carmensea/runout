import { Icon } from './Icon';
import styles from './Heart.module.css';

/** A loved song's mark, beside its name. Announced as "Loved" so it reads in lists. */
export function Heart({ size = 12, className }: { size?: number; className?: string }) {
  return (
    <span className={`${styles.heart} ${className ?? ''}`} role="img" aria-label="Loved" title="Loved">
      <Icon name="favorite" size={size} />
    </span>
  );
}

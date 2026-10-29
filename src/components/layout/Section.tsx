import type { ReactNode } from 'react';
import styles from './Section.module.css';

interface Props {
  id: string;
  /** "02 / Listening habits" */
  eyebrow: string;
  title: string;
  description: ReactNode;
  /** Controls aligned to the right of the heading. */
  actions?: ReactNode;
  /** Secondary sections use a lighter rule and a smaller title. */
  minor?: boolean;
  children: ReactNode;
}

/** Dashboard section: 1px rule, mono eyebrow column, Newsreader title and one-line description. */
export function Section({ id, eyebrow, title, description, actions, minor, children }: Props) {
  const headingId = `${id}-title`;
  const Heading = minor ? 'h3' : 'h2';
  return (
    <section id={id} aria-labelledby={headingId} className={`${styles.section} ${minor ? styles.minor : ''}`}>
      <div className={styles.head}>
        <div className="eyebrow">{eyebrow}</div>
        <div>
          <Heading id={headingId} className={styles.title}>{title}</Heading>
          <p className={styles.description}>{description}</p>
        </div>
        {actions}
      </div>
      <div className={styles.body}>{children}</div>
    </section>
  );
}

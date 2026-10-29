import type { ReactNode } from 'react';
import styles from './Module.module.css';

interface Props {
  title: string;
  caption?: ReactNode;
  /** Controls or legend shown at the right of the title. */
  tools?: ReactNode;
  /** Align tools to the title baseline (legends) rather than the caption bottom (controls). */
  baseline?: boolean;
  headingLevel?: 3 | 4;
  /** Space between the heading block and the content. */
  gap?: 8 | 12 | 16;
  children: ReactNode;
  className?: string;
}

/** A chart or list module: Schibsted 15/600 title, muted caption, 16px to content. */
export function Module({ title, caption, tools, baseline, headingLevel = 3, gap = 16, children, className }: Props) {
  const H = headingLevel === 3 ? 'h3' : 'h4';
  return (
    <div className={`${styles.module} ${className ?? ''}`}>
      <div className={`${styles.head} ${baseline ? styles.baseline : ''}`} style={{ marginBottom: gap }}>
        <div>
          <H className="module-title">{title}</H>
          {caption && <p className={`caption ${styles.caption}`}>{caption}</p>}
        </div>
        {tools && <div className={styles.tools}>{tools}</div>}
      </div>
      {children}
    </div>
  );
}

export type RowLayout = 'rows2' | 'rows75' | 'rows84' | 'rows633';

export function ModuleRow({ layout, first, children }: { layout: RowLayout; first?: boolean; children: ReactNode }) {
  return <div className={`${styles[layout]} ${first ? styles.first : ''}`}>{children}</div>;
}

export function Legend({ items }: { items: Array<{ label: string; swatch: ReactNode }> }) {
  return (
    <span className={styles.legend}>
      {items.map((i) => (
        <span key={i.label} className={styles.legendItem}>
          {i.swatch}
          {i.label}
        </span>
      ))}
    </span>
  );
}

export function SecondaryButton(props: React.ButtonHTMLAttributes<HTMLButtonElement>) {
  return <button type="button" {...props} className={`${styles.secondary} ${props.className ?? ''}`} />;
}

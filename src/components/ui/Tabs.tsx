import { useRef, type KeyboardEvent } from 'react';
import styles from './Tabs.module.css';

interface Props<T extends string> {
  idBase: string;
  label: string;
  tabs: ReadonlyArray<{ id: T; label: string }>;
  value: T;
  onChange(id: NoInfer<T>): void;
  className?: string;
}

/** WAI-ARIA tabs with automatic activation. Panels use id `${idBase}-panel`. */
export function Tabs<T extends string>({ idBase, label, tabs, value, onChange, className }: Props<T>) {
  const refs = useRef<Array<HTMLButtonElement | null>>([]);

  function onKeyDown(e: KeyboardEvent, i: number) {
    const delta = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0;
    const next = e.key === 'Home' ? 0 : e.key === 'End' ? tabs.length - 1 : delta ? (i + delta + tabs.length) % tabs.length : null;
    if (next === null) return;
    e.preventDefault();
    onChange(tabs[next]!.id);
    refs.current[next]?.focus();
  }

  return (
    <div role="tablist" aria-label={label} className={`${styles.list} ${className ?? ''}`}>
      {tabs.map((t, i) => (
        <button
          key={t.id}
          ref={(el) => {
            refs.current[i] = el;
          }}
          type="button"
          role="tab"
          id={`${idBase}-tab-${t.id}`}
          aria-selected={t.id === value}
          aria-controls={`${idBase}-panel`}
          tabIndex={t.id === value ? 0 : -1}
          className={styles.tab}
          onClick={() => onChange(t.id)}
          onKeyDown={(e) => onKeyDown(e, i)}
        >
          {t.label}
        </button>
      ))}
    </div>
  );
}

import { useRef, type KeyboardEvent } from 'react';
import styles from './SegmentedControl.module.css';

export interface SegmentOption<T extends string> {
  value: T;
  label: string;
  disabled?: boolean;
  /** Explains why an option is disabled. */
  title?: string;
}

interface Props<T extends string> {
  label: string;
  options: ReadonlyArray<SegmentOption<NoInfer<T>>>;
  value: T;
  onChange(value: NoInfer<T>): void;
  size?: 'md' | 'sm';
  className?: string;
}

/** Radio group styled as segments. Arrow keys move and select; only the checked option is a tab stop. */
export function SegmentedControl<T extends string>({ label, options, value, onChange, size = 'md', className }: Props<T>) {
  const refs = useRef<Array<HTMLButtonElement | null>>([]);
  const enabled = options.map((o, i) => (o.disabled ? -1 : i)).filter((i) => i >= 0);
  const tabStop = options.some((o) => o.value === value) ? value : options[enabled[0] ?? 0]?.value;

  function onKeyDown(e: KeyboardEvent, index: number) {
    const delta = e.key === 'ArrowRight' || e.key === 'ArrowDown' ? 1 : e.key === 'ArrowLeft' || e.key === 'ArrowUp' ? -1 : 0;
    if (!delta) return;
    e.preventDefault();
    const pos = enabled.indexOf(index);
    const nextIndex = enabled[(pos + delta + enabled.length) % enabled.length];
    if (nextIndex === undefined) return;
    onChange(options[nextIndex]!.value);
    refs.current[nextIndex]?.focus();
  }

  return (
    <div role="radiogroup" aria-label={label} className={[styles.group, size === 'sm' ? styles.sm : '', className ?? ''].join(' ')}>
      {options.map((o, i) => {
        const checked = o.value === value;
        return (
          <button
            key={o.value}
            ref={(el) => {
              refs.current[i] = el;
            }}
            type="button"
            role="radio"
            aria-checked={checked}
            disabled={o.disabled}
            title={o.title}
            tabIndex={o.value === tabStop ? 0 : -1}
            className={`${styles.option} ${checked ? styles.selected : ''}`}
            onClick={() => onChange(o.value)}
            onKeyDown={(e) => onKeyDown(e, i)}
          >
            {o.label}
          </button>
        );
      })}
    </div>
  );
}

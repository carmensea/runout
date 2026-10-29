import { useEffect, useId, useRef, useState, type KeyboardEvent } from 'react';
import { createPortal } from 'react-dom';
import { MONTH_NAMES, isIsoDate } from '../../lib/dates';
import { defaultComparison, periodLabel, periodOfKind, periodRange, type Period, type PeriodKind } from '../../lib/period';
import { usePeriod } from '../../state/PeriodContext';
import { Icon } from '../ui/Icon';
import styles from './PeriodSheet.module.css';

/** Last.fm began recording scrobbles in 2002; nothing earlier can exist. */
const FIRST_POSSIBLE_YEAR = 2002;

const MODES: ReadonlyArray<{ kind: PeriodKind; label: string }> = [
  { kind: 'all', label: 'All time' },
  { kind: 'year', label: 'Year' },
  { kind: 'l12', label: 'Last 12 months' },
  { kind: 'month', label: 'Month' },
  { kind: 'custom', label: 'Custom range' },
];

/**
 * Bottom sheet for choosing the period on small screens. Choices are a draft until
 * "Show …" applies them, so browsing options does not reload every chart.
 */
export function PeriodSheet({ onClose }: { onClose(): void }) {
  const { current, compare, today, setBoth } = usePeriod();
  const titleId = useId();
  const sheetRef = useRef<HTMLDivElement>(null);
  const [draft, setDraft] = useState<Period>(current);
  const [comparing, setComparing] = useState(compare !== null);
  const [range, setRange] = useState(() => periodRange(current, today) ?? { from: today, to: today });
  const [error, setError] = useState<string | null>(null);
  const thisYear = Number(today.slice(0, 4));

  useEffect(() => {
    sheetRef.current?.querySelector<HTMLElement>('[aria-checked="true"]')?.focus();
  }, []);

  function onKeyDown(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      e.stopPropagation();
      onClose();
    }
    // Keep focus inside the sheet while it is open.
    if (e.key === 'Tab' && sheetRef.current) {
      const focusables = [...sheetRef.current.querySelectorAll<HTMLElement>('button:not(:disabled), input')];
      const first = focusables[0];
      const last = focusables[focusables.length - 1];
      if (e.shiftKey && document.activeElement === first) {
        e.preventDefault();
        last?.focus();
      } else if (!e.shiftKey && document.activeElement === last) {
        e.preventDefault();
        first?.focus();
      }
    }
  }

  function pickKind(kind: PeriodKind) {
    const next = periodOfKind(kind, draft, today);
    setDraft(next);
    if (kind === 'all') setComparing(false);
    if (kind === 'custom') setRange(periodRange(next, today) ?? range);
    setError(null);
  }

  function apply() {
    let next = draft;
    if (draft.kind === 'custom') {
      if (!isIsoDate(range.from) || !isIsoDate(range.to)) return setError('Enter both dates as YYYY-MM-DD.');
      if (range.from > range.to) return setError('The start date must be on or before the end date.');
      if (range.from > today) return setError('The range must start on or before today.');
      next = { kind: 'custom', ...range };
    }
    const keepCompare = compare && next.kind === current.kind ? compare : defaultComparison(next, today);
    setBoth(next, comparing && next.kind !== 'all' ? keepCompare : null);
    onClose();
  }

  const applyLabel = draft.kind === 'all' ? 'Show entire history' : draft.kind === 'custom' ? 'Show range' : `Show ${periodLabel(draft, today)}`;

  // Portalled so it stacks above the sticky header and the bottom navigation.
  return createPortal(
    <>
      <div className={styles.backdrop} onClick={onClose} aria-hidden="true" />
      <div ref={sheetRef} role="dialog" aria-modal="true" aria-labelledby={titleId} className={styles.sheet} onKeyDown={onKeyDown}>
        <div className={styles.handle} aria-hidden="true" />
        <div className={styles.head}>
          <h2 id={titleId} className={styles.title}>Period</h2>
          <button type="button" className={styles.reset} onClick={() => pickKind('all')}>Reset to all time</button>
        </div>

        <div role="radiogroup" aria-label="Period type" className={styles.modes}>
          {MODES.map((m) => (
            <button key={m.kind} type="button" role="radio" aria-checked={draft.kind === m.kind} className={styles.mode} onClick={() => pickKind(m.kind)}>
              <span>{m.label}</span>
              <span className={styles.radio} aria-hidden="true" />
            </button>
          ))}
        </div>

        {draft.kind === 'year' && (
          <>
            <div className={`eyebrow ${styles.groupLabel}`} id={`${titleId}-year`}>Year</div>
            <div className={styles.grid5} role="group" aria-labelledby={`${titleId}-year`}>
              {Array.from({ length: thisYear - FIRST_POSSIBLE_YEAR + 1 }, (_, i) => thisYear - i).map((y) => (
                <button key={y} type="button" className={styles.cell} aria-pressed={draft.year === y} onClick={() => setDraft({ kind: 'year', year: y })}>
                  {y}
                </button>
              ))}
            </div>
          </>
        )}

        {draft.kind === 'month' && (
          <>
            <div className={`eyebrow ${styles.groupLabel}`}>Month</div>
            <div className={styles.yearRow}>
              <button type="button" className={styles.step} aria-label="Previous year" disabled={draft.year <= FIRST_POSSIBLE_YEAR} onClick={() => setDraft({ ...draft, year: draft.year - 1 })}>
                <Icon name="chevron_left" />
              </button>
              <span aria-live="polite">{draft.year}</span>
              <button type="button" className={styles.step} aria-label="Next year" disabled={draft.year >= thisYear} onClick={() => setDraft({ ...draft, year: draft.year + 1, month: Math.min(draft.month, draft.year + 1 === thisYear ? Number(today.slice(5, 7)) : 12) })}>
                <Icon name="chevron_right" />
              </button>
            </div>
            <div className={styles.grid4} role="group" aria-label={`Months of ${draft.year}`}>
              {MONTH_NAMES.map((name, i) => {
                const future = draft.year === thisYear && i + 1 > Number(today.slice(5, 7));
                return (
                  <button key={name} type="button" className={styles.cell} aria-label={`${name} ${draft.year}`} aria-pressed={draft.month === i + 1} disabled={future} onClick={() => setDraft({ ...draft, month: i + 1 })}>
                    {name.slice(0, 3)}
                  </button>
                );
              })}
            </div>
          </>
        )}

        {draft.kind === 'l12' && <p className={styles.note}>Rolling window ending today: {periodLabel(draft, today)}.</p>}

        {draft.kind === 'custom' && (
          <>
            <label className={styles.field}>
              From
              <input type="date" value={range.from} max={today} aria-invalid={!!error} onChange={(e) => setRange({ ...range, from: e.target.value })} />
            </label>
            <label className={styles.field}>
              To, inclusive
              <input type="date" value={range.to} aria-invalid={!!error} onChange={(e) => setRange({ ...range, to: e.target.value })} />
            </label>
            {error && (
              <p className={styles.error} role="alert">
                <Icon name="error" size={16} />
                {error}
              </p>
            )}
          </>
        )}

        <div className={styles.compareRow}>
          <span className={styles.compareText} id={`${titleId}-cmp`}>
            <span>Compare with another period</span>
            <span>{draft.kind === 'all' ? 'Choose a year, month or range first' : 'Shows both side by side'}</span>
          </span>
          <button
            type="button"
            role="switch"
            aria-checked={comparing}
            aria-labelledby={`${titleId}-cmp`}
            disabled={draft.kind === 'all'}
            className={styles.switch}
            onClick={() => setComparing((c) => !c)}
          >
            <span />
          </button>
        </div>

        <button type="button" className={styles.apply} onClick={apply}>{applyLabel}</button>
      </div>
    </>,
    document.body,
  );
}

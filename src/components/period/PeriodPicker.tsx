import { useEffect, useRef, useState, type FormEvent } from 'react';
import { MONTH_NAMES, isIsoDate } from '../../lib/dates';
import { BAR_KINDS, periodLabel, periodOfKind, periodRange, type Period, type PeriodKind } from '../../lib/period';
import { Icon } from '../ui/Icon';
import styles from './PeriodPicker.module.css';

/** Last.fm began recording scrobbles in 2002; nothing earlier can exist. */
const FIRST_POSSIBLE_YEAR = 2002;

interface Props {
  id: string;
  label: string;
  value: Period;
  today: string;
  /** Show the period type list (used when the segmented control is hidden). */
  showKinds: boolean;
  onSelect(p: Period): void;
  onDone(): void;
}

export function PeriodPicker({ id, label, value, today, showKinds, onSelect, onDone }: Props) {
  const panelRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const first = panelRef.current?.querySelector<HTMLElement>('input:checked, [aria-pressed="true"], input, button');
    first?.focus();
  }, []);

  const choose = (p: Period) => {
    onSelect(p);
    onDone();
  };

  return (
    <div ref={panelRef} id={id} role="dialog" aria-label={label} className={styles.panel}>
      {showKinds && (
        <fieldset className={styles.kinds}>
          <legend className="sr-only">Period type</legend>
          {BAR_KINDS.map(({ kind, label: kindLabel }) => (
            <label key={kind} className={styles.kind}>
              <input
                type="radio"
                name={`${id}-kind`}
                checked={value.kind === kind}
                onChange={() => onSelect(periodOfKind(kind as PeriodKind, value, today))}
              />
              {kindLabel}
            </label>
          ))}
        </fieldset>
      )}
      <PickerBody value={value} today={today} onChoose={choose} />
    </div>
  );
}

function PickerBody({ value, today, onChoose }: { value: Period; today: string; onChoose(p: Period): void }) {
  const thisYear = Number(today.slice(0, 4));
  switch (value.kind) {
    case 'all':
      return <p className={styles.note}>Covers every scrobble from your first to your latest.</p>;
    case 'l12':
      return <p className={styles.note}>Rolling window ending today: {periodLabel(value, today)}.</p>;
    case 'year':
      return <YearGrid selected={value.year} thisYear={thisYear} onChoose={(year) => onChoose({ kind: 'year', year })} />;
    case 'month':
      return <MonthGrid value={value} today={today} onChoose={onChoose} />;
    case 'custom':
    case 'week':
    case 'day':
      return <CustomRange value={value} today={today} onChoose={onChoose} />;
  }
}

function YearGrid({ selected, thisYear, onChoose }: { selected: number; thisYear: number; onChoose(y: number): void }) {
  const years: number[] = [];
  for (let y = thisYear; y >= FIRST_POSSIBLE_YEAR; y--) years.push(y);
  return (
    <div className={styles.grid} role="group" aria-label="Year">
      {years.map((y) => (
        <button key={y} type="button" className={styles.cell} aria-pressed={y === selected} onClick={() => onChoose(y)}>
          {y}
        </button>
      ))}
    </div>
  );
}

function MonthGrid({ value, today, onChoose }: { value: Extract<Period, { kind: 'month' }>; today: string; onChoose(p: Period): void }) {
  const [year, setYear] = useState(value.year);
  const thisYear = Number(today.slice(0, 4));
  const thisMonth = Number(today.slice(5, 7));
  return (
    <div className={styles.form}>
      <div className={styles.yearRow}>
        <button type="button" className={styles.iconButton} aria-label="Previous year" disabled={year <= FIRST_POSSIBLE_YEAR} onClick={() => setYear(year - 1)}>
          <Icon name="chevron_left" />
        </button>
        <strong aria-live="polite">{year}</strong>
        <button type="button" className={styles.iconButton} aria-label="Next year" disabled={year >= thisYear} onClick={() => setYear(year + 1)}>
          <Icon name="chevron_right" />
        </button>
      </div>
      <div className={styles.grid} role="group" aria-label={`Months of ${year}`}>
        {MONTH_NAMES.map((name, i) => {
          const month = i + 1;
          const future = year > thisYear || (year === thisYear && month > thisMonth);
          return (
            <button
              key={name}
              type="button"
              className={styles.cell}
              aria-label={`${name} ${year}`}
              aria-pressed={value.year === year && value.month === month}
              disabled={future}
              onClick={() => onChoose({ kind: 'month', year, month })}
            >
              {name.slice(0, 3)}
            </button>
          );
        })}
      </div>
    </div>
  );
}

function CustomRange({ value, today, onChoose }: { value: Period; today: string; onChoose(p: Period): void }) {
  const initial = periodRange(value, today) ?? { from: today, to: today };
  const [from, setFrom] = useState(initial.from);
  const [to, setTo] = useState(initial.to);
  const [error, setError] = useState<string | null>(null);

  function submit(e: FormEvent) {
    e.preventDefault();
    if (!isIsoDate(from) || !isIsoDate(to)) return setError('Enter both dates as YYYY-MM-DD.');
    if (from > to) return setError('The start date must be on or before the end date.');
    if (from > today) return setError('The range must start on or before today.');
    setError(null);
    onChoose({ kind: 'custom', from, to });
  }

  return (
    <form className={styles.form} onSubmit={submit} noValidate>
      <label className={styles.field}>
        From
        <input type="date" value={from} max={today} onChange={(e) => setFrom(e.target.value)} aria-invalid={!!error} />
      </label>
      <label className={styles.field}>
        To, inclusive
        <input type="date" value={to} onChange={(e) => setTo(e.target.value)} aria-invalid={!!error} />
      </label>
      {error && (
        <p className={styles.error} role="alert">
          <Icon name="error" size={16} />
          {error}
        </p>
      )}
      <button type="submit" className={styles.primary}>Apply range</button>
    </form>
  );
}

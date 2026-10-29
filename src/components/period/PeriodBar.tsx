import { useCallback, useEffect, useId, useMemo, useRef, useState, type KeyboardEvent, type ReactNode } from 'react';
import { useMediaQuery } from '../../hooks/useMediaQuery';
import { useDismiss } from '../../hooks/useDismiss';
import {
  BAR_KINDS, canStep, defaultComparison, periodLabel, periodOfKind, stepPeriod, type Period, type PeriodKind,
} from '../../lib/period';
import { usePeriod } from '../../state/PeriodContext';
import { Icon } from '../ui/Icon';
import { SegmentedControl } from '../ui/SegmentedControl';
import { SearchField } from '../search/SearchField';
import { PeriodPicker } from './PeriodPicker';
import styles from './PeriodBar.module.css';

/** Sticky period toolbar shared by every screen, plus the global banner slot below it. */
export function PeriodBar({ banner }: { banner?: ReactNode }) {
  const { current, compare, today, setCurrent, setCompare } = usePeriod();
  const narrow = useMediaQuery('(max-width: 1023px)');
  const [pickerFor, setPickerFor] = useState<'current' | 'compare' | null>(null);

  const selectKind = (kind: PeriodKind) => {
    if (kind === current.kind) return;
    setCurrent(periodOfKind(kind, current, today));
    if (kind === 'custom') setPickerFor('current');
  };

  return (
    <div className={styles.bar}>
      <div role="toolbar" aria-label="Period" className={styles.toolbar}>
        <span className={`eyebrow ${styles.periodEyebrow}`}>Period</span>
        <SegmentedControl
          className={styles.segments}
          label="Period type"
          options={BAR_KINDS.map(({ kind, label }) => ({ value: kind, label }))}
          value={current.kind}
          onChange={selectKind}
        />
        <Stepper
          period={current}
          today={today}
          label={narrow ? 'Choose period and type' : 'Choose period'}
          showKinds={narrow}
          open={pickerFor === 'current'}
          onOpenChange={(o) => setPickerFor(o ? 'current' : null)}
          onChange={setCurrent}
        />
        <CompareControl
          current={current}
          compare={compare}
          today={today}
          open={pickerFor === 'compare'}
          onOpenChange={(o) => setPickerFor(o ? 'compare' : null)}
          onChange={setCompare}
        />
        <div className={styles.spacer} />
        <SearchField className={styles.search} />
      </div>
      {banner}
    </div>
  );
}

interface StepperProps {
  period: Period;
  today: string;
  label: string;
  showKinds: boolean;
  open: boolean;
  onOpenChange(open: boolean): void;
  onChange(p: Period): void;
}

function Stepper({ period, today, label, showKinds, open, onOpenChange, onChange }: StepperProps) {
  const id = useId();
  const wrapRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const close = useCallback(() => {
    onOpenChange(false);
    triggerRef.current?.focus();
  }, [onOpenChange]);
  const refs = useMemo(() => [wrapRef], []);
  useDismiss(open, close, refs);

  const isAll = period.kind === 'all';
  return (
    <div ref={wrapRef} className={styles.stepper}>
      <button
        type="button"
        className={styles.step}
        aria-label="Previous period"
        title={isAll ? 'All time has no previous period' : undefined}
        disabled={!canStep(period, -1, today)}
        onClick={() => onChange(stepPeriod(period, -1, today))}
      >
        <Icon name="chevron_left" />
      </button>
      <button
        ref={triggerRef}
        type="button"
        className={styles.value}
        aria-label={`${label}. Current: ${periodLabel(period, today)}`}
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-controls={open ? id : undefined}
        onClick={() => onOpenChange(!open)}
      >
        <span>{periodLabel(period, today)}</span>
        <Icon name="expand_more" />
      </button>
      <button
        type="button"
        className={styles.step}
        aria-label="Next period"
        title={isAll ? 'All time has no next period' : undefined}
        disabled={!canStep(period, 1, today)}
        onClick={() => onChange(stepPeriod(period, 1, today))}
      >
        <Icon name="chevron_right" />
      </button>
      {open && (
        <PeriodPicker id={id} label={label} value={period} today={today} showKinds={showKinds} onSelect={onChange} onDone={close} />
      )}
    </div>
  );
}

interface CompareProps {
  current: Period;
  compare: Period | null;
  today: string;
  open: boolean;
  onOpenChange(open: boolean): void;
  onChange(p: Period | null): void;
}

function CompareControl({ current, compare, today, open, onOpenChange, onChange }: CompareProps) {
  const id = useId();
  const wrapRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const compareButtonRef = useRef<HTMLButtonElement>(null);
  const close = useCallback(() => {
    onOpenChange(false);
    triggerRef.current?.focus();
  }, [onOpenChange]);
  const refs = useMemo(() => [wrapRef], []);
  useDismiss(open, close, refs);

  // After clearing from the chip, keep keyboard focus on the control that replaces it.
  const refocusAfterClear = useRef(false);
  useEffect(() => {
    if (!compare && refocusAfterClear.current) {
      refocusAfterClear.current = false;
      compareButtonRef.current?.focus();
    }
  }, [compare]);

  if (!compare) {
    const unavailable = current.kind === 'all';
    return (
      <button
        ref={compareButtonRef}
        type="button"
        className={styles.compareButton}
        aria-pressed="false"
        disabled={unavailable}
        title={unavailable ? 'Choose a year, month or range to compare' : 'Compare with the previous period'}
        onClick={() => onChange(defaultComparison(current, today))}
      >
        <Icon name="compare_arrows" />
        <span>Compare</span>
      </button>
    );
  }

  const clear = () => {
    refocusAfterClear.current = true;
    onChange(null);
  };
  const onChipKey = (e: KeyboardEvent) => {
    if (e.key === 'Escape' && !open) {
      e.preventDefault();
      clear();
    }
  };

  return (
    <div ref={wrapRef} className={styles.chip} onKeyDown={onChipKey}>
      <span className={styles.vs} aria-hidden="true">vs</span>
      <button
        ref={triggerRef}
        type="button"
        className={styles.chipValue}
        aria-label={`Comparison period: ${periodLabel(compare, today)}. Change`}
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-controls={open ? id : undefined}
        onClick={() => onOpenChange(!open)}
      >
        <span className={styles.swatch} />
        <span>{periodLabel(compare, today)}</span>
      </button>
      <button type="button" className={styles.clear} aria-label="Clear comparison" onClick={clear}>
        <Icon name="close" size={16} />
      </button>
      {open && (
        <PeriodPicker id={id} label="Choose comparison period" value={compare} today={today} showKinds={false} onSelect={onChange} onDone={close} />
      )}
    </div>
  );
}

/** Banner row under the toolbar (specimen notice, import progress, failures). */
export function BarBanner({ tag, children }: { tag: string; children: ReactNode }) {
  return (
    <div className={styles.banner} role="status">
      <span className={styles.bannerTag}>{tag}</span>
      <span>{children}</span>
    </div>
  );
}

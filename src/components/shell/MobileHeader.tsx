import { useRef, useState, type ReactNode } from 'react';
import { Link, useLocation } from 'react-router-dom';
import { NAV_ITEMS } from '../../app/navigation';
import { defaultComparison, periodLabel, periodShortLabel } from '../../lib/period';
import { usePeriod } from '../../state/PeriodContext';
import { PeriodSheet } from '../period/PeriodSheet';
import { SearchField } from '../search/SearchField';
import { Icon } from '../ui/Icon';
import { AccountMenu } from './AccountMenu';
import { BrandMark } from './BrandMark';
import styles from './MobileHeader.module.css';

/** Below 768px: brand and page title, search, and a single period button that opens a sheet. */
export function MobileHeader({ banner }: { banner?: ReactNode }) {
  const { pathname } = useLocation();
  const { current, compare, today, setCompare } = usePeriod();
  const [searchOpen, setSearchOpen] = useState(false);
  const [sheetOpen, setSheetOpen] = useState(false);
  const periodRef = useRef<HTMLButtonElement>(null);
  const title = NAV_ITEMS.find((i) => pathname.startsWith(i.path))?.label ?? 'Runout';
  const value = compare ? `${periodShortLabel(current, today)} vs ${periodShortLabel(compare, today)}` : periodLabel(current, today);

  return (
    <div className={styles.header}>
      <div className={styles.titleRow}>
        <Link to="/" className={styles.brand} aria-label={`Runout, ${title}`}>
          <BrandMark size={22} />
          <span className={styles.title} aria-hidden="true">{title}</span>
        </Link>
        <div className={styles.actions}>
          <button
            type="button"
            className={styles.iconButton}
            aria-label={searchOpen ? 'Close search' : 'Search'}
            aria-expanded={searchOpen}
            onClick={() => setSearchOpen((o) => !o)}
          >
            <Icon name={searchOpen ? 'close' : 'search'} size={22} />
          </button>
          <AccountMenu />
        </div>
      </div>
      {searchOpen && (
        <div className={styles.searchRow}>
          <SearchField autoFocus />
        </div>
      )}
      <div className={styles.controls}>
        <button
          ref={periodRef}
          type="button"
          className={styles.period}
          aria-haspopup="dialog"
          aria-expanded={sheetOpen}
          aria-label={`Period: ${value}. Change`}
          onClick={() => setSheetOpen(true)}
        >
          <span className={styles.periodText}>
            <span className={styles.periodLabel}>Period</span>
            <span>{value}</span>
          </span>
          <span style={{ color: 'var(--mu)', display: 'flex' }}><Icon name="expand_more" size={20} /></span>
        </button>
        <button
          type="button"
          className={styles.compare}
          aria-label="Compare with the previous period"
          aria-pressed={!!compare}
          disabled={current.kind === 'all'}
          title={current.kind === 'all' ? 'Choose a year, month or range to compare' : undefined}
          onClick={() => setCompare(compare ? null : defaultComparison(current, today))}
        >
          <Icon name="compare_arrows" size={20} />
        </button>
      </div>
      {banner}
      {sheetOpen && (
        <PeriodSheet
          onClose={() => {
            setSheetOpen(false);
            periodRef.current?.focus();
          }}
        />
      )}
    </div>
  );
}

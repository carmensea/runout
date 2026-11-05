import { useCallback, useMemo, useRef, useState, type KeyboardEvent } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useAppData } from '../../data/AppDataContext';
import { useDismiss } from '../../hooks/useDismiss';
import { usePeriod } from '../../state/PeriodContext';
import { THEMES } from '../../theme/theme';
import { useTheme } from '../../theme/useTheme';
import { Icon } from '../ui/Icon';
import styles from './AccountMenu.module.css';

/** Top right, signed in: the account's initial opens a menu with the theme choice, Settings and Sign out. */
export function AccountMenu() {
  const { api, connection, auth } = useAppData();
  const navigate = useNavigate();
  const { withPeriod } = usePeriod();
  const [theme, chooseTheme] = useTheme();
  const [open, setOpen] = useState(false);
  const [failed, setFailed] = useState(false);
  const wrapRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const close = useCallback(() => {
    setOpen(false);
    triggerRef.current?.focus();
  }, []);
  const refs = useMemo(() => [wrapRef], []);
  useDismiss(open, close, refs);

  if (connection.status !== 'success' || connection.data.status === 'none') return null;
  const { username } = connection.data;

  async function signOut() {
    try {
      await api.signOut();
      setOpen(false);
      connection.retry();
      auth.retry();
      navigate('/overview');
    } catch {
      setFailed(true);
    }
  }

  // Arrow keys move between items, as a menu expects; Escape is handled by useDismiss.
  function onMenuKey(e: KeyboardEvent<HTMLDivElement>) {
    const delta = e.key === 'ArrowDown' ? 1 : e.key === 'ArrowUp' ? -1 : 0;
    if (!delta) return;
    e.preventDefault();
    const items = Array.from(e.currentTarget.querySelectorAll<HTMLElement>('[role^="menuitem"]'));
    const i = items.indexOf(document.activeElement as HTMLElement);
    items[(i + delta + items.length) % items.length]?.focus();
  }

  return (
    <div ref={wrapRef} className={styles.wrap}>
      <button
        ref={triggerRef}
        type="button"
        className={styles.trigger}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label={`Account, ${username}`}
        onClick={() => setOpen((o) => !o)}
      >
        <span className={styles.avatar} aria-hidden="true">{username.charAt(0).toUpperCase()}</span>
        <Icon name="expand_more" size={18} className={styles.chevron} />
      </button>
      {open && (
        <div role="menu" aria-label="Account" className={styles.menu} onKeyDown={onMenuKey}>
          <div className={styles.who}>
            <span className={styles.username}>{username}</span>
            <span className={styles.status}>Last.fm connected</span>
          </div>
          <div className={styles.label} id="account-menu-theme">Theme</div>
          {THEMES.map((t) => (
            <button
              key={t.id}
              type="button"
              role="menuitemradio"
              aria-checked={theme === t.id}
              className={styles.item}
              onClick={() => chooseTheme(t.id)}
            >
              <span className={styles.swatch} data-theme={t.id} aria-hidden="true" />
              <span className={styles.itemText}>{t.name}</span>
              {theme === t.id && <Icon name="check" size={16} />}
            </button>
          ))}
          <div className={styles.rule} role="separator" />
          <Link role="menuitem" to={withPeriod('/settings')} className={styles.item} onClick={() => setOpen(false)}>
            <Icon name="settings" size={16} />
            <span className={styles.itemText}>Settings</span>
          </Link>
          <button type="button" role="menuitem" className={styles.item} onClick={signOut}>
            <Icon name="logout" size={16} />
            <span className={styles.itemText}>Sign out</span>
          </button>
          {failed && <p role="alert" className={styles.error}>Sign-out failed. Try again.</p>}
        </div>
      )}
    </div>
  );
}

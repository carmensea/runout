import { THEMES, type ThemeId } from '../../theme/theme';
import { useTheme } from '../../theme/useTheme';
import styles from './Appearance.module.css';

/**
 * Settings → Appearance: pick one of the four themes. Each tile is rendered from the theme's own
 * tokens (data-theme scopes the custom properties), so the preview is the real palette.
 * Temporary home until Settings gets its Appearance tab.
 */
export function AppearancePanel() {
  const [theme, setTheme] = useTheme();
  return (
    <div className={styles.grid} role="radiogroup" aria-label="Theme">
      {THEMES.map((t) => (
        <button
          key={t.id}
          type="button"
          role="radio"
          aria-checked={theme === t.id}
          className={`${styles.tile} ${theme === t.id ? styles.selected : ''}`}
          data-theme={t.id}
          onClick={() => setTheme(t.id as ThemeId)}
        >
          <span className={styles.preview} aria-hidden="true">
            <span className={styles.previewBar}><i /><i /></span>
            <span className={styles.previewText}>Aa</span>
            <span className={styles.previewAccent} />
            <span className={styles.previewChips}><i /><i /><i /><i /><i /></span>
          </span>
          <span className={styles.name}>{t.name}</span>
          <span className={styles.description}>{t.description}</span>
        </button>
      ))}
    </div>
  );
}

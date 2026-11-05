/**
 * The selectable themes (src/styles/tokens.css). The choice lives in localStorage and as
 * `data-theme` on <html>; index.html applies it before the first paint so nothing flashes.
 */
export const THEMES = [
  { id: 'original', name: 'Original', description: 'Charcoal and burnt orange.' },
  { id: 'moss', name: 'Moss', description: 'Dark botanical green and sage.' },
  { id: 'cotton-candy', name: 'Cotton Candy', description: 'The Idle Winny sky, in motion.' },
  { id: 'midnight-candy', name: 'Midnight Candy', description: 'The same sky at night.' },
] as const;

export type ThemeId = (typeof THEMES)[number]['id'];

export const DEFAULT_THEME: ThemeId = 'original';
export const STORAGE_KEY = 'runout:theme';

/** The browser chrome colour per theme (the theme-color meta). */
export const THEME_COLORS: Record<ThemeId, string> = {
  original: '#17191A',
  moss: '#141d18',
  'cotton-candy': '#7b68ee',
  'midnight-candy': '#171331',
};

export function isThemeId(value: unknown): value is ThemeId {
  return THEMES.some((t) => t.id === value);
}

/** The stored choice, or the default for nothing, an unknown value or blocked storage. */
export function readStoredTheme(): ThemeId {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    return isThemeId(raw) ? raw : DEFAULT_THEME;
  } catch {
    return DEFAULT_THEME;
  }
}

export function currentTheme(): ThemeId {
  const attr = document.documentElement.dataset.theme;
  return isThemeId(attr) ? attr : DEFAULT_THEME;
}

const listeners = new Set<() => void>();

/** Applies a theme now (the attribute, the meta colour) and remembers it. */
export function setTheme(id: ThemeId): void {
  const root = document.documentElement;
  if (id === DEFAULT_THEME) delete root.dataset.theme;
  else root.dataset.theme = id;
  document.querySelector('meta[name="theme-color"]')?.setAttribute('content', THEME_COLORS[id]);
  try {
    localStorage.setItem(STORAGE_KEY, id);
  } catch {
    // Private windows and blocked storage: the choice lasts for this page only.
  }
  listeners.forEach((l) => l());
}

export function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

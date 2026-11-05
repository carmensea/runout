import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { DEFAULT_THEME, STORAGE_KEY, THEMES, currentTheme, isThemeId, readStoredTheme, setTheme } from './theme';

beforeEach(() => {
  localStorage.clear();
  delete document.documentElement.dataset.theme;
  document.head.innerHTML = '<meta name="theme-color" content="#17191A">';
});
afterEach(() => {
  delete document.documentElement.dataset.theme;
});

describe('theme store', () => {
  it('defaults to Original with nothing stored', () => {
    expect(readStoredTheme()).toBe('original');
    expect(currentTheme()).toBe(DEFAULT_THEME);
  });

  it('offers exactly the four themes', () => {
    expect(THEMES.map((t) => t.id)).toEqual(['original', 'moss', 'cotton-candy', 'midnight-candy']);
    expect(isThemeId('moss')).toBe(true);
    expect(isThemeId('solarized')).toBe(false);
  });

  it('applies a theme immediately, remembers it, and updates the browser colour', () => {
    setTheme('moss');
    expect(document.documentElement.dataset.theme).toBe('moss');
    expect(localStorage.getItem(STORAGE_KEY)).toBe('moss');
    expect(document.querySelector('meta[name="theme-color"]')?.getAttribute('content')).toBe('#141d18');
    expect(currentTheme()).toBe('moss');
  });

  it('survives a refresh through storage', () => {
    localStorage.setItem(STORAGE_KEY, 'midnight-candy');
    expect(readStoredTheme()).toBe('midnight-candy');
  });

  it('falls back to Original for an unknown or outdated stored value', () => {
    localStorage.setItem(STORAGE_KEY, 'cotton-candy-v1');
    expect(readStoredTheme()).toBe('original');
    document.documentElement.dataset.theme = 'nonsense';
    expect(currentTheme()).toBe('original');
  });

  it('returning to Original removes the attribute so the root tokens apply', () => {
    setTheme('cotton-candy');
    setTheme('original');
    expect(document.documentElement.dataset.theme).toBeUndefined();
    expect(localStorage.getItem(STORAGE_KEY)).toBe('original');
  });
});

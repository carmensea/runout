import { useSyncExternalStore } from 'react';
import { currentTheme, setTheme, subscribe, type ThemeId } from './theme';

/** The active theme and a setter; every subscriber re-renders when it changes. */
export function useTheme(): [ThemeId, (id: ThemeId) => void] {
  const theme = useSyncExternalStore(subscribe, currentTheme, () => 'original' as ThemeId);
  return [theme, setTheme];
}

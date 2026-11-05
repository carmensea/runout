import { useCallback, useEffect, useSyncExternalStore } from 'react';
import { useAppData } from '../data/AppDataContext';
import { currentTheme, DEFAULT_THEME, isThemeId, setTheme, subscribe, type ThemeId } from './theme';

/**
 * The active theme and a setter; every subscriber re-renders when it changes. Signed in, a choice
 * is also saved on the account; the browser keeps it either way, so a failed save changes nothing
 * visible.
 */
export function useTheme(): [ThemeId, (id: ThemeId) => void] {
  const { api, connection } = useAppData();
  const theme = useSyncExternalStore(subscribe, currentTheme, () => 'original' as ThemeId);
  const signedIn = connection.status === 'success' && connection.data.status !== 'signed_out';
  const choose = useCallback((id: ThemeId) => {
    setTheme(id);
    if (signedIn) api.setTheme(id).catch(() => {});
  }, [api, signedIn]);
  return [theme, choose];
}

/**
 * Applies the account's theme once the connection has loaded, so it follows the owner between
 * browsers. An account with no theme yet adopts this browser's choice, so a theme picked before
 * the account kept one doesn't have to be picked again.
 */
export function useAccountTheme(): void {
  const { api, connection } = useAppData();
  const account = connection.status === 'success' && connection.data.status !== 'signed_out' ? connection.data.theme : undefined;
  useEffect(() => {
    if (isThemeId(account) && account !== currentTheme()) setTheme(account);
    else if (account === null && currentTheme() !== DEFAULT_THEME) api.setTheme(currentTheme()).catch(() => {});
  }, [account, api]);
}

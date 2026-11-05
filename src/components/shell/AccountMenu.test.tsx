import { screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { connectedApi, notConnectedApi } from '../../test/fixtures';
import { location, renderApp } from '../../test/renderApp';

beforeEach(() => {
  localStorage.clear();
  delete document.documentElement.dataset.theme;
});
afterEach(() => {
  delete document.documentElement.dataset.theme;
});

describe('Account menu', () => {
  it('is absent when signed out', async () => {
    renderApp(notConnectedApi, '/overview?period=all');
    await screen.findByRole('main');
    expect(screen.queryByRole('button', { name: /^Account,/ })).not.toBeInTheDocument();
  });

  it('changes the theme at once and saves it on the account', async () => {
    const user = userEvent.setup();
    const setTheme = vi.fn(async () => {});
    renderApp({ ...connectedApi(), setTheme }, '/overview?period=all');
    await user.click(await screen.findByRole('button', { name: 'Account, test-user' }));
    const menu = screen.getByRole('menu', { name: 'Account' });
    expect(within(menu).getByRole('menuitemradio', { name: 'Original' })).toHaveAttribute('aria-checked', 'true');
    await user.click(within(menu).getByRole('menuitemradio', { name: 'Moss' }));
    expect(document.documentElement.dataset.theme).toBe('moss');
    expect(localStorage.getItem('runout:theme')).toBe('moss');
    expect(setTheme).toHaveBeenCalledWith('moss');
  });

  it('applies the account’s theme when the connection loads', async () => {
    localStorage.setItem('runout:theme', 'moss');
    document.documentElement.dataset.theme = 'moss';
    const api = { ...connectedApi(), getConnection: async () => ({ status: 'connected' as const, displayName: 'test-user', username: 'test-user', timezone: 'Europe/London', theme: 'verdant' }) };
    renderApp(api, '/overview?period=all');
    await waitFor(() => expect(document.documentElement.dataset.theme).toBe('verdant'));
  });

  it('saves this browser’s theme on an account that has none yet', async () => {
    localStorage.setItem('runout:theme', 'cotton-candy');
    document.documentElement.dataset.theme = 'cotton-candy';
    const setTheme = vi.fn(async () => {});
    const api = { ...connectedApi(), setTheme, getConnection: async () => ({ status: 'connected' as const, displayName: 'test-user', username: 'test-user', timezone: 'Europe/London', theme: null }) };
    renderApp(api, '/overview?period=all');
    await waitFor(() => expect(setTheme).toHaveBeenCalledWith('cotton-candy'));
    expect(setTheme).toHaveBeenCalledTimes(1);
    expect(document.documentElement.dataset.theme).toBe('cotton-candy');
  });

  it('signs out and lands on the signed-out Overview', async () => {
    const user = userEvent.setup();
    let signedIn = true;
    const base = connectedApi();
    const api = {
      ...base,
      getConnection: async () => (signedIn ? base.getConnection() : { status: 'signed_out' as const }),
      signOut: async () => {
        signedIn = false;
      },
    };
    renderApp(api, '/settings#account');
    await user.click(await screen.findByRole('button', { name: 'Account, test-user' }));
    await user.click(screen.getByRole('menuitem', { name: 'Sign out' }));
    await waitFor(() => expect(location.current).toBe('/overview'));
    await waitFor(() => expect(screen.queryByRole('button', { name: /^Account,/ })).not.toBeInTheDocument());
  });
});

import { screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { RunoutApi } from '../../data/api';
import { connectedApi, fakeAuthApi, makeSession } from '../../test/fixtures';
import { location, renderApp } from '../../test/renderApp';

function supportPasskeys() {
  Object.defineProperty(globalThis, 'PublicKeyCredential', {
    configurable: true,
    value: { parseCreationOptionsFromJSON: () => ({}), parseRequestOptionsFromJSON: () => ({}) },
  });
}

/** An invited account: signed in, no passkey, no codes, no Last.fm, nothing stored. */
function invitedApi(): RunoutApi & { auth: ReturnType<typeof fakeAuthApi> } {
  const auth = fakeAuthApi({ session: makeSession({ user: { displayName: 'Dana', timezone: 'America/Los_Angeles' }, methods: { passkeys: 0, recoveryCodes: 0, lastfm: false } }), passkeys: [] });
  return { ...connectedApi(), getConnection: async () => ({ status: 'none', displayName: 'Dana', timezone: 'America/Los_Angeles' }), auth };
}

beforeEach(() => {
  localStorage.clear();
  supportPasskeys();
});
afterEach(() => {
  delete (globalThis as { PublicKeyCredential?: unknown }).PublicKeyCredential;
});

describe('Onboarding', () => {
  it('sends an invited account without a passkey to /welcome from any page', async () => {
    renderApp(invitedApi(), '/overview?period=all');
    expect(await screen.findByRole('heading', { name: 'Welcome to Runout, Dana.' }, { timeout: 5000 })).toBeInTheDocument();
    await waitFor(() => expect(location.current).toMatch(/^\/welcome/));
  });

  it('walks through passkey, recovery codes and a source, then opens the Overview', async () => {
    const user = userEvent.setup();
    const api = invitedApi();
    renderApp(api, '/welcome');
    await screen.findByRole('heading', { name: 'Welcome to Runout, Dana.' });
    const steps = screen.getByRole('list', { name: 'Steps' });
    expect(within(steps).getByText('Add a passkey').closest('li')).toHaveAttribute('aria-current', 'step');

    await user.type(screen.getByRole('textbox', { name: /A name for this passkey/ }), 'Phone');
    await user.click(screen.getByRole('button', { name: 'Add a passkey' }));
    expect(api.auth.calls).toContain('addPasskey:Phone');
    const codes = await screen.findByRole('list', { name: 'Your recovery codes' });
    expect(within(codes).getAllByRole('listitem')).toHaveLength(10);
    expect(within(steps).getByText('Save your recovery codes').closest('li')).toHaveAttribute('aria-current', 'step');

    await user.click(screen.getByRole('button', { name: 'I’ve saved them' }));
    expect(screen.getByRole('link', { name: 'Connect Spotify' })).toHaveAttribute('href', '/api/auth/spotify');
    const disclosure = screen.getByRole('list', { name: 'What to know in this beta' });
    expect(disclosure).toHaveTextContent('sometimes misses one');
    expect(disclosure).toHaveTextContent('can read the database');
    expect(disclosure).toHaveTextContent('daily ones are kept for 30 days, monthly ones for 12 months');
    expect(disclosure).toHaveTextContent('delete your account at any time in Settings');
    await user.click(screen.getByRole('button', { name: 'Skip for now' }));
    await waitFor(() => expect(location.current).toMatch(/^\/overview/));
  });

  it('leaves the owner alone: Last.fm accounts are never sent to /welcome', async () => {
    renderApp(connectedApi(), '/overview?period=all');
    expect(await screen.findByText('4,321')).toBeInTheDocument();
    expect(location.current).toMatch(/^\/overview/);
  });
});

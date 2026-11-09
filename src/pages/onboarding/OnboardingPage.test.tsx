import { screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { RunoutApi } from '../../data/api';
import { connectedApi, fakeAuthApi, fakeSourcesApi, makeSession } from '../../test/fixtures';
import { location, renderApp } from '../../test/renderApp';

function supportPasskeys() {
  Object.defineProperty(globalThis, 'PublicKeyCredential', {
    configurable: true,
    value: { parseCreationOptionsFromJSON: () => ({}), parseRequestOptionsFromJSON: () => ({}) },
  });
}

/** An invited account: signed in, no passkey, no codes, no Last.fm, nothing stored. */
function invitedApi(): RunoutApi & { auth: ReturnType<typeof fakeAuthApi> } {
  const auth = fakeAuthApi({ session: makeSession({ user: { displayName: 'Dana', timezone: 'America/Los_Angeles' }, methods: { passkeys: 0, recoveryCodes: 0, lastfm: false, google: false } }), passkeys: [] });
  return { ...connectedApi(), getConnection: async () => ({ status: 'none', displayName: 'Dana', timezone: 'America/Los_Angeles', features: [] }), auth };
}

beforeEach(() => {
  localStorage.clear();
  supportPasskeys();
});
afterEach(() => {
  delete (globalThis as { PublicKeyCredential?: unknown }).PublicKeyCredential;
});

/** The same invited account on a server that offers Google; `linked` once they chose it. */
function invitedWithGoogle(linked = false): RunoutApi & { auth: ReturnType<typeof fakeAuthApi> } {
  const methods = { passkeys: 0, recoveryCodes: 0, lastfm: false, google: linked, googleEmail: linked ? 'dana@example.com' : null };
  const session = { signedIn: true as const, user: { displayName: 'Dana', timezone: 'America/Los_Angeles' }, methods, providers: { google: true } };
  return { ...invitedApi(), auth: fakeAuthApi({ session, passkeys: [] }) };
}

describe('Onboarding with Google', () => {
  it('offers Google first and a passkey as the other choice', async () => {
    renderApp(invitedWithGoogle(), '/welcome');
    await screen.findByRole('heading', { name: 'Welcome to Runout, Dana.' });
    const steps = screen.getByRole('list', { name: 'Steps' });
    expect(within(steps).getByText('Choose how you sign in').closest('li')).toHaveAttribute('aria-current', 'step');
    expect(screen.getByRole('link', { name: 'Continue with Google' })).toHaveAttribute('href', '/api/auth/google?intent=link&return=welcome');
    expect(screen.getByText(/nothing in your Google account is read/)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Add a passkey' })).toBeEnabled();
    expect(screen.getByText('Or add a passkey')).toBeInTheDocument();
  });

  it('after Google is linked goes straight to the source step, with no recovery codes to save', async () => {
    const user = userEvent.setup();
    renderApp(invitedWithGoogle(true), '/welcome?google=linked');
    await screen.findByRole('heading', { name: 'Welcome to Runout, Dana.' });
    const steps = screen.getByRole('list', { name: 'Steps' });
    expect(within(steps).getAllByRole('listitem').map((li) => li.textContent)).toEqual(['✓Choose how you sign in', '2Connect a music source']);
    expect(screen.queryByText('Save your recovery codes')).toBeNull();
    expect(screen.getByRole('link', { name: 'Connect Spotify' })).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Skip for now' }));
    await waitFor(() => expect(location.current).toMatch(/^\/overview/));
    // Complete: no page sends them back to /welcome.
    expect(location.current).not.toMatch(/welcome/);
  });

  it('still walks the passkey path with its recovery codes when that is the choice', async () => {
    const user = userEvent.setup();
    const api = invitedWithGoogle();
    renderApp(api, '/welcome');
    await user.type(await screen.findByRole('textbox', { name: /A name for this passkey/ }), 'Phone');
    await user.click(screen.getByRole('button', { name: 'Add a passkey' }));
    expect(within(await screen.findByRole('list', { name: 'Your recovery codes' })).getAllByRole('listitem')).toHaveLength(10);
    expect(within(screen.getByRole('list', { name: 'Steps' })).getByText('Save your recovery codes').closest('li')).toHaveAttribute('aria-current', 'step');
  });

  it('says why a Google account could not be linked', async () => {
    renderApp(invitedWithGoogle(), '/welcome?google_error=unavailable');
    expect(await screen.findByRole('alert')).toHaveTextContent('can’t be linked to this Runout account');
  });
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
    expect(await screen.findByLabelText('ListenBrainz user token')).toHaveAttribute('type', 'password');
    expect(screen.getByText(/Nothing here needs Last.fm or Spotify/)).toBeInTheDocument();
    const disclosure = screen.getByRole('list', { name: 'What to know in this beta' });
    expect(disclosure).toHaveTextContent('sometimes misses one');
    expect(disclosure).toHaveTextContent('can read the database');
    expect(disclosure).toHaveTextContent('daily ones are kept for 30 days, monthly ones for 12 months');
    expect(disclosure).toHaveTextContent('delete your account at any time in Settings');
    await user.click(screen.getByRole('button', { name: 'Skip for now' }));
    await waitFor(() => expect(location.current).toMatch(/^\/overview/));
  });

  it('connects ListenBrainz on the welcome page with a token, for someone with no Spotify and no plays', async () => {
    const user = userEvent.setup();
    const api = invitedApi();
    api.auth = fakeAuthApi({ session: makeSession({ user: { displayName: 'Dana', timezone: 'America/Los_Angeles' }, methods: { passkeys: 1, recoveryCodes: 10, lastfm: false, google: false } }), passkeys: [] });
    const sources = fakeSourcesApi();
    renderApp({ ...api, sources }, '/welcome');
    await screen.findByRole('heading', { name: 'Welcome to Runout, Dana.' });
    const disclosure = await screen.findByRole('list', { name: 'What to know in this beta' });
    expect(disclosure).toHaveTextContent('ListenBrainz listening history is public');
    await user.type(await screen.findByLabelText('ListenBrainz user token'), 'lb-token');
    await user.click(screen.getByRole('button', { name: 'Connect ListenBrainz' }));
    expect(sources.calls).toContain('connectListenbrainz:lb-token');
    expect(await screen.findByRole('status')).toHaveTextContent('ListenBrainz is connected as dana_lb');
    expect(screen.queryByLabelText('ListenBrainz user token')).not.toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Open your Overview' }));
    await waitFor(() => expect(location.current).toMatch(/^\/overview/));
  });

  it('leaves the owner alone: Last.fm accounts are never sent to /welcome', async () => {
    renderApp(connectedApi(), '/overview?period=all');
    expect(await screen.findByText('4,321')).toBeInTheDocument();
    expect(location.current).toMatch(/^\/overview/);
  });
});

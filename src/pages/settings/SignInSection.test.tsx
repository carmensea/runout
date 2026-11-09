import { screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { ApiError, type RunoutApi } from '../../data/api';
import type { ConnectionState } from '../../data/types';
import { connectedApi, fakeAuthApi, makePasskey } from '../../test/fixtures';
import { location, renderApp } from '../../test/renderApp';

function supportPasskeys() {
  Object.defineProperty(globalThis, 'PublicKeyCredential', {
    configurable: true,
    value: { parseCreationOptionsFromJSON: () => ({}), parseRequestOptionsFromJSON: () => ({}) },
  });
}

const api = (auth: ReturnType<typeof fakeAuthApi>): RunoutApi => ({ ...connectedApi(), auth });

beforeEach(() => {
  localStorage.clear();
  supportPasskeys();
});
afterEach(() => {
  delete (globalThis as { PublicKeyCredential?: unknown }).PublicKeyCredential;
});

/** An account on a server that offers Google. */
function withGoogle(methods: Partial<{ passkeys: number; google: boolean; googleEmail: string | null }> = {}, passkeys = [makePasskey(1)]) {
  const all = { passkeys: passkeys.length, recoveryCodes: 10, lastfm: false, google: false, googleEmail: null, ...methods };
  return fakeAuthApi({ session: { signedIn: true, user: { displayName: 'Dana', timezone: 'Europe/London' }, methods: all, providers: { google: true } }, passkeys });
}

describe('Settings: Google sign-in', () => {
  it('is absent when the server offers no Google', async () => {
    renderApp(api(fakeAuthApi()), '/settings#account');
    await screen.findByRole('list', { name: 'Your passkeys' });
    expect(screen.queryByRole('link', { name: 'Link Google' })).toBeNull();
  });

  it('links Google from an account that has a passkey', async () => {
    renderApp(api(withGoogle()), '/settings#account');
    expect(await screen.findByRole('link', { name: 'Link Google' })).toHaveAttribute('href', '/api/auth/google?intent=link&return=settings');
    expect(screen.getByText('Not linked.')).toBeInTheDocument();
    expect(await screen.findByRole('list', { name: 'Your passkeys' })).toHaveTextContent('Device 1');
  });

  it('shows the linked account and unlinks it', async () => {
    const user = userEvent.setup();
    const auth = withGoogle({ google: true, googleEmail: 'dana@example.com' });
    renderApp(api(auth), '/settings?google=linked#account');
    expect(await screen.findByText(/Linked to dana@example.com/)).toHaveTextContent('You can sign in with Google from now on.');
    await user.click(screen.getByRole('button', { name: 'Unlink Google' }));
    await waitFor(() => expect(auth.calls).toEqual(['unlinkGoogle']));
    expect(await screen.findByRole('link', { name: 'Link Google' })).toBeInTheDocument();
  });

  it('keeps Google when it is the only way in', async () => {
    const user = userEvent.setup();
    const auth = withGoogle({ google: true, googleEmail: 'dana@example.com' }, []);
    auth.unlinkGoogle = async () => { throw new ApiError(409, 'no', 'last_method'); };
    renderApp(api(auth), '/settings#account');
    await user.click(await screen.findByRole('button', { name: 'Unlink Google' }));
    expect(await screen.findByText(/only way in, so it stays linked/)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Unlink Google' })).toBeInTheDocument();
  });

  it('asks for a fresh sign-in before changing methods, and takes the passkey as proof', async () => {
    const user = userEvent.setup();
    const auth = withGoogle({ google: true, googleEmail: 'dana@example.com' });
    let fresh = false;
    const unlink = auth.unlinkGoogle;
    auth.unlinkGoogle = async () => { if (!fresh) throw new ApiError(403, 'no', 'confirm_first'); return unlink(); };
    const signIn = auth.signInWithPasskey;
    auth.signInWithPasskey = async () => { fresh = true; await signIn(); return { signedIn: true, user: { displayName: 'Dana', timezone: 'Europe/London' }, methods: { passkeys: 1, recoveryCodes: 10, lastfm: false, google: true, googleEmail: 'dana@example.com' }, providers: { google: true } }; };
    auth.status = async () => ({ signedIn: true, user: { displayName: 'Dana', timezone: 'Europe/London' }, methods: { passkeys: 1, recoveryCodes: 10, lastfm: false, google: !auth.calls.includes('unlinkGoogle'), googleEmail: 'dana@example.com' }, providers: { google: true } });
    renderApp(api(auth), '/settings#account');
    await user.click(await screen.findByRole('button', { name: 'Unlink Google' }));
    const group = await screen.findByRole('group', { name: 'Confirm it’s you' });
    expect(within(group).getByRole('link', { name: 'Confirm with Google' })).toHaveAttribute('href', '/api/auth/google?intent=sign_in&return=settings');
    await user.click(within(group).getByRole('button', { name: 'Confirm with a passkey' }));
    expect(await screen.findByText('Confirmed. Go ahead.')).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Unlink Google' }));
    await waitFor(() => expect(auth.calls).toContain('unlinkGoogle'));
    expect(await screen.findByRole('link', { name: 'Link Google' })).toBeInTheDocument();
  });

  it('shows what came back when a link was refused', async () => {
    renderApp(api(withGoogle()), '/settings?google_error=confirm_first#account');
    expect(await screen.findByRole('group', { name: 'Confirm it’s you' })).toBeInTheDocument();
    expect(screen.getAllByRole('alert').some((a) => /Confirm it’s you first/.test(a.textContent ?? ''))).toBe(true);
  });
});

describe('Settings: sign-in', () => {
  it('is absent while the server has Runout’s own sign-in switched off', async () => {
    renderApp(connectedApi(), '/settings#account');
    await screen.findByRole('heading', { name: 'Account' });
    expect(screen.queryByRole('heading', { name: 'Sign-in' })).not.toBeInTheDocument();
  });

  it('lists passkeys and adds one with the typed name', async () => {
    const user = userEvent.setup();
    const auth = fakeAuthApi();
    renderApp(api(auth), '/settings#account');
    const list = await screen.findByRole('list', { name: 'Your passkeys' });
    expect(within(list).getByText('Device 1')).toBeInTheDocument();
    expect(screen.getByText(/It works only on this address, localhost/)).toBeInTheDocument();
    await user.type(screen.getByRole('textbox', { name: /A name for this passkey/ }), 'Phone');
    await user.click(screen.getByRole('button', { name: 'Add a passkey' }));
    await waitFor(() => expect(auth.calls).toEqual(['addPasskey:Phone']));
    expect(await within(await screen.findByRole('list', { name: 'Your passkeys' })).findByText('Phone')).toBeInTheDocument();
    expect(screen.queryByRole('region', { name: 'Your new recovery codes' })).not.toBeInTheDocument();
  });

  it('shows the recovery codes once, with the first passkey', async () => {
    const user = userEvent.setup();
    const auth = fakeAuthApi({ passkeys: [] });
    renderApp(api(auth), '/settings#account');
    expect(await screen.findByText('No passkey yet.')).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Add a passkey' }));
    const codes = await screen.findByRole('region', { name: 'Your new recovery codes' });
    expect(within(codes).getAllByRole('listitem')).toHaveLength(10);
    expect(within(codes).getByText('code0-abcde')).toBeInTheDocument();
    await user.click(within(codes).getByRole('button', { name: 'I’ve saved them' }));
    expect(screen.queryByRole('region', { name: 'Your new recovery codes' })).not.toBeInTheDocument();
  });

  it('refuses to remove the last passkey when the server says so, and removes another', async () => {
    const user = userEvent.setup();
    const auth = fakeAuthApi({ passkeys: [makePasskey(1), makePasskey(2, { nickname: 'Phone' })] });
    const remove = auth.removePasskey;
    auth.removePasskey = async (id) => {
      if (id === 1) throw new ApiError(409, 'no', 'last_passkey');
      return remove(id);
    };
    renderApp(api(auth), '/settings#account');
    const list = await screen.findByRole('list', { name: 'Your passkeys' });
    const buttons = within(list).getAllByRole('button', { name: 'Remove' });
    await user.click(buttons[1]!);
    await waitFor(() => expect(auth.calls).toEqual(['removePasskey:2']));
    await waitFor(() => expect(within(screen.getByRole('list', { name: 'Your passkeys' })).queryByText('Phone')).not.toBeInTheDocument());
    await user.click(within(screen.getByRole('list', { name: 'Your passkeys' })).getByRole('button', { name: 'Remove' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('only passkey');
    expect(within(screen.getByRole('list', { name: 'Your passkeys' })).getByText('Device 1')).toBeInTheDocument();
  });

  it('replaces recovery codes only after confirming', async () => {
    const user = userEvent.setup();
    const auth = fakeAuthApi();
    renderApp(api(auth), '/settings#account');
    const panel = (await screen.findByRole('heading', { name: 'Sign-in' })).closest('section')!;
    expect(within(panel).getByText('10 of 10')).toBeInTheDocument();
    await user.click(within(panel).getByRole('button', { name: 'Generate new codes' }));
    const confirm = within(panel).getByRole('group', { name: 'Confirm new recovery codes' });
    await user.click(within(confirm).getByRole('button', { name: 'Keep them' }));
    expect(auth.calls).toEqual([]);
    await user.click(within(panel).getByRole('button', { name: 'Generate new codes' }));
    await user.click(within(panel).getByRole('button', { name: 'Replace my codes' }));
    await waitFor(() => expect(auth.calls).toEqual(['regenerateRecoveryCodes']));
    expect(await screen.findByRole('region', { name: 'Your new recovery codes' })).toBeInTheDocument();
  });

  it('signs this browser out from the Sign-in section and lands on the signed-out Overview', async () => {
    const user = userEvent.setup();
    const auth = fakeAuthApi();
    let signedOut = false;
    const base = connectedApi();
    const calls: string[] = [];
    const apiWithSignOut: RunoutApi = {
      ...base,
      getConnection: async (): Promise<ConnectionState> => (signedOut ? { status: 'signed_out' } : base.getConnection()),
      signOut: async () => { calls.push('signOut'); signedOut = true; },
      auth: { ...auth, status: async () => (signedOut ? { signedIn: false } : auth.status()) },
    };
    renderApp(apiWithSignOut, '/settings#account');
    const list = await screen.findByRole('list', { name: 'Signed-in browsers' });
    const mine = within(list).getByText('This browser').closest('li')!;
    await user.click(within(mine).getByRole('button', { name: 'Sign out' }));
    await waitFor(() => expect(calls).toEqual(['signOut']));
    await waitFor(() => expect(location.current).toBe('/overview'));
    expect(await screen.findByRole('button', { name: 'Sign in with a passkey' })).toBeInTheDocument();
    expect(auth.calls).toEqual([]);
  });

  it('lists signed-in browsers and signs another one out', async () => {
    const user = userEvent.setup();
    const auth = fakeAuthApi();
    renderApp(api(auth), '/settings#account');
    const list = await screen.findByRole('list', { name: 'Signed-in browsers' });
    expect(within(list).getByText('This browser')).toBeInTheDocument();
    expect(within(list).getByText('Safari on iOS')).toBeInTheDocument();
    expect(within(list).getAllByRole('button', { name: 'Sign out' })).toHaveLength(2);
    const other = within(list).getByText('Safari on iOS').closest('li')!;
    await user.click(within(other).getByRole('button', { name: 'Sign out' }));
    await waitFor(() => expect(auth.calls).toEqual(['revokeSession:2']));
    await waitFor(() => expect(within(screen.getByRole('list', { name: 'Signed-in browsers' })).queryByText('Safari on iOS')).not.toBeInTheDocument());
  });
});

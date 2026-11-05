import { screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { RunoutApi } from '../../data/api';
import type { ConnectionState } from '../../data/types';
import { connectedApi, fakeAuthApi, notConnectedApi } from '../../test/fixtures';
import { location, renderApp } from '../../test/renderApp';

/** jsdom has no WebAuthn; the fake API never reaches it, so only the support check matters. */
function supportPasskeys() {
  Object.defineProperty(globalThis, 'PublicKeyCredential', {
    configurable: true,
    value: { parseCreationOptionsFromJSON: () => ({}), parseRequestOptionsFromJSON: () => ({}) },
  });
}

/** Signed out until a sign-in succeeds, then the connected account. */
function signedOutApi(auth = fakeAuthApi({ session: { signedIn: false } })): RunoutApi {
  let connection: ConnectionState = { status: 'none' };
  const connected = connectedApi();
  return {
    ...connected,
    getConnection: async () => connection,
    auth: {
      ...auth,
      signInWithPasskey: async () => {
        const session = await auth.signInWithPasskey();
        connection = await connected.getConnection();
        return session;
      },
      signInWithRecoveryCode: async (code) => {
        const session = await auth.signInWithRecoveryCode(code);
        connection = await connected.getConnection();
        return session;
      },
    },
  };
}

beforeEach(() => localStorage.clear());
afterEach(() => {
  delete (globalThis as { PublicKeyCredential?: unknown }).PublicKeyCredential;
});

describe('Signed out', () => {
  it('offers only Last.fm while Runout’s own sign-in is switched off on the server', async () => {
    renderApp(notConnectedApi, '/overview');
    expect(await screen.findByRole('link', { name: 'Connect Last.fm' })).toHaveAttribute('href', '/api/auth/lastfm');
    expect(screen.queryByRole('button', { name: /passkey/ })).not.toBeInTheDocument();
  });

  it('signs in with a passkey and shows the listening', async () => {
    supportPasskeys();
    const user = userEvent.setup();
    const auth = fakeAuthApi({ session: { signedIn: false } });
    renderApp(signedOutApi(auth), '/overview?period=all');
    const button = await screen.findByRole('button', { name: 'Sign in with a passkey' });
    expect(screen.getByRole('link', { name: 'Sign in with Last.fm' })).toHaveAttribute('href', '/api/auth/lastfm');
    await user.click(button);
    await waitFor(() => expect(auth.calls).toEqual(['signInWithPasskey']));
    expect(await screen.findByText(/4,321/)).toBeInTheDocument();
  });

  it('explains when the browser can’t use passkeys and still takes a recovery code', async () => {
    const user = userEvent.setup();
    const auth = fakeAuthApi({ session: { signedIn: false } });
    renderApp(signedOutApi(auth), '/overview?period=all');
    expect(await screen.findByRole('button', { name: 'Sign in with a passkey' })).toBeDisabled();
    expect(screen.getByText(/This browser can’t use passkeys here/)).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Use a recovery code instead' }));
    await user.type(screen.getByRole('textbox', { name: 'Recovery code' }), 'abcde-fghjk');
    await user.click(screen.getByRole('button', { name: 'Use code' }));
    await waitFor(() => expect(auth.calls).toEqual(['signInWithRecoveryCode:abcde-fghjk']));
    await waitFor(() => expect(location.current).toBe('/settings?recovered=1'));
    expect(await screen.findByText(/You signed in with a recovery code/)).toBeInTheDocument();
  });

  it('shows what went wrong without changing anything', async () => {
    supportPasskeys();
    const user = userEvent.setup();
    const auth = fakeAuthApi({ session: { signedIn: false } });
    const api = signedOutApi(auth);
    api.auth.signInWithPasskey = async () => {
      const { ApiError } = await import('../../data/api');
      throw new ApiError(401, 'no', 'passkey_rejected');
    };
    renderApp(api, '/overview?period=all');
    await user.click(await screen.findByRole('button', { name: 'Sign in with a passkey' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('That passkey wasn’t accepted');
    expect(screen.getByRole('button', { name: 'Sign in with a passkey' })).toBeInTheDocument();
  });
});

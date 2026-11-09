import { screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { RunoutApi } from '../../data/api';
import type { ConnectionState } from '../../data/types';
import { connectedApi, fakeAuthApi, notConnectedApi } from '../../test/fixtures';
import { location, renderApp } from '../../test/renderApp';
import { viewport } from '../../test/setup';

/** jsdom has no WebAuthn; the fake API never reaches it, so only the support check matters. */
function supportPasskeys() {
  Object.defineProperty(globalThis, 'PublicKeyCredential', {
    configurable: true,
    value: { parseCreationOptionsFromJSON: () => ({}), parseRequestOptionsFromJSON: () => ({}) },
  });
}

/** Signed out until a sign-in succeeds, then the connected account. */
function signedOutApi(auth = fakeAuthApi({ session: { signedIn: false } })): RunoutApi {
  let connection: ConnectionState = { status: 'signed_out' };
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

  it('puts Google first when the server offers it, with the passkey beside it, on a desktop and on a phone', async () => {
    supportPasskeys();
    for (const width of [1440, 390]) {
      viewport.width = width;
      const { unmount } = renderApp(signedOutApi(fakeAuthApi({ session: { signedIn: false, providers: { google: true } } })), '/overview?period=all');
      const google = await screen.findByRole('link', { name: 'Continue with Google' });
      expect(google).toHaveAttribute('href', '/api/auth/google?intent=sign_in&return=overview');
      expect(screen.getByRole('button', { name: 'Sign in with a passkey' })).toBeEnabled();
      expect(screen.getByRole('button', { name: 'Use a recovery code instead' })).toBeInTheDocument();
      // Google leads: it comes before the passkey in the page.
      expect(google.compareDocumentPosition(screen.getByRole('button', { name: 'Sign in with a passkey' })) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
      expect(screen.getByText(/Invited people sign in with Google or a passkey/)).toBeInTheDocument();
      unmount();
    }
    viewport.width = 1440;
  });

  it('offers no Google when the server has none configured', async () => {
    supportPasskeys();
    renderApp(signedOutApi(fakeAuthApi({ session: { signedIn: false, providers: { google: false } } })), '/overview?period=all');
    await screen.findByRole('button', { name: 'Sign in with a passkey' });
    expect(screen.queryByRole('link', { name: 'Continue with Google' })).toBeNull();
  });

  it('says in plain words why Google did not sign anyone in', async () => {
    supportPasskeys();
    renderApp(signedOutApi(fakeAuthApi({ session: { signedIn: false, providers: { google: true } } })), '/overview?google_error=no_account');
    expect(await screen.findByRole('alert')).toHaveTextContent('isn’t linked to a Runout account');
    expect(screen.getByRole('alert')).toHaveTextContent('by invitation');
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
    await waitFor(() => expect(location.current).toMatch(/^\/settings\?recovered=1.*#sign-in$/));
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

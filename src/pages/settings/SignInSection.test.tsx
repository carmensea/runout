import { screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { ApiError, type RunoutApi } from '../../data/api';
import { connectedApi, fakeAuthApi, makePasskey } from '../../test/fixtures';
import { renderApp } from '../../test/renderApp';

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

describe('Settings: sign-in', () => {
  it('is absent while the server has Runout’s own sign-in switched off', async () => {
    renderApp(connectedApi(), '/settings');
    await screen.findByRole('heading', { name: 'Account' });
    expect(screen.queryByRole('heading', { name: 'Sign-in' })).not.toBeInTheDocument();
  });

  it('lists passkeys and adds one with the typed name', async () => {
    const user = userEvent.setup();
    const auth = fakeAuthApi();
    renderApp(api(auth), '/settings');
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
    renderApp(api(auth), '/settings');
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
    renderApp(api(auth), '/settings');
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
    renderApp(api(auth), '/settings');
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

  it('lists signed-in browsers and signs another one out', async () => {
    const user = userEvent.setup();
    const auth = fakeAuthApi();
    renderApp(api(auth), '/settings');
    const list = await screen.findByRole('list', { name: 'Signed-in browsers' });
    expect(within(list).getByText('This browser')).toBeInTheDocument();
    expect(within(list).getByText('Safari on iOS')).toBeInTheDocument();
    expect(within(list).getAllByRole('button', { name: 'Sign out' })).toHaveLength(1);
    await user.click(within(list).getByRole('button', { name: 'Sign out' }));
    await waitFor(() => expect(auth.calls).toEqual(['revokeSession:2']));
    await waitFor(() => expect(within(screen.getByRole('list', { name: 'Signed-in browsers' })).queryByText('Safari on iOS')).not.toBeInTheDocument());
  });
});

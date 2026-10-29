import { screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it } from 'vitest';
import { connectedApi } from '../../test/fixtures';
import { location, renderApp } from '../../test/renderApp';

describe('SearchField', () => {
  it('focuses on "/", moves with arrows and opens the result on Enter', async () => {
    const user = userEvent.setup();
    renderApp(connectedApi());
    await screen.findByText('4,321');
    await user.keyboard('/');
    const box = screen.getByRole('combobox');
    expect(box).toHaveFocus();
    await user.keyboard('test');
    await screen.findByRole('option', { name: /Test Artist A/ });
    await user.keyboard('{ArrowDown}');
    expect(box.getAttribute('aria-activedescendant')).toBeTruthy();
    await user.keyboard('{Enter}');
    await waitFor(() => expect(location.current).toMatch(/^\/artists\/a1\?/));
  });

  it('closes on Escape, then clears on a second Escape', async () => {
    const user = userEvent.setup();
    renderApp(connectedApi());
    await screen.findByText('4,321');
    const box = screen.getByRole('combobox');
    await user.click(box);
    await user.keyboard('test');
    await screen.findByRole('option', { name: /Test Artist A/ });
    await user.keyboard('{Escape}');
    expect(screen.queryByRole('listbox', { name: 'Search results' })).not.toBeInTheDocument();
    expect(box).toHaveValue('test');
    await user.keyboard('{Escape}');
    expect(box).toHaveValue('');
  });
});

import { screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { connectedApi } from '../../test/fixtures';
import { renderApp } from '../../test/renderApp';

beforeEach(() => {
  localStorage.clear();
  delete document.documentElement.dataset.theme;
});
afterEach(() => {
  delete document.documentElement.dataset.theme;
});

describe('Settings: appearance', () => {
  it('offers the five themes as a radio group with Original selected by default', async () => {
    renderApp(connectedApi(), '/settings#appearance');
    const group = await screen.findByRole('radiogroup', { name: 'Theme' });
    const radios = within(group).getAllByRole('radio');
    expect(radios.map((r) => r.textContent)).toEqual([
      expect.stringContaining('Original'), expect.stringContaining('Moss'), expect.stringContaining('Cotton Candy'), expect.stringContaining('Midnight Candy'), expect.stringContaining('Verdant'),
    ]);
    expect(within(group).getByRole('radio', { name: /Original/ })).toHaveAttribute('aria-checked', 'true');
    expect(within(group).getByRole('radio', { name: /Moss/ })).toHaveAttribute('aria-checked', 'false');
  });

  it('switches the theme at once, marks the choice, and keeps it for the next visit', async () => {
    const user = userEvent.setup();
    renderApp(connectedApi(), '/settings#appearance');
    const group = await screen.findByRole('radiogroup', { name: 'Theme' });
    await user.click(within(group).getByRole('radio', { name: /Cotton Candy/ }));
    expect(document.documentElement.dataset.theme).toBe('cotton-candy');
    expect(within(group).getByRole('radio', { name: /Cotton Candy/ })).toHaveAttribute('aria-checked', 'true');
    expect(within(group).getByRole('radio', { name: /Original/ })).toHaveAttribute('aria-checked', 'false');
    expect(localStorage.getItem('runout:theme')).toBe('cotton-candy');
    expect(screen.getByTestId('sky')).toBeInTheDocument();
    await user.click(within(group).getByRole('radio', { name: /Original/ }));
    expect(document.documentElement.dataset.theme).toBeUndefined();
    expect(screen.queryByTestId('sky')).not.toBeInTheDocument();
  });

  it('is reachable by keyboard', async () => {
    const user = userEvent.setup();
    renderApp(connectedApi(), '/settings#appearance');
    const group = await screen.findByRole('radiogroup', { name: 'Theme' });
    const moss = within(group).getByRole('radio', { name: /Moss/ });
    moss.focus();
    await user.keyboard('{Enter}');
    expect(document.documentElement.dataset.theme).toBe('moss');
  });

  it('shows the sky only for the candy themes, from a stored choice too', async () => {
    localStorage.setItem('runout:theme', 'midnight-candy');
    document.documentElement.dataset.theme = 'midnight-candy';
    renderApp(connectedApi(), '/overview?period=all');
    expect(await screen.findByTestId('sky')).toBeInTheDocument();
  });
});

import { screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { connectedApi, makeOverview, notConnectedApi } from '../../../test/fixtures';
import { location, renderApp } from '../../../test/renderApp';
import { viewport } from '../../../test/setup';

beforeEach(() => {
  localStorage.clear();
  viewport.width = 390;
});
afterEach(() => {
  viewport.width = 1440;
});

describe('Overview on mobile', () => {
  it('renders the mobile composition instead of the desktop sections', async () => {
    renderApp(connectedApi());
    expect(await screen.findByText('4,321')).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: 'By hour of day' })).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: 'Day and time' })).toBeInTheDocument();
    expect(screen.queryByRole('heading', { name: 'When you listen' })).not.toBeInTheDocument();
    expect(screen.queryByRole('radiogroup', { name: 'Period type' })).not.toBeInTheDocument();
  });

  it('selects an activity bar and links that period into Time Machine', async () => {
    const user = userEvent.setup();
    const data = makeOverview({
      activity: {
        ...makeOverview().activity,
        year: [
          { key: '2019', scrobbles: 5, topArtist: null },
          { key: '2020', scrobbles: 60, topArtist: null },
        ],
      },
    });
    renderApp(connectedApi(() => data));
    await screen.findByText('4,321');
    expect(screen.getByRole('link', { name: 'Open 2020 in Time Machine' })).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: '2019, 5 scrobbles' }));
    expect(screen.getByRole('link', { name: 'Open 2019 in Time Machine' })).toHaveAttribute('href', expect.stringContaining('at=2019'));
  });

  it('expands a genre to show its artists', async () => {
    const user = userEvent.setup();
    renderApp(connectedApi());
    await screen.findByText('4,321');
    const rock = screen.getByRole('button', { name: /Rock/, expanded: false });
    await user.click(rock);
    expect(rock).toHaveAttribute('aria-expanded', 'true');
    expect(screen.getByRole('button', { name: 'Clear selection' })).toBeInTheDocument();
    expect(screen.getByText('Post-punk')).toBeInTheDocument();
  });

  it('applies a period and comparison from the sheet in one step', async () => {
    const user = userEvent.setup();
    renderApp(connectedApi(), '/overview?period=all');
    await screen.findByText('4,321');
    await user.click(screen.getByRole('button', { name: /^Period: Entire history/ }));
    const sheet = screen.getByRole('dialog', { name: 'Period' });
    await user.click(within(sheet).getByRole('radio', { name: 'Year' }));
    await user.click(within(sheet).getByRole('button', { name: '2024' }));
    await user.click(within(sheet).getByRole('switch'));
    await user.click(within(sheet).getByRole('button', { name: 'Show 2024' }));
    await waitFor(() => expect(location.current).toContain('period=year%3A2024'));
    expect(location.current).toContain('vs=year%3A2023');
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: /^Period: 2024 vs 2023/ })).toHaveFocus();
  });

  it('closes the sheet on Escape without changing the period', async () => {
    const user = userEvent.setup();
    renderApp(connectedApi(), '/overview?period=year:2024');
    await screen.findByText('4,321');
    await user.click(screen.getByRole('button', { name: /^Period: 2024/ }));
    const sheet = screen.getByRole('dialog', { name: 'Period' });
    await user.click(within(sheet).getByRole('radio', { name: 'Month' }));
    await user.keyboard('{Escape}');
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    expect(location.current).toMatch(/period=year(%3A|:)2024$/);
  });

  it('shows the sign-in state on mobile too', async () => {
    renderApp(notConnectedApi);
    expect(await screen.findByText('Sign in to see your listening.')).toBeInTheDocument();
  });
});

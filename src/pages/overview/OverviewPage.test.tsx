import { act, fireEvent, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it } from 'vitest';
import type { RunoutApi } from '../../data/api';
import { connectedApi, makeOverview, notConnectedApi } from '../../test/fixtures';
import { location, renderApp } from '../../test/renderApp';

beforeEach(() => localStorage.clear());

describe('Overview, not connected', () => {
  it('shows the connect state and never renders figures', async () => {
    renderApp(notConnectedApi);
    expect(await screen.findByText('Connect your Last.fm account to see your listening.')).toBeInTheDocument();
    expect(screen.getAllByText('Last.fm not connected').length).toBeGreaterThan(0);
    expect(screen.queryByText('Scrobbles')).not.toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Connect Last.fm' })).toHaveAttribute('href', expect.stringContaining('/connect'));
  });

  it('explains that search needs a connected library', async () => {
    const user = userEvent.setup();
    renderApp(notConnectedApi);
    await user.type(screen.getByRole('combobox'), 'ab');
    expect(await screen.findByText(/Search covers your own listening history/)).toBeInTheDocument();
  });
});

describe('Overview, connected', () => {
  it('renders stats from the API', async () => {
    renderApp(connectedApi());
    expect(await screen.findByText('4,321')).toBeInTheDocument();
    expect(screen.getByText('Since first scrobble 2020-01-05')).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: 'When you listen' })).toBeInTheDocument();
  });

  it('changes the period from the segmented control and keeps it in the URL', async () => {
    const user = userEvent.setup();
    const seen: string[] = [];
    renderApp(connectedApi((p) => {
      seen.push(p);
      return makeOverview();
    }));
    await screen.findByText('4,321');
    await user.click(within(screen.getByRole('radiogroup', { name: 'Period type' })).getByRole('radio', { name: 'Year' }));
    expect(location.current).toMatch(/period=year%3A\d{4}/);
    expect(await screen.findByText(/^Overview · \d{4}$/)).toBeInTheDocument();
    expect(seen.some((p) => p.startsWith('year:'))).toBe(true);

    await user.click(screen.getByRole('button', { name: 'Previous period' }));
    expect(location.current).toMatch(/period=year%3A\d{4}/);
  });

  it('adds and clears a comparison', async () => {
    const user = userEvent.setup();
    renderApp(connectedApi(), '/overview?period=year:2024');
    await screen.findByText('4,321');
    await user.click(screen.getByRole('button', { name: /Compare/ }));
    expect(location.current).toContain('vs=year%3A2023');
    expect(await screen.findByText('Overview · 2024 compared with 2023')).toBeInTheDocument();
    expect((await screen.findAllByText(/^2023: /)).length).toBe(4);

    const clear = screen.getByRole('button', { name: 'Clear comparison' });
    await user.click(clear);
    expect(location.current).not.toContain('vs=');
    expect(screen.getByRole('button', { name: /Compare/ })).toHaveFocus();
  });

  it('disables comparison for all time', async () => {
    renderApp(connectedApi());
    await screen.findByText('4,321');
    expect(screen.getByRole('button', { name: /Compare/ })).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Previous period' })).toBeDisabled();
  });

  it('pins an activity bar from the keyboard and links into Time Machine', async () => {
    renderApp(connectedApi());
    await screen.findByText('4,321');
    const plot = screen.getByRole('group', { name: /Bar chart of scrobbles per month/ });
    act(() => plot.focus());
    fireEvent.keyDown(plot, { key: 'ArrowRight' });
    fireEvent.keyDown(plot, { key: 'Enter' });
    const tip = await screen.findByRole('dialog', { name: 'January 2020 details' });
    const link = within(tip).getByRole('link', { name: 'Open in Time Machine' });
    expect(link.getAttribute('href')).toContain('/time-machine?at=2020-01&period=month%3A2020-01');
  });

  it('switches the activity chart to a table and back', async () => {
    const user = userEvent.setup();
    renderApp(connectedApi());
    await screen.findByText('4,321');
    await user.click(screen.getByRole('button', { name: 'View as table' }));
    const table = screen.getByRole('table', { name: 'Scrobbles per month' });
    expect(within(table).getByText('February 2020')).toBeInTheDocument();
    expect(within(table).getByText('30')).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'View as chart' }));
    expect(screen.queryByRole('table', { name: 'Scrobbles per month' })).not.toBeInTheDocument();
  });

  it('disables week granularity outside two-year periods', async () => {
    renderApp(connectedApi());
    await screen.findByText('4,321');
    const week = screen.getByRole('radio', { name: 'Week' });
    expect(week).toBeDisabled();
    expect(week).toHaveAttribute('title', 'Available for periods up to 2 years');
  });

  it('selects a genre with the keyboard and clears it', async () => {
    const user = userEvent.setup();
    renderApp(connectedApi());
    await screen.findByText('4,321');
    const rock = screen.getByRole('option', { name: /Rock/ });
    expect(rock).toHaveAttribute('aria-selected', 'true');
    act(() => rock.focus());
    await user.keyboard('{ArrowDown}');
    expect(screen.getByRole('option', { name: /Jazz/ })).toHaveAttribute('aria-selected', 'true');
    await user.click(screen.getByRole('button', { name: 'Clear selection' }));
    expect(screen.queryByRole('button', { name: 'Clear selection' })).not.toBeInTheDocument();
  });

  it('shows an empty state for a period without scrobbles', async () => {
    const empty = makeOverview({ stats: { ...makeOverview().stats, scrobbles: 0 }, nearestWithData: ['year:2019'] });
    renderApp(connectedApi(() => empty), '/overview?period=year:2024');
    expect(await screen.findByText('No scrobbles in 2024.')).toBeInTheDocument();
    expect(screen.getByRole('link', { name: '2019' })).toBeInTheDocument();
  });

  it('shows an error with retry when the overview fails', async () => {
    const user = userEvent.setup();
    let calls = 0;
    const api: RunoutApi = {
      ...connectedApi(),
      getOverview: async () => {
        calls += 1;
        if (calls === 1) throw new Error('Request to /overview failed with HTTP 500.');
        return makeOverview();
      },
    };
    renderApp(api);
    expect(await screen.findByText('Scrobbles for Entire history could not be loaded.')).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Try again' }));
    expect(await screen.findByText('4,321')).toBeInTheDocument();
  });
});

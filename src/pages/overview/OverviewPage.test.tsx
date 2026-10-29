import { act, fireEvent, screen, waitFor, within } from '@testing-library/react';
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
    expect(screen.getByRole('link', { name: 'Connect Last.fm' })).toHaveAttribute('href', '/api/auth/lastfm');
  });

  it('explains that search needs a connected library', async () => {
    const user = userEvent.setup();
    renderApp(notConnectedApi);
    await user.type(screen.getByRole('combobox'), 'ab');
    expect(await screen.findByText(/Search covers your own listening history/)).toBeInTheDocument();
  });
});

describe('Overview, authentication states', () => {
  it('explains a failed sign-in', async () => {
    renderApp(notConnectedApi, '/overview?period=all&auth_error=state');
    expect(await screen.findByRole('alert')).toHaveTextContent('That sign-in link expired or was opened in another browser.');
  });

  it('shows a signed-in account without history, and loads no charts', async () => {
    let overviewCalls = 0;
    const api: RunoutApi = {
      ...connectedApi(),
      getConnection: async () => ({ status: 'connected', username: 'test-user', timezone: 'Europe/London' }),
      getOverview: async () => {
        overviewCalls += 1;
        return makeOverview();
      },
    };
    renderApp(api);
    expect(await screen.findByText('Signed in as test-user.')).toBeInTheDocument();
    expect(screen.getByText(/Importing your Last.fm history is not available/)).toBeInTheDocument();
    expect(overviewCalls).toBe(0);
    expect(screen.getAllByText('Last.fm connected').length).toBeGreaterThan(0);
  });

  it('signs out from Settings', async () => {
    const user = userEvent.setup();
    let signedIn = true;
    const api: RunoutApi = {
      ...connectedApi(),
      getConnection: async () => (signedIn ? { status: 'connected', username: 'test-user', timezone: 'Europe/London' } : { status: 'none' }),
      signOut: async () => {
        signedIn = false;
      },
    };
    renderApp(api, '/settings');
    await user.click(await screen.findByRole('button', { name: 'Sign out' }));
    expect(await screen.findByText('Connect your Last.fm account to see your listening.')).toBeInTheDocument();
    expect(location.current).toMatch(/^\/overview/);
  });

  it('deletes the account only after the username is typed, then explains how to revoke access', async () => {
    const user = userEvent.setup();
    let signedIn = true;
    const confirmations: string[] = [];
    const api: RunoutApi = {
      ...connectedApi(),
      getConnection: async () => (signedIn ? { status: 'connected', username: 'test-user', timezone: 'Europe/London' } : { status: 'none' }),
      deleteAccount: async (confirm) => {
        confirmations.push(confirm);
        signedIn = false;
        return { revokeAccessUrl: 'https://www.last.fm/settings/applications' };
      },
    };
    renderApp(api, '/settings');
    const remove = await screen.findByRole('button', { name: 'Delete account' });
    expect(remove).toBeDisabled();
    await user.type(screen.getByLabelText(/Type your Last.fm username/), 'wrong');
    expect(remove).toBeDisabled();
    await user.clear(screen.getByLabelText(/Type your Last.fm username/));
    await user.type(screen.getByLabelText(/Type your Last.fm username/), 'TEST-USER');
    await user.click(remove);
    expect(await screen.findByText('Your Runout account and its data were deleted.')).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Last.fm application settings' })).toHaveAttribute('href', 'https://www.last.fm/settings/applications');
    expect(confirmations).toEqual(['TEST-USER']);
    await waitFor(() => expect(screen.queryByRole('button', { name: 'Sign out' })).not.toBeInTheDocument());
  });

  it('reports a failed deletion without claiming anything was removed', async () => {
    const user = userEvent.setup();
    const api: RunoutApi = {
      ...connectedApi(),
      getConnection: async () => ({ status: 'connected', username: 'test-user', timezone: 'Europe/London' }),
      deleteAccount: async () => {
        throw new Error('network');
      },
    };
    renderApp(api, '/settings');
    await user.type(await screen.findByLabelText(/Type your Last.fm username/), 'test-user');
    await user.click(screen.getByRole('button', { name: 'Delete account' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('Deletion did not complete.');
  });

  it('explains every sign-in error the server can report', async () => {
    renderApp(notConnectedApi, '/overview?period=all&auth_error=rate_limited');
    expect(await screen.findByRole('alert')).toHaveTextContent('Too many sign-in attempts.');
  });

  it('credits Last.fm wherever listening data is shown', async () => {
    renderApp(connectedApi());
    await screen.findByText('4,321');
    expect(screen.getByRole('link', { name: 'Last.fm' })).toHaveAttribute('href', 'https://www.last.fm');
    expect(screen.getByText(/powered by AudioScrobbler/)).toBeInTheDocument();
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

import { act, fireEvent, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it } from 'vitest';
import type { RunoutApi } from '../../data/api';
import { connectedApi, makeOverview, notConnectedApi } from '../../test/fixtures';
import { location, renderApp } from '../../test/renderApp';

beforeEach(() => localStorage.clear());

describe('Overview, signed out', () => {
  it('shows the sign-in state and never renders figures', async () => {
    renderApp(notConnectedApi);
    expect(await screen.findByText('Sign in to see your listening.')).toBeInTheDocument();
    expect(screen.getAllByText('Not signed in').length).toBeGreaterThan(0);
    expect(screen.queryByText('Scrobbles')).not.toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Connect Last.fm' })).toHaveAttribute('href', '/api/auth/lastfm');
  });

  it('explains that search needs a stored library', async () => {
    const user = userEvent.setup();
    renderApp(notConnectedApi);
    await user.type(screen.getByRole('combobox'), 'ab');
    expect(await screen.findByText(/Search covers your stored listening history/)).toBeInTheDocument();
  });
});

describe('Overview, authentication states', () => {
  it('explains a failed sign-in', async () => {
    renderApp(notConnectedApi, '/overview?period=all&auth_error=state');
    expect(await screen.findByRole('alert')).toHaveTextContent('That sign-in link expired or was opened in another browser.');
  });

  it('shows a signed-in account without history', async () => {
    const api: RunoutApi = {
      ...connectedApi(() => makeOverview({ stats: { ...makeOverview().stats, scrobbles: 0 }, nearestWithData: [] })),
      getConnection: async () => ({ status: 'connected', displayName: 'test-user', username: 'test-user', timezone: 'Europe/London', features: [] }),
    };
    renderApp(api);
    expect(await screen.findByText('Signed in as test-user.')).toBeInTheDocument();
    expect(screen.getByText(/Your listening history hasn’t been imported yet/)).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Start the import in Settings' })).toBeInTheDocument();
    expect(screen.getAllByText('Last.fm connected').length).toBeGreaterThan(0);
  });

  it('shows plays recorded from Spotify when Last.fm was never imported', async () => {
    const api: RunoutApi = {
      ...connectedApi(),
      getConnection: async () => ({ status: 'connected', displayName: 'test-user', username: 'test-user', timezone: 'Europe/London', features: [] }),
    };
    renderApp(api);
    expect(await screen.findByRole('heading', { name: '01 / Listening overview' })).toBeInTheDocument();
    expect(screen.queryByText(/hasn’t been imported yet/)).not.toBeInTheDocument();
  });

  it('signs out from Settings', async () => {
    const user = userEvent.setup();
    let signedIn = true;
    const api: RunoutApi = {
      ...connectedApi(),
      getConnection: async () => (signedIn ? { status: 'connected', displayName: 'test-user', username: 'test-user', timezone: 'Europe/London', features: [] } : { status: 'signed_out' }),
      signOut: async () => {
        signedIn = false;
      },
    };
    renderApp(api, '/settings#account');
    await user.click(await screen.findByRole('button', { name: 'Sign out' }));
    expect(await screen.findByText('Sign in to see your listening.')).toBeInTheDocument();
    expect(location.current).toMatch(/^\/overview/);
  });

  it('deletes the account only after the username is typed, then explains how to revoke access', async () => {
    const user = userEvent.setup();
    let signedIn = true;
    const confirmations: string[] = [];
    const api: RunoutApi = {
      ...connectedApi(),
      getConnection: async () => (signedIn ? { status: 'connected', displayName: 'test-user', username: 'test-user', timezone: 'Europe/London', features: [] } : { status: 'signed_out' }),
      deleteAccount: async (confirm) => {
        confirmations.push(confirm);
        signedIn = false;
        return { revokeAccessUrl: 'https://www.last.fm/settings/applications', spotifyAppsUrl: null };
      },
    };
    renderApp(api, '/settings#account');
    const remove = await screen.findByRole('button', { name: 'Delete account' });
    expect(remove).toBeDisabled();
    await user.type(screen.getByLabelText(/Type your name/), 'wrong');
    expect(remove).toBeDisabled();
    await user.clear(screen.getByLabelText(/Type your name/));
    await user.type(screen.getByLabelText(/Type your name/), 'TEST-USER');
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
      getConnection: async () => ({ status: 'connected', displayName: 'test-user', username: 'test-user', timezone: 'Europe/London', features: [] }),
      deleteAccount: async () => {
        throw new Error('network');
      },
    };
    renderApp(api, '/settings#account');
    await user.type(await screen.findByLabelText(/Type your name/), 'test-user');
    await user.click(screen.getByRole('button', { name: 'Delete account' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('Deletion did not complete.');
  });

  it.each([
    ['rate_limited', 'Too many sign-in attempts.'],
    ['denied', 'Sign-in was cancelled or not confirmed on Last.fm.'],
    ['account_not_allowed', 'set up for a different Last.fm account'],
    ['relink_required', 'relink it on the server'],
    ['identity_changed', 'looks like a different account'],
    ['identity_unverified', 'did not return enough account details'],
    ['lastfm_unavailable', 'Last.fm could not be reached'],
  ])('explains the %s sign-in error accurately', async (code, text) => {
    renderApp(notConnectedApi, `/overview?period=all&auth_error=${code}`);
    expect(await screen.findByRole('alert')).toHaveTextContent(text);
  });

  it('does not blame Last.fm availability for identity problems', async () => {
    renderApp(notConnectedApi, '/overview?period=all&auth_error=identity_unverified');
    expect(await screen.findByRole('alert')).not.toHaveTextContent('could not be reached');
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

  it('opens an activity bar in Time Machine from the keyboard', async () => {
    renderApp(connectedApi());
    await screen.findByText('4,321');
    const plot = screen.getByRole('group', { name: /Bar chart of scrobbles per month/ });
    act(() => plot.focus());
    fireEvent.keyDown(plot, { key: 'ArrowRight' });
    fireEvent.keyDown(plot, { key: 'Enter' });
    await waitFor(() => expect(location.current).toContain('/time-machine?at=2020-01&period=month%3A2020-01'));
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

  it('says what isn’t available yet instead of showing figures (genres, metadata, artwork)', async () => {
    const real = makeOverview({ genres: null, metadata: null, stats: { ...makeOverview().stats, albumsWithoutArtwork: null } });
    renderApp(connectedApi(() => real), '/overview?period=year:2020');
    expect(await screen.findByText(/Genres aren’t available yet/)).toBeInTheDocument();
    expect(screen.getByText(/Artist metadata isn’t available yet/)).toBeInTheDocument();
    expect(screen.getByText('Artwork arrives in a later version')).toBeInTheDocument();
    expect(screen.queryByText(/without artwork/)).not.toBeInTheDocument();
  });

  it('shows album artwork only from the Cover Art Archive, credits it, and counts albums without artwork', async () => {
    const user = userEvent.setup();
    const base = makeOverview();
    const album = { ...base.top.artists[0]!, artist: 'Test Artist A', tracksPlayed: null };
    const real = makeOverview({
      top: {
        ...base.top,
        albums: [
          { ...album, id: 'l1', name: 'Covered', imageUrl: 'https://coverartarchive.org/release/r1/1-250.jpg' },
          { ...album, id: 'l2', name: 'Elsewhere', imageUrl: 'https://example.com/cover.jpg' },
        ],
      },
    });
    const { container } = renderApp(connectedApi(() => real), '/overview?period=year:2020');
    await user.click(await screen.findByRole('tab', { name: 'Albums' }));
    const images = [...container.querySelectorAll('img')].map((i) => i.getAttribute('src'));
    expect(images).toEqual(['https://coverartarchive.org/release/r1/1-250.jpg']);
    expect(screen.getByRole('link', { name: 'Cover Art Archive' })).toHaveAttribute('href', 'https://coverartarchive.org');
    expect(screen.getByText('2 without artwork')).toBeInTheDocument();
  });

  it('shows genres as whole percentages that add up to 100, explains Unclassified, credits MusicBrainz and opens a genre', async () => {
    const user = userEvent.setup();
    renderApp(connectedApi(), '/overview?period=year:2020');
    const list = await screen.findByRole('listbox', { name: 'Genres' });
    const shown = within(list).getAllByRole('option').map((o) => o.textContent);
    expect(shown).toEqual(['Rock60%', 'Jazz30%']);
    expect(screen.getByText('10% of plays are unclassified: 3% by artists not looked up yet, 5% by artists without a MusicBrainz ID, 2% by artists with no listed genres.')).toBeInTheDocument();
    expect(screen.getByText(/CC BY-NC-SA 3.0/)).toBeInTheDocument();
    await user.click(within(list).getByRole('option', { name: /Rock/ }));
    expect(screen.getByRole('link', { name: 'Open Rock' })).toHaveAttribute('href', '/genres/rock?period=year%3A2020');
  });

  it('lists the dates a period is missing, and says figures cover imported history only', async () => {
    const missing = [
      { from: '2020-06-01', to: '2020-06-30', startsAt: '2020-05-31T23:00:00Z', endsAt: '2020-06-30T23:00:00Z', partialFrom: false, partialTo: false },
      // The UTC month of August in London time: from 01:00 BST on 1 August to 01:00 on 1 September.
      { from: '2020-08-01', to: '2020-09-01', startsAt: '2020-08-01T00:00:00Z', endsAt: '2020-09-01T00:00:00Z', partialFrom: true, partialTo: true },
    ];
    const partial = makeOverview({ coverage: { status: 'partial', missing } });
    renderApp(connectedApi(() => partial), '/overview?period=year:2020');
    expect(await screen.findByText(/Part of this period isn’t imported: 2020-06-01 to 2020-06-30, 2020-08-01 01:00 to 2020-09-01 01:00\. Figures cover imported/)).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Import status' })).toHaveAttribute('href', expect.stringMatching(/^\/settings\?period=.*#history$/));
  });

  it('never calls an unimported period "no scrobbles"', async () => {
    const unknown = makeOverview({ stats: { ...makeOverview().stats, scrobbles: 0 }, coverage: { status: 'none', missing: [{ from: '2003-01-01', to: '2003-12-31', startsAt: '2003-01-01T00:00:00Z', endsAt: '2004-01-01T00:00:00Z', partialFrom: false, partialTo: false }] } });
    renderApp(connectedApi(() => unknown), '/overview?period=year:2003');
    expect(await screen.findByText('Scrobbles for 2003 have not been imported.')).toBeInTheDocument();
    expect(screen.queryByText('No scrobbles in 2003.')).not.toBeInTheDocument();
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

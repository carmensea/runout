import { act, renderHook, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiError, NotAvailableError, ReviewChangedError, type RunoutApi } from '../../data/api';
import type { ImportStatus, ReviewItem, ReviewQueue } from '../../data/types';
import { usePolling } from '../../hooks/usePolling';
import { connectedApi, fakeHistoryApi, fakeSourcesApi, makeImportStatus, makeSources, makeSyncHealth } from '../../test/fixtures';
import { location, renderApp } from '../../test/renderApp';

beforeEach(() => localStorage.clear());

function api(history: ReturnType<typeof fakeHistoryApi>, connection: Awaited<ReturnType<RunoutApi['getConnection']>> | null = null): RunoutApi {
  return {
    ...connectedApi(),
    ...(connection ? { getConnection: async () => connection } : {}),
    history,
  };
}

const removal: ReviewItem = {
  kind: 'removal', id: 7, version: 'v1', playedAt: '2014-03-15T20:00:00Z', history: [],
  play: { id: 70, seq: 0, artist: 'Test Artist', track: 'Gone Track', album: 'Test Album' }, removedAt: null,
  firstMissingAt: '2026-10-20T10:00:00Z', confirmedMissingAt: '2026-10-21T10:00:00Z',
};

const dispute: ReviewItem = {
  kind: 'dispute', id: 9, version: 'v9', playedAt: '2014-04-02T09:00:00Z', history: [],
  stored: [{ id: 90, seq: 0, artist: 'Test Artist', track: 'Old Name', album: null }],
  fetched: [{ index: 0, artist: 'Test Artist', track: 'New Name', album: null }],
  firstSeenAt: '2026-10-20T10:00:00Z', lastSeenAt: '2026-10-21T10:00:00Z',
};

const queue = (items: ReviewItem[], waiting = 0): ReviewQueue => ({ items, total: items.length, offset: 0, waiting });

describe('Settings: import', () => {
  it('starts the import once, then shows its progress in plain words', async () => {
    const user = userEvent.setup();
    let status: ImportStatus = makeImportStatus({ state: 'not_started', complete: false, canStart: true, percent: null, importedScrobbles: 0 });
    const history = fakeHistoryApi({
      importStatus: async () => status,
      syncHealth: async () => makeSyncHealth({ importComplete: false, connectionState: 'not_started' }),
      startImport: async () => {
        history.calls.push('startImport');
        status = makeImportStatus({
          state: 'running', complete: false, activity: 'importing', percent: 42, importedScrobbles: 1234, lastfmPlaycount: 3000,
          currentPeriod: { from: '2014-03-01T00:00:00Z', to: '2014-04-01T00:00:00Z' }, canStart: false,
        });
      },
    });
    renderApp(api(history), '/settings#history');
    const start = await screen.findByRole('button', { name: 'Start import' });
    await user.dblClick(start);
    expect(await screen.findByText('Importing your history')).toBeInTheDocument();
    expect(history.calls.filter((c) => c === 'startImport')).toHaveLength(1);
    expect(screen.getByRole('progressbar', { name: 'Import progress' })).toHaveAttribute('aria-valuenow', '42');
    expect(screen.getByText(/1,234 scrobbles of about 3,000 on Last.fm/)).toBeInTheDocument();
    // A UTC month in London time: March ends at 01:00 BST on 1 April.
    expect(screen.getByText('2014-03-01 to 2014-04-01 01:00')).toBeInTheDocument();
  });

  it('explains that storage is off, and offers no start', async () => {
    const history = fakeHistoryApi({
      importStatus: async () => makeImportStatus({ enabled: false, state: 'not_started', complete: false, canStart: false }),
      syncHealth: async () => makeSyncHealth({ enabled: false, importComplete: false, connectionState: 'not_started' }),
    });
    renderApp(api(history), '/settings#history');
    expect(await screen.findByText(/History storage is switched off on this server, so nothing can be imported yet/)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Start import' })).not.toBeInTheDocument();
  });

  it('pauses, and cancels only after confirmation', async () => {
    const user = userEvent.setup();
    const history = fakeHistoryApi({
      importStatus: async () => makeImportStatus({ state: 'running', complete: false, activity: 'importing', percent: 10 }),
      syncHealth: async () => makeSyncHealth({ importComplete: false }),
    });
    renderApp(api(history), '/settings#history');
    await user.click(await screen.findByRole('button', { name: 'Pause import' }));
    await waitFor(() => expect(history.calls).toContain('pauseImport'));

    await user.click(screen.getByRole('button', { name: 'Cancel import' }));
    const confirm = screen.getByRole('group', { name: 'Confirm cancelling the import' });
    expect(confirm).toHaveTextContent('Scrobbles imported so far are kept');
    await user.click(within(confirm).getByRole('button', { name: 'Keep importing' }));
    expect(history.calls).not.toContain('cancelImport');

    await user.click(screen.getByRole('button', { name: 'Cancel import' }));
    await user.click(screen.getByRole('button', { name: 'Yes, cancel the import' }));
    await waitFor(() => expect(history.calls).toContain('cancelImport'));
  });
});

describe('Settings: history without Last.fm', () => {
  it('shows what is stored and no Last.fm controls', async () => {
    const history = fakeHistoryApi({ importStatus: async () => makeImportStatus({ stored: { plays: 2, firstPlayedAt: '2026-01-02T03:00:00Z', lastPlayedAt: '2026-01-02T04:00:00Z', sources: { spotify: 2 } } }) });
    const connection = { status: 'none' as const, displayName: 'bob', timezone: 'Europe/London' };
    renderApp(api(history, connection), '/settings#history');
    const panel = await screen.findByRole('region', { name: 'Stored plays' });
    expect(panel).toHaveTextContent('Spotify 2');
    expect(screen.queryByRole('region', { name: 'Import from Last.fm' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Check now' })).not.toBeInTheDocument();
  });

  it('says so when nothing is stored yet', async () => {
    const history = fakeHistoryApi({ importStatus: async () => makeImportStatus({ stored: { plays: 0, firstPlayedAt: null, lastPlayedAt: null, sources: {} } }) });
    renderApp(api(history, { status: 'none' as const, displayName: 'bob', timezone: 'Europe/London' }), '/settings#history');
    expect(await screen.findByText(/Nothing is stored yet/)).toBeInTheDocument();
  });
});

describe('Settings: deletion notice', () => {
  it('speaks of Spotify, not Last.fm, for an account that only connected Spotify', async () => {
    const user = userEvent.setup();
    let signedIn = true;
    const api: RunoutApi = {
      ...connectedApi(),
      getConnection: async () => (signedIn ? { status: 'none', displayName: 'Dana', timezone: 'Europe/London' } : { status: 'signed_out' }),
      deleteAccount: async () => {
        signedIn = false;
        return { revokeAccessUrl: null, spotifyAppsUrl: 'https://www.spotify.com/account/apps/' };
      },
    };
    renderApp(api, '/settings#account');
    await user.type(await screen.findByLabelText(/Type your name/), 'Dana');
    await user.click(screen.getByRole('button', { name: 'Delete account' }));
    expect(await screen.findByText('Your Runout account and its data were deleted.')).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Manage apps' })).toHaveAttribute('href', 'https://www.spotify.com/account/apps/');
    expect(screen.queryByRole('link', { name: 'Last.fm application settings' })).not.toBeInTheDocument();
    expect(screen.getByText(/daily ones for 30 days, monthly ones for 12 months/)).toBeInTheDocument();
  });
});

describe('Settings: sync', () => {
  it('pauses automatic sync, and says when a manual check is too soon', async () => {
    const user = userEvent.setup();
    let paused = false;
    const history = fakeHistoryApi({
      syncHealth: async () => makeSyncHealth({ syncPaused: paused, activity: paused ? 'sync_paused' : 'idle' }),
      pauseSync: async () => {
        history.calls.push('pauseSync');
        paused = true;
      },
      refreshSync: async () => {
        throw new ApiError(429, 'too soon', 'too_soon', { retryAfter: '2026-10-29T09:35:00Z' });
      },
    });
    renderApp(api(history), '/settings#history');
    expect(await screen.findByText('12 in the last 24 hours')).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Check now' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('Checked moments ago. You can check again at 09:35.');

    await user.click(screen.getByRole('button', { name: 'Pause automatic sync' }));
    expect(await screen.findByRole('button', { name: 'Resume automatic sync' })).toBeInTheDocument();
    expect(screen.getByText(/nothing was cancelled or deleted/)).toBeInTheDocument();
  });

  it('offers no check or pause while history storage is off', async () => {
    const history = fakeHistoryApi({ syncHealth: async () => makeSyncHealth({ enabled: false }) });
    renderApp(api(history), '/settings#history');
    expect(await screen.findByText(/History storage is switched off on this server, so nothing is checked/)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Check now' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Pause automatic sync' })).not.toBeInTheDocument();
  });

  it('lists missing and stopped periods; only those needing a person offer Try again', async () => {
    const user = userEvent.setup();
    const history = fakeHistoryApi({
      syncHealth: async () => makeSyncHealth({
        missingPeriods: [{ from: '2026-11-05T10:00:00Z', to: '2026-11-05T11:00:00Z', state: 'needs_review', reason: 'undated_rows', message: '1 plays without a date' }],
        problemPeriods: [
          { id: 5, from: '2026-11-05T10:00:00Z', to: '2026-11-05T11:00:00Z', status: 'check_stopped', imported: false, reason: 'undated_rows',
            message: '1 plays without a date', retriesAutomatically: false, attempts: 1, httpStatus: null, lastfmError: null },
          { id: 6, from: '2026-10-01T00:00:00Z', to: '2026-11-01T00:00:00Z', status: 'check_stopped', imported: true, reason: 'gave_up',
            message: 'Last.fm returned HTTP 502', retriesAutomatically: true, attempts: 5, httpStatus: 502, lastfmError: null },
        ],
      }),
    });
    renderApp(api(history), '/settings#history');
    expect(await screen.findByText(/One period has no imported scrobbles. Charts treat it as incomplete/)).toBeInTheDocument();
    expect(screen.getByText('Last.fm returned plays without a date, so this period was not saved.')).toBeInTheDocument();
    expect(screen.getByText('Will try again automatically')).toBeInTheDocument();
    // The UTC month in London time: from 01:00 BST on 1 October to midnight GMT, after the clocks go back.
    expect(screen.getByText('2026-10-01 01:00 to 2026-10-31')).toBeInTheDocument();
    expect(screen.getByText('Its scrobbles imported earlier are kept and still count.')).toBeInTheDocument();
    const retries = screen.getAllByRole('button', { name: 'Try again' });
    expect(retries).toHaveLength(1);
    await user.click(retries[0]!);
    await waitFor(() => expect(history.calls).toContain('retryPeriod:5'));
  });
});

describe('Settings: review', () => {
  it('shows what Runout has and what Last.fm says, and removes only after confirmation, once', async () => {
    const user = userEvent.setup();
    let items = [removal];
    const history = fakeHistoryApi({
      reviews: async () => queue(items, 2),
      decide: async (item, decision, options) => {
        history.calls.push(`decide:${item.id}:${decision}:${options?.confirm}`);
        items = [];
        return { result: 'approved', item: null };
      },
    });
    renderApp(api(history), '/settings#review');
    const card = await screen.findByRole('article', { name: /Missing from Last.fm/ });
    expect(within(card).getByText('Gone Track')).toBeInTheDocument();
    expect(within(card).getByText('Not found in two separate checks')).toBeInTheDocument();
    expect(screen.getByText(/2 scrobbles were missing from Last.fm once/)).toBeInTheDocument();

    await user.click(within(card).getByRole('button', { name: 'Remove from history' }));
    expect(history.calls).toHaveLength(0);
    expect(screen.getByRole('group', { name: 'Confirm decision' })).toHaveTextContent('hidden, not deleted, and can be restored');
    await user.dblClick(screen.getByRole('button', { name: 'Confirm removal' }));
    await waitFor(() => expect(screen.getByText('Nothing to review.', { exact: false })).toBeInTheDocument());
    expect(history.calls).toEqual(['decide:7:approve:true']);
  });

  it('keeps a scrobble without confirmation: nothing is removed', async () => {
    const user = userEvent.setup();
    const history = fakeHistoryApi({ reviews: async () => queue([removal]) });
    renderApp(api(history), '/settings#review');
    await user.click(await screen.findByRole('button', { name: 'Keep it' }));
    await waitFor(() => expect(history.calls).toEqual(['decide:removal:7:dismiss:{}']));
  });

  it('shows an item that changed while open as it is now, deciding nothing', async () => {
    const user = userEvent.setup();
    let version = 'v1';
    const history = fakeHistoryApi({
      reviews: async () => queue([{ ...removal, version }]),
      decide: async () => {
        version = 'v2';
        throw new ReviewChangedError({ ...removal, version: 'v2' });
      },
    });
    renderApp(api(history), '/settings#review');
    await user.click(await screen.findByRole('button', { name: 'Keep it' }));
    expect(await screen.findByText(/This item changed while it was open, so nothing was decided/)).toBeInTheDocument();
    expect(screen.getByRole('article', { name: /Missing from Last.fm/ })).toBeInTheDocument();
  });

  it('pairs a correction explicitly, previews the outcome, and applies it with confirmation', async () => {
    const user = userEvent.setup();
    const history = fakeHistoryApi({ reviews: async () => queue([dispute]) });
    renderApp(api(history), '/settings#review');
    const card = await screen.findByRole('article', { name: /Different on Last.fm/ });
    expect(within(card).getByText(/“Old Name” stays, and is checked again/)).toBeInTheDocument();
    expect(within(card).getByText(/“New Name” \(Test Artist\) is added as a new scrobble/)).toBeInTheDocument();

    await user.selectOptions(within(card).getByLabelText('Same scrobble on Last.fm'), '0');
    expect(within(card).getByText('“Old Name” is renamed to “New Name” (Test Artist).')).toBeInTheDocument();
    await user.click(within(card).getByRole('button', { name: 'Apply' }));
    await user.click(screen.getByRole('button', { name: 'Confirm changes' }));
    await waitFor(() => expect(history.calls).toEqual(['decide:dispute:9:resolve:{"confirm":true,"pairs":[[90,0]]}']));
  });
});

describe('Settings: ListenBrainz', () => {
  it('connects with a token that is checked once and never shown, then disconnects keeping plays', async () => {
    const user = userEvent.setup();
    const sources = fakeSourcesApi();
    renderApp({ ...connectedApi(), sources }, '/settings#sources');
    const panel = await screen.findByRole('region', { name: 'ListenBrainz' });
    expect(panel).toHaveTextContent('Your ListenBrainz listening history is public');
    const input = within(panel).getByLabelText('ListenBrainz user token');
    expect(input).toHaveAttribute('type', 'password');
    expect(within(panel).getByRole('button', { name: 'Connect ListenBrainz' })).toBeDisabled();
    await user.type(input, ' lb-token ');
    await user.click(within(panel).getByRole('button', { name: 'Connect ListenBrainz' }));
    expect(sources.calls).toContain('connectListenbrainz:lb-token');
    await waitFor(() => expect(panel).toHaveTextContent('dana_lb'));
    expect(panel).not.toHaveTextContent('lb-token');
    await user.click(within(panel).getByRole('button', { name: 'Disconnect ListenBrainz' }));
    expect(within(panel).getByText(/Plays already stored stay/)).toBeInTheDocument();
    await user.click(within(panel).getByRole('button', { name: 'Disconnect' }));
    expect(sources.calls).toContain('disconnectListenbrainz');
    await waitFor(() => expect(panel).toHaveTextContent('Disconnected'));
    expect(within(panel).getByRole('button', { name: 'Connect ListenBrainz again' })).toBeInTheDocument();
  });

  it('explains a refused token and an account already taken', async () => {
    const user = userEvent.setup();
    const sources = fakeSourcesApi();
    sources.connectListenbrainz = async (token) => {
      throw new ApiError(token === 'taken' ? 409 : 422, 'refused', token === 'taken' ? 'account_taken' : 'invalid_token');
    };
    renderApp({ ...connectedApi(), sources }, '/settings#sources');
    const panel = await screen.findByRole('region', { name: 'ListenBrainz' });
    await user.type(within(panel).getByLabelText('ListenBrainz user token'), 'nope');
    await user.click(within(panel).getByRole('button', { name: 'Connect ListenBrainz' }));
    expect(await within(panel).findByRole('alert')).toHaveTextContent('didn’t recognise that token');
    await user.clear(within(panel).getByLabelText('ListenBrainz user token'));
    await user.type(within(panel).getByLabelText('ListenBrainz user token'), 'taken');
    await user.click(within(panel).getByRole('button', { name: 'Connect ListenBrainz' }));
    expect(await within(panel).findByRole('alert')).toHaveTextContent('already connected to another Runout account');
  });

  it('shows sync health and the full-history import, and lets a renamed account be connected again', async () => {
    const user = userEvent.setup();
    const connected = {
      enabled: true, state: 'connected' as const, account: { id: 'dana_lb', displayName: 'dana_lb' }, connectedAt: '2026-11-06T10:00:00Z',
      lastPollAt: '2026-11-06T12:10:00Z', lastSuccessAt: '2026-11-06T12:10:00Z', lastNewPlayAt: '2026-11-06T12:10:00Z', playsAdded: 42,
      coveredFrom: '2026-10-07T10:00:00Z', pollSchedule: 'every 10 minutes', backfill: null,
      recentPolls: [{ startedAt: '2026-11-06T12:10:00Z', trigger: 'schedule' as const, outcome: 'ok' as const, items: 12, added: 3, linked: 1, held: 0, error: null }],
    };
    const sources = fakeSourcesApi({ ...makeSources(), listenbrainz: connected });
    renderApp({ ...connectedApi(), sources }, '/settings#sources');
    const panel = await screen.findByRole('region', { name: 'ListenBrainz' });
    expect(panel).toHaveTextContent('On, every 10 minutes');
    expect(panel).toHaveTextContent('42 added in all');
    expect(panel).toHaveTextContent('Not imported yet: only the last 30 days so far');
    expect(within(panel).queryByLabelText('ListenBrainz user token')).not.toBeInTheDocument();
    await user.click(within(panel).getByText('Getting your plays into ListenBrainz'));
    expect(panel).toHaveTextContent('Pano Scrobbler');
    expect(panel).toHaveTextContent('Web Scrobbler');
    expect(panel).toHaveTextContent('hasn’t yet checked this route');
    await user.click(within(panel).getByRole('button', { name: 'Import your full history' }));
    expect(sources.calls).toContain('backfillListenbrainz');
    await waitFor(() => expect(panel).toHaveTextContent('Importing: 0 plays read of about 12,000'));
    expect(within(panel).getByRole('button', { name: 'Continue the full import' })).toBeInTheDocument();
    expect(within(panel).getByRole('status')).toHaveTextContent('Reading ListenBrainz now');
  });

  it('lets a renamed or vanished account be connected again with a new token', async () => {
    const user = userEvent.setup();
    const renamed = fakeSourcesApi({ ...makeSources(), listenbrainz: { enabled: true, state: 'needs_reauth', account: { id: 'dana_lb', displayName: 'dana_lb' }, connectedAt: '2026-11-06T10:00:00Z', lastError: 'no such user' } });
    renderApp({ ...connectedApi(), sources: renamed }, '/settings#sources');
    const panel = await screen.findByRole('region', { name: 'ListenBrainz' });
    expect(panel).toHaveTextContent('no longer has an account by that name');
    await user.type(within(panel).getByLabelText('ListenBrainz user token'), 'new-token');
    await user.click(within(panel).getByRole('button', { name: 'Connect ListenBrainz again' }));
    expect(renamed.calls).toContain('connectListenbrainz:new-token');
  });

  it('is absent while the server has ListenBrainz switched off', async () => {
    const sources = fakeSourcesApi({ ...makeSources(), listenbrainz: { enabled: false, state: 'not_connected', account: null } });
    renderApp({ ...connectedApi(), sources }, '/settings#sources');
    await screen.findByRole('region', { name: 'Listening sources' });
    expect(screen.queryByRole('region', { name: 'ListenBrainz' })).not.toBeInTheDocument();
  });
});

describe('Settings: tabs', () => {
  it('opens the tab the hash names, keeps it when the period is written, and puts the chosen tab in the hash', async () => {
    const user = userEvent.setup();
    const base = { status: 'synced' as const, displayName: 'test-user', username: 'test-user', timezone: 'Europe/London', lastSyncedAt: '2026-10-29T09:00:00Z' };
    renderApp(api(fakeHistoryApi(), { ...base, attention: 3 }), '/settings#lastfm');
    expect(await screen.findByRole('tab', { name: 'Account', selected: true })).toBeInTheDocument();
    expect(screen.getByRole('region', { name: 'Account' })).toBeInTheDocument();
    expect(screen.queryByRole('region', { name: 'Listening sources' })).not.toBeInTheDocument();
    await waitFor(() => expect(location.current).toBe('/settings?period=all#lastfm'));
    await user.click(screen.getByRole('tab', { name: 'History' }));
    expect(await screen.findByRole('region', { name: 'To review' })).toBeInTheDocument();
    expect(location.current).toBe('/settings?period=all#history');
  });
});

describe('Banner and Overview', () => {
  it('shows the attention count and links to review; nothing when there is nothing to do', async () => {
    const base = { status: 'synced' as const, displayName: 'test-user', username: 'test-user', timezone: 'Europe/London', lastSyncedAt: '2026-10-29T09:00:00Z' };
    const { unmount } = renderApp(api(fakeHistoryApi(), { ...base, attention: 3 }));
    expect(await screen.findByText(/3 items in your history need your attention/)).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Review in Settings' })).toHaveAttribute('href', expect.stringContaining('/settings#review'));
    unmount();
    renderApp(api(fakeHistoryApi(), { ...base, attention: 0 }));
    await screen.findAllByText('Last.fm connected');
    expect(screen.queryByText(/need your attention/)).not.toBeInTheDocument();
  });

  it('says charts arrive in the next version when the server has none yet', async () => {
    renderApp({ ...connectedApi(), getOverview: async () => { throw new NotAvailableError(); } });
    expect(await screen.findByText('Your history is stored in Runout. Charts arrive in the next version.')).toBeInTheDocument();
  });
});

describe('usePolling', () => {
  afterEach(() => {
    vi.useRealTimers();
    Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'visible' });
  });

  it('paces itself from the data, and makes no requests while the tab is hidden', async () => {
    vi.useFakeTimers();
    let loads = 0;
    const load = async () => ++loads;
    renderHook(() => usePolling(load, (n) => (n !== null && n < 3 ? 1_000 : 60_000)));
    await act(async () => { await vi.advanceTimersByTimeAsync(0); });
    expect(loads).toBe(1);
    for (let i = 0; i < 2; i += 1) {
      await act(async () => { await vi.advanceTimersByTimeAsync(1_000); });
    }
    expect(loads).toBe(3); // fast while "busy"
    await act(async () => { await vi.advanceTimersByTimeAsync(5_000); });
    expect(loads).toBe(3); // slow once idle

    Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'hidden' });
    act(() => { document.dispatchEvent(new Event('visibilitychange')); });
    await act(async () => { await vi.advanceTimersByTimeAsync(120_000); });
    expect(loads).toBe(3);
    Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'visible' });
    await act(async () => {
      document.dispatchEvent(new Event('visibilitychange'));
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(loads).toBe(4); // at once when visible again
  });
});

describe('Settings: listening sources', () => {
  it('shows Last.fm as the archive and offers to connect Spotify', async () => {
    renderApp(connectedApi(), '/settings');
    const section = await screen.findByRole('region', { name: 'Listening sources' });
    expect(await within(section).findByText('Historical archive')).toBeInTheDocument();
    expect(within(section).getByText('test-user')).toBeInTheDocument();
    expect(within(section).getByRole('link', { name: 'Connect Spotify' })).toHaveAttribute('href', '/api/auth/spotify');
  });

  it('shows the connected account, says scrobbling is off, and disconnects only after confirming', async () => {
    const user = userEvent.setup();
    const sources = fakeSourcesApi(makeSources({ state: 'connected', account: { id: 'spotify-user', displayName: 'Listener' }, connectedAt: '2026-10-31T12:00:00Z' }));
    renderApp({ ...connectedApi(), sources }, '/settings?spotify=connected#sources');
    const section = await screen.findByRole('region', { name: 'Listening sources' });
    expect(await within(section).findByText('Listener (spotify-user)')).toBeInTheDocument();
    expect(within(section).getByText('Spotify is connected.')).toBeInTheDocument();
    expect(within(section).getByText('Off: Runout isn’t storing plays from Spotify yet')).toBeInTheDocument();
    expect(within(section).queryByRole('link', { name: /Connect Spotify/ })).not.toBeInTheDocument();

    await user.click(within(section).getByRole('button', { name: 'Disconnect Spotify' }));
    expect(sources.calls).toEqual([]);
    await user.click(within(section).getByRole('button', { name: 'Disconnect' }));
    await waitFor(() => expect(sources.calls).toEqual(['disconnect']));
    expect(await within(section).findByRole('link', { name: 'Connect Spotify again' })).toBeInTheDocument();
  });

  it('explains a failed connection and an account that must be connected again', async () => {
    const sources = fakeSourcesApi(makeSources({ state: 'needs_reauth', account: { id: 'x', displayName: 'x' }, lastError: 'Spotify refused the authorisation (invalid_grant)' }));
    renderApp({ ...connectedApi(), sources }, '/settings?spotify_error=denied#sources');
    const section = await screen.findByRole('region', { name: 'Listening sources' });
    expect(await within(section).findByRole('alert')).toHaveTextContent('Spotify access wasn’t granted, so nothing was connected.');
    expect(within(section).getByText(/Spotify stopped accepting Runout’s access \(Spotify refused the authorisation \(invalid_grant\)\)/)).toBeInTheDocument();
    expect(within(section).getByRole('link', { name: 'Connect Spotify again' })).toBeInTheDocument();
  });

  it('shows ingestion status, syncs, pauses and resumes, and says when plays may be missing', async () => {
    const user = userEvent.setup();
    const sources = fakeSourcesApi(makeSources({
      state: 'connected', ingestionEnabled: true, paused: false, pollSchedule: 'every 5 minutes',
      account: { id: 'spotify-user', displayName: 'Listener' }, connectedAt: '2026-10-31T12:00:00Z',
      lastPollAt: '2026-11-02T12:00:00Z', lastSuccessAt: '2026-11-02T12:00:00Z', lastNewPlayAt: '2026-11-02T11:55:00Z', playsAdded: 42,
      coveredFrom: '2026-11-01T08:00:00Z', pendingReview: 0,
      gaps: [{ from: '2026-11-01T20:00:00Z', to: '2026-11-02T09:00:00Z', detectedAt: '2026-11-02T09:05:00Z' }],
      recentPolls: [{ startedAt: '2026-11-02T12:00:00Z', trigger: 'schedule', outcome: 'ok', items: 50, added: 3, linked: 1, held: 0, error: null }],
    }));
    renderApp({ ...connectedApi(), sources }, '/settings');
    const section = await screen.findByRole('region', { name: 'Listening sources' });
    expect(await within(section).findByText('On, every 5 minutes')).toBeInTheDocument();
    expect(within(section).getByText(/42 added in all/)).toBeInTheDocument();
    expect(within(section).getByText('Plays may be missing')).toBeInTheDocument();
    expect(within(section).getByText(/50 recent plays read: 3 new, 1 already in your archive/)).toBeInTheDocument();

    await user.click(within(section).getByRole('button', { name: 'Sync now' }));
    expect(await within(section).findByText('Checking Spotify now. New plays appear within a minute.')).toBeInTheDocument();
    await user.click(within(section).getByRole('button', { name: 'Pause' }));
    expect(await within(section).findByText('Paused')).toBeInTheDocument();
    await user.click(within(section).getByRole('button', { name: 'Resume' }));
    await waitFor(() => expect(sources.calls).toEqual(['sync', 'pause', 'resume']));
  });

  it('lists plays held for review and records the owner’s decision', async () => {
    const user = userEvent.setup();
    const item = {
      id: 5, provider: 'spotify' as const, reportedAt: '2026-11-02T12:03:20.000Z', durationMs: 200000, reason: 'several_same_plays',
      play: { artist: 'Test Band', track: 'Test Song', album: null },
      candidates: [
        { scrobbleId: 11, source: 'lastfm' as const, playedAt: '2026-11-02T12:00:00Z', identity: 'same' as const, present: true, artist: 'Test Band', track: 'Test Song', album: null },
        { scrobbleId: 12, source: 'lastfm' as const, playedAt: '2026-11-02T12:00:20Z', identity: 'same' as const, present: true, artist: 'Test Band', track: 'Test Song', album: null },
      ],
    };
    const sources = fakeSourcesApi(makeSources({ state: 'connected', ingestionEnabled: true, account: { id: 'x', displayName: 'x' }, pendingReview: 1 }), [item]);
    renderApp({ ...connectedApi(), sources }, '/settings');
    const panel = await screen.findByRole('region', { name: 'Spotify plays to check' });
    expect(await within(panel).findByText('Test Band – Test Song')).toBeInTheDocument();
    expect(within(panel).getAllByRole('button', { name: 'Same play' })).toHaveLength(2);
    await user.click(within(panel).getAllByRole('button', { name: 'Same play' })[0]!);
    await waitFor(() => expect(sources.calls).toEqual(['decide:5:11']));
    await waitFor(() => expect(screen.queryByRole('region', { name: 'Spotify plays to check' })).not.toBeInTheDocument());
  });
});

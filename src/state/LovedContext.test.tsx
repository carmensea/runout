import { screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it } from 'vitest';
import type { RunoutApi } from '../data/api';
import type { Play, PlaysPage } from '../data/types';
import { connectedApi, makeLoved, makeLovedLibrary, makeOverview } from '../test/fixtures';
import { renderApp } from '../test/renderApp';

/** Hearts follow the identity key: `t1` is loved everywhere, `t2` nowhere. */
function api(overrides: Partial<RunoutApi> = {}): RunoutApi {
  const base = makeOverview();
  const entry = (id: string, name: string, scrobbles: number) => ({ ...base.top.artists[0]!, id, name, artist: 'The Band', tracksPlayed: null, scrobbles });
  return {
    ...connectedApi(() => ({
      ...base,
      top: { ...base.top, tracks: [entry('t1', 'Loved Song', 20), entry('t2', 'Plain Song', 10)] },
      onRepeat: [{ trackId: 't1', name: 'Loved Song', artist: 'The Band', plays: 9, date: '2014-03-15' }, { trackId: 't2', name: 'Plain Song', artist: 'The Band', plays: 4, date: '2014-03-16' }],
    })),
    getLovedTracks: async () => makeLovedLibrary([makeLoved(1, { track: { id: 't1', name: 'Loved Song' } })]),
    search: async () => ({ artists: [], albums: [], tracks: [{ id: 't1', name: 'Loved Song', artist: 'The Band' }, { id: 't2', name: 'Plain Song', artist: 'The Band' }] }),
    ...overrides,
  };
}

describe('hearts beside loved tracks', () => {
  it('appear in the Overview’s top tracks and On repeat, only for loved identities', async () => {
    const user = userEvent.setup();
    renderApp(api(), '/overview?period=year:2014');
    await screen.findByText('On repeat');
    const loved = screen.getByRole('link', { name: /Loved Song/ });
    const plain = screen.getByRole('link', { name: /Plain Song/ });
    expect(await within(loved).findByRole('img', { name: 'Loved' })).toBeInTheDocument();
    expect(within(plain).queryByRole('img', { name: 'Loved' })).toBeNull();

    await user.click(screen.getByRole('tab', { name: 'Tracks' }));
    const panel = screen.getByRole('tabpanel');
    expect(within(within(panel).getByRole('link', { name: /Loved Song/ })).getByRole('img', { name: 'Loved' })).toBeInTheDocument();
    expect(within(within(panel).getByRole('link', { name: /Plain Song/ })).queryByRole('img', { name: 'Loved' })).toBeNull();
  });

  it('appear in search results', async () => {
    const user = userEvent.setup();
    renderApp(api(), '/overview?period=all');
    await screen.findByRole('heading', { level: 1 });
    await user.type(screen.getByRole('combobox'), 'song');
    const options = await within(screen.getByRole('listbox', { name: 'Search results' })).findAllByRole('option');
    await waitFor(() => expect(within(options[0]!).getByRole('img', { name: 'Loved' })).toBeInTheDocument());
    expect(within(options[1]!).queryByRole('img', { name: 'Loved' })).toBeNull();
  });

  it('appear in the Time Machine play log', async () => {
    const play = (n: number, id: string, track: string): Play => ({
      id: `2016-03-15T08:0${n}:00/0`, playedAt: `2016-03-15T08:0${n}:00.000000Z`, date: '2016-03-15', time: `08:0${n}:00`,
      artist: { id: 'a1', name: 'The Band' }, track: { id, name: track }, album: null,
    });
    const page: PlaysPage = { period: 'day:2016-03-15', total: 2, plays: [play(1, 't1', 'Loved Song'), play(2, 't2', 'Plain Song')], nextCursor: null, coverage: { status: 'complete', missing: [] } };
    renderApp(api({
      getCalendar: async () => ({ firstDay: '2016-03-15', lastDay: '2016-03-15', years: [{ key: '2016', scrobbles: 2 }], months: [{ key: '2016-03', scrobbles: 2 }], coverage: { status: 'complete', missing: [] } }),
      getCalendarDays: async (from, to) => ({ from, to, days: [{ date: '2016-03-15', scrobbles: 2 }], coverage: { status: 'complete', missing: [] } }),
      getPlays: async () => page,
    }), '/time-machine?at=2016-03-15&period=day:2016-03-15');
    const loved = (await screen.findByText('Loved Song')).closest('li')!;
    expect(await within(loved).findByRole('img', { name: 'Loved' })).toBeInTheDocument();
    expect(within(screen.getByText('Plain Song').closest('li')!).queryByRole('img', { name: 'Loved' })).toBeNull();
  });
});

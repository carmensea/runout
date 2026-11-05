import { screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it } from 'vitest';
import { NotConnectedError, type RunoutApi } from '../../data/api';
import type { LovedTrack } from '../../data/types';
import { connectedApi, makeLoved, makeLovedLibrary } from '../../test/fixtures';
import { location, renderApp } from '../../test/renderApp';

const daysAgo = (n: number) => new Date(Date.now() - n * 86_400_000).toISOString();
const dateOf = (iso: string) => iso.slice(0, 10);

/** Four loved songs covering the insights: oldest, most played, not heard in years, back in rotation. */
function library(): LovedTrack[] {
  const recent = daysAgo(10);
  return [
    makeLoved(1, { lovedAt: '2009-07-25T10:00:00Z', track: { id: 't1', name: 'Old Flame' }, artist: { id: 'a1', name: 'Alpha Band' }, asLoved: { artist: 'Alpha Band', track: 'Old Flame' },
      plays: 300, lastPlayedAt: recent, lastPlayedDate: dateOf(recent), previousPlayedAt: '2019-01-01T00:00:00Z', namePlays: 300 }),
    makeLoved(2, { lovedAt: '2015-02-01T10:00:00Z', track: { id: 't2', name: 'Left Behind' }, artist: { id: 'a2', name: 'Beta Band' }, asLoved: { artist: 'Beta Band', track: 'Left Behind' },
      plays: 12, lastPlayedAt: '2018-05-05T00:00:00Z', lastPlayedDate: '2018-05-05', previousPlayedAt: '2017-01-01T00:00:00Z', namePlays: 12 }),
    makeLoved(3, { lovedAt: '2015-09-09T10:00:00Z', track: { id: 't3', name: 'Other Recording' }, artist: { id: 'a3', name: 'Gamma' }, asLoved: { artist: 'Gamma', track: 'Other Recording' },
      plays: 0, firstPlayedAt: null, lastPlayedAt: null, lastPlayedDate: null, previousPlayedAt: null, namePlays: 40 }),
    makeLoved(4, { lovedAt: '2024-01-01T10:00:00Z', track: { id: 't4', name: 'Unheard' }, artist: { id: 'a1', name: 'Alpha Band' }, asLoved: { artist: 'Alpha  Band', track: 'Unheard' },
      link: 'review', plays: 0, firstPlayedAt: null, lastPlayedAt: null, lastPlayedDate: null, previousPlayedAt: null, namePlays: 0 }),
  ];
}

function api(tracks: LovedTrack[] = library(), overrides: Partial<RunoutApi> = {}): RunoutApi {
  return { ...connectedApi(), getLovedTracks: async () => makeLovedLibrary(tracks), ...overrides };
}

describe('Loved songs page', () => {
  beforeEach(() => localStorage.clear());

  it('shows the figures with their dates labelled as loved or listened', async () => {
    renderApp(api(), '/loved');
    expect(await screen.findByRole('heading', { level: 1, name: 'Loved songs' })).toBeInTheDocument();
    const stats = (await screen.findByText('Loved songs', { selector: 'dt' })).closest('dl')!;
    expect(within(stats).getByText('4')).toBeInTheDocument();
    expect(within(stats).getByText(/loved between 2009-07-25 and 2024-01-01/)).toBeInTheDocument();
    expect(within(stats).getByText('With listening').nextElementSibling).toHaveTextContent('2');
    expect(within(stats).getByText(/1 have plays under another recording of the same name, 1 were never played/)).toBeInTheDocument();
    expect(within(stats).getByText('Loved most in').nextElementSibling).toHaveTextContent('2015');
  });

  it('lists the insights: oldest, most played, not heard in years and back in rotation', async () => {
    renderApp(api(), '/loved');
    const oldest = await screen.findByRole('list', { name: 'Oldest loved songs' });
    expect(within(oldest).getAllByRole('listitem')[0]).toHaveTextContent('Old Flame');
    expect(within(oldest).getAllByRole('listitem')[0]).toHaveTextContent('Loved on 2009-07-25 · 300 plays');
    expect(within(oldest).getAllByRole('listitem')[2]).toHaveTextContent('40 plays under another recording');
    expect(within(oldest).getAllByRole('listitem')[3]).toHaveTextContent('no plays found');

    const most = screen.getByRole('list', { name: 'Most played loved songs' });
    expect(within(most).getAllByRole('listitem').map((li) => li.textContent)).toEqual([expect.stringContaining('Old Flame'), expect.stringContaining('Left Behind')]);

    const left = screen.getByRole('list', { name: 'Loved songs not heard in years' });
    expect(within(left).getAllByRole('listitem')).toHaveLength(1);
    expect(within(left).getByRole('listitem')).toHaveTextContent('Left Behind');
    expect(within(left).getByRole('listitem')).toHaveTextContent('Last listened 2018-05-05 · 12 plays · loved on 2015-02-01');
    expect(within(left).getByRole('link', { name: 'Left Behind' })).toHaveAttribute('href', '/time-machine?at=2018-05-05&period=day%3A2018-05-05');

    const back = screen.getByRole('list', { name: 'Loved songs back in rotation' });
    expect(within(back).getByRole('listitem')).toHaveTextContent('Old Flame');
    expect(within(back).getByRole('listitem')).toHaveTextContent(/Away \d yr · back/);
  });

  it('searches, filters by artist and year, sorts, and marks what is held for review', async () => {
    const user = userEvent.setup();
    renderApp(api(), '/loved');
    await screen.findByRole('table', { name: 'Loved songs' });
    const table = () => screen.getByRole('table', { name: 'Loved songs' });
    const names = () => within(table()).getAllByRole('row').slice(1).map((r) => within(r).getAllByRole('cell')[0]!.textContent);

    expect(names()).toEqual([expect.stringContaining('Unheard'), expect.stringContaining('Other Recording'), expect.stringContaining('Left Behind'), expect.stringContaining('Old Flame')]);
    expect(names()[0]).toContain('catalogue review open');
    expect(names()[0]).toContain('Loved as “Unheard” by Alpha  Band');
    expect(within(table()).getByText('0 linked · 40 under this name')).toBeInTheDocument();
    expect(within(table()).getByText('none found')).toBeInTheDocument();

    await user.selectOptions(screen.getByLabelText('Sort'), 'plays');
    expect(names()[0]).toContain('Old Flame');
    await user.selectOptions(screen.getByLabelText('Artist'), 'Alpha Band');
    expect(names()).toHaveLength(2);
    await user.selectOptions(screen.getByLabelText('Year loved'), '2024');
    expect(names()).toEqual([expect.stringContaining('Unheard')]);
    expect(screen.getByText('1 of 4 songs')).toBeInTheDocument();
    await user.selectOptions(screen.getByLabelText('Year loved'), '');
    await user.selectOptions(screen.getByLabelText('Artist'), '');
    await user.type(screen.getByRole('searchbox', { name: 'Search loved songs' }), 'left');
    expect(names()).toEqual([expect.stringContaining('Left Behind')]);
    await user.clear(screen.getByRole('searchbox', { name: 'Search loved songs' }));
    await user.type(screen.getByRole('searchbox', { name: 'Search loved songs' }), 'zzz');
    expect(screen.getByText('No loved songs match.')).toBeInTheDocument();
  });

  it('links each row to the artist and to the day it was last listened to', async () => {
    const user = userEvent.setup();
    renderApp(api(), '/loved');
    const row = within(await screen.findByRole('table', { name: 'Loved songs' })).getAllByRole('row')[4]!; // Old Flame
    expect(within(row).getByRole('link', { name: 'Alpha Band' })).toHaveAttribute('href', '/artists/a1?period=all');
    await user.click(within(row).getAllByRole('link')[1]!);
    expect(location.current).toContain('/time-machine?at=');
  });

  it('shows songs no longer loved muted, without a heart, and the empty and error states', async () => {
    const gone = makeLoved(9, { unlovedAt: '2020-02-02T00:00:00Z', track: { id: 't9', name: 'Gone Now' } });
    renderApp(api([...library(), gone]), '/loved');
    expect(await screen.findByText(/1 no longer loved, shown muted/)).toBeInTheDocument();
    const row = screen.getByText('Gone Now').closest('tr')!;
    expect(within(row).queryByRole('img', { name: 'Loved' })).toBeNull();
    expect(within(row).getByText(/no longer loved since 2020-02-02/)).toBeInTheDocument();
    expect(screen.getAllByRole('img', { name: 'Loved' }).length).toBeGreaterThan(4);
  });

  it('says so when nothing is loved yet, and when the account is not connected', async () => {
    renderApp(api([]), '/loved');
    expect(await screen.findByText('No loved songs yet.')).toBeInTheDocument();
    renderApp(api([], { getLovedTracks: async () => { throw new NotConnectedError(); } }), '/loved');
    expect(await screen.findByText('No listening history is stored yet.')).toBeInTheDocument();
  });

  it('is reachable from the navigation', async () => {
    const user = userEvent.setup();
    renderApp(api(), '/overview?period=all');
    await user.click(await screen.findByRole('link', { name: 'Loved' }));
    expect(location.current).toContain('/loved');
    expect(await screen.findByRole('heading', { level: 1, name: 'Loved songs' })).toBeInTheDocument();
  });
});

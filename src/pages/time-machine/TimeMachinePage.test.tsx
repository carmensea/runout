import { fireEvent, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it } from 'vitest';
import type { RunoutApi } from '../../data/api';
import type { CalendarDays, HistoryCalendar, OnThisDay, Play, PlaysPage } from '../../data/types';
import { serializePeriod } from '../../lib/period';
import { connectedApi, notConnectedApi } from '../../test/fixtures';
import { location, renderApp } from '../../test/renderApp';
import { viewport } from '../../test/setup';

const history: HistoryCalendar = {
  firstDay: '2014-01-02',
  lastDay: '2016-03-15',
  years: [{ key: '2014', scrobbles: 60 }, { key: '2016', scrobbles: 5 }],
  months: [{ key: '2014-01', scrobbles: 20 }, { key: '2014-03', scrobbles: 40 }, { key: '2016-03', scrobbles: 5 }],
  coverage: { status: 'partial', missing: [{ from: '2015-01-01', to: '2015-12-31', startsAt: '2015-01-01T00:00:00Z', endsAt: '2016-01-01T00:00:00Z', partialFrom: false, partialTo: false }] },
};

const play = (n: number, date: string, time: string, track: string, artist = 'The Band', album: string | null = 'An Album'): Play => ({
  id: `${date}T${time}/${n}`, playedAt: `${date}T${time}.000000Z`, date, time,
  artist: { id: 'a1', name: artist }, track: { id: `t${n}`, name: track }, album: album ? { id: 'l1', name: album } : null,
});

function api(overrides: Partial<RunoutApi> = {}): RunoutApi & { requests: string[] } {
  const requests: string[] = [];
  return {
    ...connectedApi(),
    getCalendar: async () => {
      requests.push('calendar');
      return history;
    },
    getCalendarDays: async (from, to): Promise<CalendarDays> => {
      requests.push(`days:${from}..${to}`);
      const days = [{ date: '2014-03-15', scrobbles: 33 }, { date: '2014-03-16', scrobbles: 7 }, { date: '2016-03-15', scrobbles: 5 }]
        .filter((d) => d.date >= from && d.date <= to);
      const missing = from <= '2015-12-31' && to >= '2015-01-01' ? history.coverage.missing : [];
      return { from, to, days, coverage: { status: missing.length ? 'partial' : 'complete', missing } };
    },
    getPlays: async (period, cursor): Promise<PlaysPage> => {
      const key = serializePeriod(period);
      requests.push(`plays:${key}:${cursor ?? ''}`);
      if (key === 'day:2016-03-15') {
        const all = [
          play(1, '2016-03-15', '08:00:00', 'Morning Song'),
          play(2, '2016-03-15', '08:04:10', 'Same Second'),
          play(3, '2016-03-15', '08:04:10', 'Same Second'),
          play(4, '2016-03-15', '09:30:00', 'Untitled', 'Another Artist', null),
        ];
        const page = cursor ? all.slice(2) : all.slice(0, 2);
        return { period: key, total: 4, plays: page, nextCursor: cursor ? null : 'c1', coverage: { status: 'complete', missing: [] } };
      }
      if (key.startsWith('custom:2014-01-01')) {
        const rows = [play(1, '2014-03-15', '10:00:00', 'Morning Song'), play(2, '2014-03-16', '11:00:00', 'Sunday Song')];
        return { period: key, total: 40, plays: rows, nextCursor: null, coverage: { status: 'complete', missing: [] } };
      }
      if (key === 'day:2015-06-01') return { period: key, total: 0, plays: [], nextCursor: null, coverage: { status: 'none', missing: [] } };
      return { period: key, total: 0, plays: [], nextCursor: null, coverage: { status: 'complete', missing: [] } };
    },
    getOnThisDay: async (date): Promise<OnThisDay> => ({
      date,
      leapDay: date.endsWith('-02-29'),
      years: [
        { date: '2015-03-15', scrobbles: 0, coverage: 'none', topArtists: [], topTrack: null },
        { date: '2014-03-15', scrobbles: 33, coverage: 'complete', topArtists: [{ id: 'a1', name: 'The Band', scrobbles: 20 }], topTrack: { id: 't1', name: 'Hit', artist: 'The Band', scrobbles: 9 } },
      ],
    }),
    ...overrides,
    requests,
  };
}

describe('Time Machine', () => {
  beforeEach(() => {
    localStorage.clear();
    viewport.width = 1440;
  });

  it('opens the latest day with listening when there is no deep link, and lists every play in order', async () => {
    const user = userEvent.setup();
    renderApp(api(), '/time-machine');
    expect(await screen.findByRole('heading', { level: 1, name: 'Tuesday 15 March 2016' })).toBeInTheDocument();
    await waitFor(() => expect(location.current).toBe('/time-machine?period=day%3A2016-03-15&at=2016-03-15'));

    // Wait for the plays: the sidebar's list items are there before they are.
    expect(await screen.findByText('Showing 2 of 4')).toBeInTheDocument();
    const log = screen.getAllByRole('listitem').filter((r) => r.querySelector('time'));
    expect(log.map((r) => r.querySelector('time')!.textContent)).toEqual(['08:00:00', '08:04:10']);

    await user.click(screen.getByRole('button', { name: 'Show 2 more' }));
    expect(await screen.findByText('Showing 4 of 4')).toBeInTheDocument();
    expect(screen.getAllByText('Same Second')).toHaveLength(2);
    expect(screen.getAllByText('same second')).toHaveLength(1);
    expect(screen.getByText('Untitled').closest('li')!.textContent).toContain('Another Artist');
    expect(screen.queryByRole('button', { name: /more/ })).not.toBeInTheDocument();
  });

  it('shows the first plays of a day on hover', async () => {
    const user = userEvent.setup();
    renderApp(api(), '/time-machine?at=2016-03-15&period=day%3A2016-03-15');
    const day = await screen.findByRole('link', { name: /Tuesday 15 March 2016/ });
    await user.hover(day);
    const card = await screen.findByTestId('day-plays-2016-03-15');
    await waitFor(() => expect(card).toHaveTextContent('Morning Song'));
    expect(card).toHaveTextContent('08:00');
    expect(card).toHaveTextContent('and 2 more');
    await user.unhover(day);
    expect(screen.queryByTestId('day-plays-2016-03-15')).not.toBeInTheDocument();
  });

  it('opens a deep link, with a calendar whose days open the day', async () => {
    const user = userEvent.setup();
    const fake = api();
    renderApp(fake, '/time-machine?at=2014-03&period=month%3A2014-03');
    expect(await screen.findByRole('heading', { level: 1, name: 'March 2014' })).toBeInTheDocument();
    const day = await screen.findByRole('link', { name: 'Saturday 15 March 2014, 33 scrobbles' });
    expect(screen.getByRole('link', { name: 'Sunday 2 March 2014, no scrobbles' })).toBeInTheDocument();
    expect(fake.requests).toContain('days:2014-01-01..2014-12-31');
    await user.click(day);
    expect(await screen.findByRole('heading', { level: 1, name: 'Saturday 15 March 2014' })).toBeInTheDocument();
    expect(location.current).toContain('at=2014-03-15');
    // The year is fetched once, for the month and its days alike.
    expect(fake.requests.filter((r) => r.startsWith('days:'))).toEqual(['days:2014-01-01..2014-12-31']);
  });

  it('keeps the old deep links: ?at= alone, and ?at= with a week', async () => {
    renderApp(api(), '/time-machine?at=2014-W11');
    expect(await screen.findByRole('heading', { level: 1, name: 'Week 11, 2014' })).toBeInTheDocument();
    expect(screen.getByText('10 to 16 March 2014')).toBeInTheDocument();
    expect(await screen.findByRole('link', { name: 'Saturday 15 March 2014, 33 scrobbles' })).toBeInTheDocument();
    await waitFor(() => expect(location.current).toContain('period=week%3A2014-W11'));
  });

  it('moves through the calendar with arrow keys, and up a level with Escape', async () => {
    renderApp(api(), '/time-machine?at=2014-03-15&period=day%3A2014-03-15');
    const selected = await screen.findByRole('link', { name: 'Saturday 15 March 2014, 33 scrobbles' });
    // A key press on a day moves from that day, even if its focus event was never seen.
    fireEvent.keyDown(selected, { key: 'ArrowRight' });
    expect(document.activeElement).toBe(screen.getByRole('link', { name: 'Sunday 16 March 2014, 7 scrobbles' }));
    fireEvent.keyDown(document.activeElement!, { key: 'ArrowDown' });
    expect(document.activeElement).toBe(screen.getByRole('link', { name: 'Sunday 23 March 2014, no scrobbles' }));

    fireEvent.keyDown(document.activeElement!, { key: 'Escape' });
    expect(await screen.findByRole('heading', { level: 1, name: 'March 2014' })).toBeInTheDocument();
    fireEvent.keyDown(screen.getByRole('heading', { level: 1 }), { key: 'Escape' });
    expect(await screen.findByRole('heading', { level: 1, name: '2014' })).toBeInTheDocument();
  });

  it('leaves Escape and arrows alone while typing in Search', async () => {
    const user = userEvent.setup();
    renderApp(api(), '/time-machine?at=2014-03&period=month%3A2014-03');
    await screen.findByRole('heading', { level: 1, name: 'March 2014' });
    const search = screen.getByRole('combobox');
    await user.type(search, 'ab');
    fireEvent.keyDown(search, { key: 'Escape' });
    expect(screen.getByRole('heading', { level: 1, name: 'March 2014' })).toBeInTheDocument();
  });

  it('tells a day without listening from a day without history', async () => {
    renderApp(api(), '/time-machine?at=2014-03-20&period=day%3A2014-03-20');
    expect(await screen.findByText('No scrobbles on Thursday 20 March 2014.')).toBeInTheDocument();
  });

  it('says a day outside the imported history is unknown, not silent', async () => {
    renderApp(api(), '/time-machine?at=2015-06-01&period=day%3A2015-06-01');
    expect(await screen.findByText(/haven’t been imported, so nothing is known about this day/)).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /Monday 1 June 2015, not imported/ })).toBeInTheDocument();
  });

  it('shows the same date in other years, telling zero plays from missing data', async () => {
    const user = userEvent.setup();
    renderApp(api(), '/time-machine?at=2016-03-15&period=day%3A2016-03-15');
    const aside = await screen.findByRole('complementary', { name: 'On this day' });
    expect(await within(aside).findByRole('link', { name: '2014, Sat: 33 scrobbles' })).toBeInTheDocument();
    expect(within(aside).getByRole('link', { name: '2015, Sun: Not imported' })).toBeInTheDocument();
    expect(within(aside).getByText('Hit by The Band, 9 plays')).toBeInTheDocument();
    await user.click(within(aside).getByRole('link', { name: '2014, Sat: 33 scrobbles' }));
    expect(await screen.findByRole('heading', { level: 1, name: 'Saturday 15 March 2014' })).toBeInTheDocument();
  });

  it('on a phone, puts "On this day" above the plays, closed, with real counts in its summary', async () => {
    viewport.width = 390;
    const user = userEvent.setup();
    renderApp(api(), '/time-machine?at=2016-03-15&period=day%3A2016-03-15');
    const summary = await screen.findByText('15 March: listening in 1 of 2 other years');
    const details = summary.closest('details')!;
    expect(details).not.toHaveAttribute('open');
    expect(screen.queryByRole('complementary', { name: 'On this day' })).not.toBeInTheDocument();
    const plays = await screen.findByRole('heading', { level: 2, name: /Every scrobble/ });
    expect(details.compareDocumentPosition(plays) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();

    await user.click(summary);
    expect(details).toHaveAttribute('open');
    expect(within(details).getByRole('link', { name: '2014, Sat: 33 scrobbles' })).toBeInTheDocument();
    expect(within(details).getByRole('link', { name: '2015, Sun: Not imported' })).toBeInTheDocument();
  });

  it('gives every day heading its total in long custom ranges', async () => {
    const fake = api();
    renderApp(fake, '/time-machine?period=custom%3A2014-01-01..2014-12-31');
    expect(await screen.findByRole('heading', { level: 3, name: /Saturday 15 March 2014\s*33/ })).toBeInTheDocument();
    expect(screen.getByRole('heading', { level: 3, name: /Sunday 16 March 2014\s*7/ })).toBeInTheDocument();
    expect(fake.requests).toContain('days:2014-01-01..2014-12-31');
  });

  it('counts each page of plays for itself when a range is longer than the calendar answers at once', async () => {
    const fake = api();
    renderApp(fake, '/time-machine?period=custom%3A2014-01-01..2016-03-31');
    expect(await screen.findByRole('heading', { level: 3, name: /Saturday 15 March 2014\s*33/ })).toBeInTheDocument();
    expect(fake.requests).toContain('days:2014-03-15..2014-03-16');
    expect(fake.requests).not.toContain('days:2014-01-01..2016-03-31');
  });

  it('steps to neighbours, links to the Overview, and stops at the edges of the history', async () => {
    renderApp(api(), '/time-machine?at=2014-01&period=month%3A2014-01');
    await screen.findByRole('heading', { level: 1, name: 'January 2014' });
    expect(screen.getByRole('link', { name: 'Next month: February 2014' })).toHaveAttribute('href', '/time-machine?period=month%3A2014-02&at=2014-02');
    expect(await screen.findByRole('link', { name: 'No earlier month' })).toHaveAttribute('aria-disabled', 'true');
    expect(screen.getByRole('link', { name: /Open in Overview/ })).toHaveAttribute('href', '/overview?period=month%3A2014-01');
    const trail = screen.getByRole('navigation', { name: 'Time Machine levels' });
    expect(within(trail).getByRole('link', { name: 'All years' })).toHaveAttribute('href', '/time-machine?period=all&at=all');
  });

  it('shows the whole history, every year from the first, a silent one included', async () => {
    renderApp(api(), '/time-machine?at=all&period=all');
    expect(await screen.findByRole('heading', { level: 1, name: 'Your whole history' })).toBeInTheDocument();
    const years = await screen.findByRole('navigation', { name: 'Years' });
    expect(within(years).getByRole('link', { name: '2015, no scrobbles' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'June 2015, not imported' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'March 2014, 40 scrobbles' })).toBeInTheDocument();
  });

  it('says so when nothing is connected or there is no history yet', async () => {
    renderApp(notConnectedApi, '/time-machine');
    expect(await screen.findByText('Sign in to see your listening.')).toBeInTheDocument();
  });

  it('shows plays recorded from Spotify when Last.fm was never imported', async () => {
    renderApp(api({ getConnection: async () => ({ status: 'connected', displayName: 'test-user', username: 'test-user', timezone: 'Europe/London' }) }), '/time-machine');
    expect(await screen.findByText('Morning Song')).toBeInTheDocument();
    expect(screen.queryByText(/hasn’t been imported yet/)).not.toBeInTheDocument();
  });

  it('asks a signed-in account with no plays to import', async () => {
    renderApp({ ...connectedApi(), getConnection: async () => ({ status: 'connected', displayName: 'test-user', username: 'test-user', timezone: 'Europe/London' }) }, '/time-machine');
    expect(await screen.findByText('Your listening history hasn’t been imported yet.')).toBeInTheDocument();
  });

  it('has an empty state for an empty history', async () => {
    renderApp(api({ getCalendar: async () => ({ firstDay: null, lastDay: null, years: [], months: [], coverage: { status: 'none', missing: [] } }) }), '/time-machine');
    expect(await screen.findByText('There are no scrobbles in your history yet.')).toBeInTheDocument();
  });
});

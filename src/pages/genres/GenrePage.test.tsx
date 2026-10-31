import { screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it } from 'vitest';
import { ApiError, type RunoutApi } from '../../data/api';
import { serializePeriod } from '../../lib/period';
import { connectedApi, makeGenreDetail } from '../../test/fixtures';
import { location, renderApp } from '../../test/renderApp';

function api(overrides: Partial<RunoutApi> = {}): RunoutApi & { asked: string[] } {
  const asked: string[] = [];
  return {
    ...connectedApi(),
    getGenre: async (slug, period) => {
      asked.push(`${slug}:${serializePeriod(period)}`);
      if (slug === 'nonsense') throw new ApiError(404, 'not found');
      return makeGenreDetail(slug, period.kind === 'year' && period.year === 2019 ? { share: 0.2, allocated: 20, reach: { plays: 40, share: 0.4 } } : {});
    },
    ...overrides,
    asked,
  };
}

describe('Genre page', () => {
  beforeEach(() => localStorage.clear());

  it('shows share, plays counted, reach (labelled as overlapping) and Unclassified, with sources', async () => {
    renderApp(api(), '/genres/rock?period=year%3A2020');
    expect(await screen.findByRole('heading', { level: 1, name: 'Rock' })).toBeInTheDocument();
    const stats = screen.getByText('Share of plays').closest('dl')!;
    expect(within(stats).getByText('40%')).toBeInTheDocument();
    expect(within(stats).getByText('70%')).toBeInTheDocument();
    expect(within(stats).getByText(/Overlaps with other genres, so reach figures don’t add up/)).toBeInTheDocument();
    expect(within(stats).getByText('20%')).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'MusicBrainz' })).toHaveAttribute('href', 'https://musicbrainz.org');
    expect(screen.getByText(/CC BY-NC-SA 3.0/)).toBeInTheDocument();
    expect(screen.getByText(/Classification is by artist/)).toBeInTheDocument();
  });

  it('lists subgenres (linking where they have a page), artists and tracks', async () => {
    const user = userEvent.setup();
    renderApp(api(), '/genres/rock?period=year%3A2020');
    await screen.findByRole('heading', { level: 1, name: 'Rock' });
    expect(screen.getByText('Other rock').closest('a')).toBeNull();
    const artists = screen.getByRole('table', { name: 'Artists contributing to rock' });
    expect(within(artists).getByRole('link', { name: 'Test Artist A' })).toBeInTheDocument();
    expect(within(artists).getByText('85%')).toBeInTheDocument();
    expect(screen.getByRole('table', { name: 'Tracks contributing to rock' })).toHaveTextContent('Test Track');
    await user.click(screen.getByRole('link', { name: 'Post-punk' }));
    expect(location.current).toContain('/genres/post-punk');
  });

  it('compares with the comparison period beside each figure', async () => {
    const fake = api();
    renderApp(fake, '/genres/rock?period=year%3A2020&vs=year%3A2019');
    await screen.findByRole('heading', { level: 1, name: 'Rock' });
    expect(await screen.findByText('2019: 40%')).toBeInTheDocument(); // the comparison's reach
    expect(fake.asked).toEqual(expect.arrayContaining(['rock:year:2020', 'rock:year:2019']));
  });

  it('says so for a genre Runout doesn’t have', async () => {
    renderApp(api(), '/genres/nonsense');
    expect(await screen.findByText('Runout has no genre by that name.')).toBeInTheDocument();
  });
});

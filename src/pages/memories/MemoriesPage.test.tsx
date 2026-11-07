import { screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it } from 'vitest';
import type { RunoutApi } from '../../data/api';
import { connectedApi, fakeMemoriesApi, makeMemory } from '../../test/fixtures';
import { location, renderApp } from '../../test/renderApp';
import { viewport } from '../../test/setup';

// Memories: songs that carry memories, a journal in time order, a search, and the way in from
// the navigation on desktop and on a phone. Fictional songs and words.
describe('Memories page', () => {
  afterEach(() => {
    viewport.width = 1440;
  });

  function api(overrides: Partial<RunoutApi> = {}): RunoutApi {
    const memories = fakeMemoriesApi([
      makeMemory(1),
      makeMemory(2, { body: 'Driving around with my best friend.', rememberedOn: null, rememberedLabel: '2012', createdAt: '2026-11-07T13:00:00Z', updatedAt: '2026-11-07T13:00:00Z' }),
      makeMemory(3, { song: { id: 't2', name: 'Paper Boats', artist: { id: 'a1', name: 'The Lanterns' }, artworkUrl: 'https://coverartarchive.org/release/x/1-250.jpg' },
        body: 'The song from the end of that summer.', rememberedOn: '2015-08-30', createdAt: '2026-11-06T13:00:00Z', updatedAt: '2026-11-06T13:00:00Z' }),
    ]);
    return { ...connectedApi(), memories, ...overrides };
  }

  it('lists the songs with memories, newest written first, with a count and a preview, and opens a song', async () => {
    const user = userEvent.setup();
    renderApp(api(), '/memories');
    expect(await screen.findByRole('heading', { name: 'Memories' })).toBeInTheDocument();
    const songs = within(screen.getByRole('list', { name: 'Songs with memories' })).getAllByRole('listitem');
    expect(songs).toHaveLength(2);
    expect(songs[0]).toHaveTextContent('Harbour Lights');
    expect(songs[0]).toHaveTextContent('2 memories');
    expect(songs[0]).toHaveTextContent('Driving around with my best friend.');
    expect(songs[1]).toHaveTextContent('Paper Boats');
    expect(songs[1]).toHaveTextContent('1 memory');
    expect(songs[1]).toHaveTextContent('2015-08-30');
    expect(screen.queryByRole('radiogroup', { name: 'Period type' })).not.toBeInTheDocument();
    await user.click(within(songs[1]!).getByRole('link', { name: 'Paper Boats' }));
    expect(location.current).toMatch(/^\/tracks\/t2/);
  });

  it('shows the journal in the order of what the memories are about, and searches the words, songs and artists', async () => {
    const user = userEvent.setup();
    renderApp(api(), '/memories');
    await screen.findByRole('heading', { name: 'Memories' });
    await user.click(screen.getByRole('radio', { name: 'Journal' }));
    const entries = within(screen.getByRole('list', { name: 'Memories in time order' })).getAllByRole('listitem');
    expect(entries.map((e) => e.textContent)).toEqual([
      expect.stringContaining('Driving around'),
      expect.stringContaining('end of that summer'),
      expect.stringContaining('ferry crossing'),
    ]);
    expect(entries[1]).toHaveTextContent('Paper Boats');

    await user.type(screen.getByRole('searchbox', { name: 'Search memories' }), 'summer');
    expect(await screen.findByText(/end of that summer/)).toBeInTheDocument();
    expect(screen.queryByText(/ferry crossing/)).not.toBeInTheDocument();
    await user.clear(screen.getByRole('searchbox', { name: 'Search memories' }));
    await user.type(screen.getByRole('searchbox', { name: 'Search memories' }), 'nothing like this');
    expect(await screen.findByText('Nothing matches that.')).toBeInTheDocument();
  });

  it('explains how to start when nothing is written yet', async () => {
    renderApp(api({ memories: fakeMemoriesApi([]) }), '/memories');
    expect(await screen.findByText(/No memories yet/)).toBeInTheDocument();
  });

  it('is reachable from the sidebar', async () => {
    const user = userEvent.setup();
    renderApp(api(), '/overview?period=all');
    await user.click(await screen.findByRole('link', { name: /Memories/ }));
    expect(location.current).toMatch(/^\/memories/);
    expect(await screen.findByRole('heading', { name: 'Memories' })).toBeInTheDocument();
  });

  it('is reachable from the phone navigation, under More', async () => {
    const user = userEvent.setup();
    viewport.width = 375;
    renderApp(api(), '/overview?period=all');
    await user.click(await screen.findByRole('button', { name: /More/ }));
    // The sidebar is in the document too (hidden by layout); the More sheet's link is the last one.
    const links = await screen.findAllByRole('link', { name: /Memories/ });
    await user.click(links[links.length - 1]!);
    expect(location.current).toMatch(/^\/memories/);
    expect(await screen.findByRole('heading', { name: 'Memories' })).toBeInTheDocument();
  });
});

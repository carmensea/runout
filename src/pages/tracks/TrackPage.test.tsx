import { screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it } from 'vitest';
import { ApiError, type RunoutApi } from '../../data/api';
import { connectedApi, fakeMemoriesApi, makeMemory, makeSong } from '../../test/fixtures';
import { renderApp } from '../../test/renderApp';

// The song page: name, artist, the person's own listening, and their memories, written, edited
// and deleted in place. Fictional songs and words.
describe('Song page', () => {
  function api(overrides: Partial<RunoutApi> = {}): RunoutApi & { memories: ReturnType<typeof fakeMemoriesApi> } {
    const memories = fakeMemoriesApi([makeMemory(1), makeMemory(2, { body: 'Driving around with my best friend.', rememberedOn: null, rememberedLabel: '2012', createdAt: '2026-11-07T13:00:00Z', updatedAt: '2026-11-07T13:00:00Z' })]);
    return { ...connectedApi(), getSong: async (key) => makeSong(key, { memories: memories.all() }), memories, ...overrides } as RunoutApi & { memories: typeof memories };
  }

  it('shows the song, its listening and its memories in the order they were written', async () => {
    renderApp(api(), '/tracks/t1');
    expect(await screen.findByRole('heading', { name: 'Harbour Lights' })).toBeInTheDocument();
    expect(screen.getByText('The Lanterns')).toBeInTheDocument();
    expect(screen.getByText('Listens')).toBeInTheDocument();
    expect(screen.getByRole('list', { name: 'Listens by year' })).toHaveTextContent('2014');
    const items = within(screen.getByRole('list', { name: 'Your memories of this song' })).getAllByRole('listitem');
    expect(items).toHaveLength(2);
    expect(items[0]).toHaveTextContent('2014-03-15');
    expect(items[0]).toHaveTextContent('The ferry crossing the first winter I lived by the water.');
    expect(items[1]).toHaveTextContent('2012');
    expect(screen.queryByRole('radiogroup', { name: 'Period type' })).not.toBeInTheDocument();
  });

  it('writes a new memory with its own date and label, then edits and deletes it', async () => {
    const user = userEvent.setup();
    const a = api();
    renderApp(a, '/tracks/t1');
    await user.click(await screen.findByRole('button', { name: 'Add a memory' }));
    const form = screen.getByRole('form', { name: 'New memory' });
    await user.type(within(form).getByLabelText('What this song means to you'), 'Listened to this constantly after the move.');
    await user.type(within(form).getByLabelText('Date it is about, if you know it'), '2016-09-01');
    await user.type(within(form).getByLabelText('Or a time in your own words'), 'the autumn after the move');
    await user.click(within(form).getByRole('button', { name: 'Save memory' }));
    await waitFor(() => expect(a.memories.calls).toContain('create:t1'));
    const list = screen.getByRole('list', { name: 'Your memories of this song' });
    expect(within(list).getAllByRole('listitem')).toHaveLength(3);
    expect(list).toHaveTextContent('the autumn after the move · 2016-09-01');
    expect(screen.queryByRole('form', { name: 'New memory' })).not.toBeInTheDocument();

    const third = within(list).getAllByRole('listitem')[2]!;
    await user.click(within(third).getByRole('button', { name: 'Edit' }));
    const edit = screen.getByRole('form', { name: 'Edit memory' });
    await user.clear(within(edit).getByLabelText('Your memory'));
    await user.type(within(edit).getByLabelText('Your memory'), 'Every morning that autumn.');
    await user.click(within(edit).getByRole('button', { name: 'Save changes' }));
    await waitFor(() => expect(a.memories.calls).toContain('update:3'));
    expect(list).toHaveTextContent('Every morning that autumn.');
    expect(list).toHaveTextContent('edited 2026-11-09');

    const first = within(list).getAllByRole('listitem')[0]!;
    await user.click(within(first).getByRole('button', { name: 'Delete' }));
    await user.click(within(first).getByRole('button', { name: 'Delete memory' }));
    await waitFor(() => expect(a.memories.calls).toContain('remove:1'));
    expect(within(list).getAllByRole('listitem')).toHaveLength(2);
    expect(list).not.toHaveTextContent('ferry crossing');
  });

  it('keeps the memory when a delete is called off, and refuses an empty memory', async () => {
    const user = userEvent.setup();
    const a = api();
    renderApp(a, '/tracks/t1');
    const list = await screen.findByRole('list', { name: 'Your memories of this song' });
    const first = within(list).getAllByRole('listitem')[0]!;
    await user.click(within(first).getByRole('button', { name: 'Delete' }));
    await user.click(within(first).getByRole('button', { name: 'Keep it' }));
    expect(within(list).getAllByRole('listitem')).toHaveLength(2);
    await user.click(screen.getByRole('button', { name: 'Add a memory' }));
    expect(screen.getByRole('button', { name: 'Save memory' })).toBeDisabled();
    expect(a.memories.calls.filter((c) => c.startsWith('remove') || c.startsWith('create'))).toEqual([]);
  });

  it('shows a song without listening as rememberable, and a song the catalogue lacks as missing', async () => {
    renderApp(api({ getSong: async (key) => makeSong(key, { plays: { total: 0, firstPlayedAt: null, lastPlayedAt: null, byYear: [] }, memories: [] }) }), '/tracks/t9');
    expect(await screen.findByText(/No listens recorded for this song yet/)).toBeInTheDocument();
    expect(screen.getByText(/Nothing written yet/)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Add a memory' })).toBeInTheDocument();

    renderApp(api({ getSong: async () => { throw new ApiError(404, 'not found', null, null); } }), '/tracks/t404');
    expect(await screen.findByText('This song isn’t in the catalogue.')).toBeInTheDocument();
  });
});

import { useDeferredValue, useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { MemoryItem } from '../../components/memories/MemoryItem';
import { rememberedText } from '../../lib/memories';
import { LoadingState, MessageState } from '../../components/states/States';
import stateStyles from '../../components/states/States.module.css';
import { Artwork } from '../../components/ui/Artwork';
import { SegmentedControl } from '../../components/ui/SegmentedControl';
import { useAppData } from '../../data/AppDataContext';
import type { Memory, MemoryInput } from '../../data/types';
import { useAsync } from '../../data/useAsync';
import { usePeriod } from '../../state/PeriodContext';
import pageStyles from '../overview/OverviewPage.module.css';
import styles from './Memories.module.css';

type View = 'songs' | 'journal';

/**
 * Memories (GET /api/memories): everything the signed-in person has written about songs, by song
 * or as a journal in time order, with a search over their words, the songs and the artists. The same
 * search also finds songs in the person's own history that have no memory yet, so the first one can
 * be written from here. Opening a song shows its whole history and every memory about it. Private:
 * nobody else's ever appears.
 */
export function MemoriesPage() {
  const { api, fmt } = useAppData();
  const { withPeriod } = usePeriod();
  const [query, setQuery] = useState('');
  const [view, setView] = useState<View>('songs');
  const q = useDeferredValue(query.trim());
  const loaded = useAsync(`memories:${q}`, (signal) => api.memories.list(q, signal));
  // Songs from the person's history whose title matches the search (GET /api/search, which matches
  // song titles, not artists; two characters or more). A null key never resolves, so the states
  // below count only when a search is really running.
  const found = useAsync(q.length >= 2 ? `memories-search:${q}` : null, (signal) => api.search(q, signal));
  const searching = q.length >= 2 && found.status === 'loading';
  const searchFailed = q.length >= 2 && found.status === 'error';
  // Edits made here, valid for the data they were made against; a new search or reload starts afresh.
  const [edits, setEdits] = useState<{ base: Memory[]; list: Memory[] } | null>(null);
  const data = loaded.status === 'success' ? loaded.data : null;
  useEffect(() => {
    document.title = 'Memories · Runout';
  }, []);
  const list = useMemo(() => (data ? (edits && edits.base === data.memories ? edits.list : data.memories) : []), [edits, data]);
  const setMemories = (next: Memory[]) => data && setEdits({ base: data.memories, list: next });
  const songHref = (id: string) => withPeriod(`/tracks/${encodeURIComponent(id)}`);

  async function update(id: number, input: MemoryInput) {
    const updated = await api.memories.update(id, input);
    setMemories(list.map((m) => (m.id === id ? updated : m)));
  }
  async function remove(id: number) {
    await api.memories.remove(id);
    setMemories(list.filter((m) => m.id !== id));
  }

  const songs = useMemo(() => {
    const bySong = new Map<string, Memory[]>();
    for (const m of list) bySong.set(m.song.id, [...(bySong.get(m.song.id) ?? []), m]);
    // Songs by the most recently written memory about them (the list arrives newest first).
    return [...bySong.values()]
      .flatMap((group) => (group[0] ? [{ latest: group[0], count: group.length }] : []))
      .sort((a, b) => b.latest.createdAt.localeCompare(a.latest.createdAt));
  }, [list]);
  // History songs the search found that carry no memory yet; a song the catalogue could not place has no page.
  const unwritten = useMemo(() => {
    if (q.length < 2 || found.status !== 'success') return [];
    const written = new Set(list.map((m) => m.song.id));
    return found.data.tracks.filter((t) => t.id.startsWith('t') && !written.has(t.id));
  }, [q, found, list]);
  const journal = useMemo(() => [...list].sort((a, b) => (b.rememberedOn ?? b.createdAt.slice(0, 10)).localeCompare(a.rememberedOn ?? a.createdAt.slice(0, 10)) || b.createdAt.localeCompare(a.createdAt)), [list]);

  return (
    <main id="main" className={pageStyles.main}>
      <header className={pageStyles.header}>
        <div>
          <div className="eyebrow">06 / Memories{data && list.length > 0 && ` · ${fmt.count(list.length)} ${list.length === 1 ? 'memory' : 'memories'}`}</div>
          <h1 className={pageStyles.title}>Memories</h1>
          <p className={pageStyles.intro}>
            The songs that carry a person, a place or a time for you, in your own words. Open a song to see everything you wrote about it and its whole history in your listening.
          </p>
        </div>
      </header>

      <div className={styles.controls}>
        <label className={styles.search} style={{ display: 'contents' }}>
          <span className="sr-only">Search memories</span>
          <input type="search" className={styles.search} placeholder="Search your memories, songs and artists" value={query} onChange={(e) => setQuery(e.target.value)} />
        </label>
        <SegmentedControl label="View" options={[{ value: 'songs', label: 'By song' }, { value: 'journal', label: 'Journal' }]} value={view} onChange={setView} />
      </div>

      {data?.readOnly && <p className={styles.empty} role="note">Operator view: the words are placeholders of the same shape, the search looks only at songs and artists, and nothing can be changed.</p>}
      {loaded.status === 'loading' && !data && <LoadingState label="Loading your memories" />}
      {loaded.status === 'error' && (
        <MessageState icon="error" tone="error" message="Your memories could not be loaded." detail={loaded.error.message}>
          <div className={stateStyles.actions}><button type="button" className={stateStyles.secondary} onClick={loaded.retry}>Try again</button></div>
        </MessageState>
      )}
      {data && list.length === 0 && !q && (
        <p className={styles.empty}>No memories yet. Search a song above, or open one from the Overview or the Time Machine, and write what it means to you.</p>
      )}
      {data && list.length === 0 && q && searching && <p className={styles.empty} role="status">Searching your history…</p>}
      {data && list.length === 0 && q && searchFailed && (
        <MessageState icon="error" tone="error" message="No memories match that, and your history could not be searched." detail={found.status === 'error' ? found.error.message : undefined}>
          <div className={stateStyles.actions}><button type="button" className={stateStyles.secondary} onClick={found.retry}>Try again</button></div>
        </MessageState>
      )}
      {data && list.length === 0 && q && !searching && !searchFailed && (
        <p className={styles.empty}>
          {unwritten.length > 0 ? 'No memories match that yet.' : 'Nothing matches that. Songs with no memory yet are found by their title.'}
        </p>
      )}
      {list.length > 0 && view === 'songs' && (
        <ul className={styles.list} aria-label="Songs with memories">
          {songs.map(({ latest, count }) => {
            const song = latest.song;
            return (
              <li key={song.id} className={styles.songRow}>
                <span className={styles.songRowArt}><Artwork src={song.artworkUrl} name={song.name} size={56} /></span>
                <div className={styles.songRowTitle}>
                  <Link to={songHref(song.id)}>{song.name}</Link>
                  <span className={styles.songArtist} style={{ margin: 0 }}>{song.artist.name}</span>
                  <span className={styles.songRowCount}>{count === 1 ? '1 memory' : `${count} memories`}</span>
                </div>
                <p className={styles.memoryWhen} style={{ margin: 0 }}>{rememberedText(latest, fmt)}</p>
                <p className={styles.songRowPreview}>{latest.body}</p>
              </li>
            );
          })}
        </ul>
      )}
      {list.length > 0 && view === 'journal' && (
        <div className={styles.measure}>
          <ul className={styles.list} aria-label="Memories in time order">
            {journal.map((m) => <MemoryItem key={m.id} memory={m} fmt={fmt} showSong readOnly={data?.readOnly} songHref={songHref} onUpdate={update} onDelete={remove} />)}
          </ul>
        </div>
      )}
      {unwritten.length > 0 && (
        <section className={styles.unwritten} aria-labelledby="memories-unwritten">
          <h2 id="memories-unwritten" className={styles.unwrittenHead}>Songs in your history</h2>
          <p className={styles.unwrittenHint}>Songs whose title matches, with no memory yet. Open one to write the first.</p>
          <ul className={styles.list} aria-label="Songs in your history">
            {unwritten.map((t) => (
              <li key={t.id} className={styles.songRow}>
                <span className={styles.songRowArt}><Artwork src={null} name={t.name} size={56} /></span>
                <div className={styles.songRowTitle}>
                  <Link to={songHref(t.id)}>{t.name}</Link>
                  <span className={styles.songArtist} style={{ margin: 0 }}>{t.artist}</span>
                </div>
              </li>
            ))}
          </ul>
        </section>
      )}
    </main>
  );
}

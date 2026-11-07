import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { MemoryEditor } from '../../components/memories/MemoryEditor';
import { MemoryItem } from '../../components/memories/MemoryItem';
import { Section } from '../../components/layout/Section';
import { LoadingState, MessageState } from '../../components/states/States';
import stateStyles from '../../components/states/States.module.css';
import { Artwork } from '../../components/ui/Artwork';
import { ApiError } from '../../data/api';
import { useAppData } from '../../data/AppDataContext';
import type { Memory, MemoryInput } from '../../data/types';
import { useAsync } from '../../data/useAsync';
import { ratio } from '../../lib/scale';
import { usePeriod } from '../../state/PeriodContext';
import genreStyles from '../genres/GenrePage.module.css';
import styles from '../memories/Memories.module.css';
import statStyles from '../overview/sections/ListeningSection.module.css';
import pageStyles from '../overview/OverviewPage.module.css';

/**
 * One song (GET /api/tracks/:key): its name, artist and cover, the signed-in person's own
 * listening (in all, first and last, by year), and their memories about it, with the place to
 * write another. Memories are private; the page never shows anyone else's.
 */
export function TrackPage() {
  const { trackId = '' } = useParams();
  const { api, fmt } = useAppData();
  const { withPeriod } = usePeriod();
  const song = useAsync(trackId ? `song:${trackId}` : null, (signal) => api.getSong(trackId, signal));
  // Edits made on this page, valid for the data they were made against; a reload starts afresh.
  const [edits, setEdits] = useState<{ base: Memory[]; list: Memory[] } | null>(null);
  const [writing, setWriting] = useState(false);
  const data = song.status === 'success' ? song.data : null;
  useEffect(() => {
    document.title = data ? `${data.name} · ${data.artist.name} · Runout` : 'Song · Runout';
  }, [data]);

  if (song.status === 'loading') return <LoadingState label="Loading the song" />;
  if (song.status === 'error') {
    const missing = song.error instanceof ApiError && song.error.status === 404;
    return (
      <main id="main" className={pageStyles.main}>
        <MessageState
          icon={missing ? 'music_off' : 'error'}
          tone={missing ? undefined : 'error'}
          message={missing ? 'This song isn’t in the catalogue.' : 'The song could not be loaded.'}
          detail={missing ? 'Songs reach the catalogue through your plays. Find one from the Overview, Search or the Time Machine.' : song.error.message}
        >
          <div className={stateStyles.actions}>
            {missing ? <Link to={withPeriod('/overview')} className={stateStyles.secondary}>Back to the Overview</Link> : <button type="button" className={stateStyles.secondary} onClick={song.retry}>Try again</button>}
          </div>
        </MessageState>
      </main>
    );
  }
  const s = song.data;
  const list = edits && edits.base === s.memories ? edits.list : s.memories;
  const setMemories = (next: Memory[]) => setEdits({ base: s.memories, list: next });
  const songHref = (id: string) => withPeriod(`/tracks/${encodeURIComponent(id)}`);
  const years = s.plays.byYear;
  const most = Math.max(1, ...years.map((y) => y.plays));

  async function create(input: MemoryInput) {
    const created = await api.memories.create(s.id, input);
    setMemories([...list, created]);
    setWriting(false);
  }
  async function update(id: number, input: MemoryInput) {
    const updated = await api.memories.update(id, input);
    setMemories(list.map((m) => (m.id === id ? updated : m)));
  }
  async function remove(id: number) {
    await api.memories.remove(id);
    setMemories(list.filter((m) => m.id !== id));
  }

  return (
    <main id="main" className={pageStyles.main}>
      <header className={`${pageStyles.header} ${styles.songHead}`}>
        <Artwork src={s.artworkUrl} name={s.name} size={96} />
        <div className={styles.songHeadText}>
          <div className="eyebrow">04 / Song</div>
          <h1 className={pageStyles.title}>{s.name}</h1>
          <p className={styles.songArtist}>{s.artist.name}</p>
        </div>
      </header>

      <Section id="listening" eyebrow="01 / Listening" title="In your history" description={s.plays.total === 0 ? 'No listens recorded for this song yet. A memory can still be written about it.' : 'Your own plays of this song, by the shared identity rules: the same song however it was spelled or reported.'}>
        {s.plays.total > 0 && (
          <>
            <dl className={statStyles.stats}>
              {[
                { label: 'Listens', value: fmt.count(s.plays.total), note: 'in all' },
                { label: 'First listen', value: s.plays.firstPlayedAt ? fmt.date(s.plays.firstPlayedAt) : '—', note: '' },
                { label: 'Last listen', value: s.plays.lastPlayedAt ? fmt.date(s.plays.lastPlayedAt) : '—', note: '' },
              ].map((st) => (
                <div key={st.label} className={statStyles.stat}>
                  <dt>{st.label}</dt>
                  <dd><span className={statStyles.value}>{st.value}</span>{st.note && <span className={statStyles.note}>{st.note}</span>}</dd>
                </div>
              ))}
            </dl>
            <ol className={genreStyles.bars} aria-label="Listens by year">
              {years.map((y) => (
                <li key={y.year} className={genreStyles.barRow}>
                  <span className="mono">{y.year}</span>
                  <span className={genreStyles.track} aria-hidden="true"><span style={{ width: `${ratio(y.plays, most) * 100}%` }} /></span>
                  <span className="mono">{fmt.count(y.plays)}</span>
                  <span className={`mono ${genreStyles.muted}`}>{y.plays === 1 ? 'listen' : 'listens'}</span>
                </li>
              ))}
            </ol>
          </>
        )}
      </Section>

      <Section
        id="memories"
        eyebrow="02 / Memories"
        title="What this song means to you"
        description="Your own words, private to you. A memory can be about a time long before the first play recorded here."
        actions={!writing && <button type="button" className={stateStyles.primary} onClick={() => setWriting(true)}>Add a memory</button>}
      >
        <div className={styles.measure}>
          {writing && <MemoryEditor onSave={create} onCancel={() => setWriting(false)} />}
          {list.length === 0 && !writing && (
            <p className={styles.empty}>Nothing written yet. When this song brings back a person, a place or a time, write it down here and it stays with the song.</p>
          )}
          {list.length > 0 && (
            <ul className={styles.list} aria-label="Your memories of this song">
              {list.map((m) => <MemoryItem key={m.id} memory={m} fmt={fmt} songHref={songHref} onUpdate={update} onDelete={remove} />)}
            </ul>
          )}
        </div>
      </Section>
    </main>
  );
}

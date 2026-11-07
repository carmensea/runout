import { useState } from 'react';
import { Link } from 'react-router-dom';
import stateStyles from '../states/States.module.css';
import type { Formatter } from '../../lib/format';
import { rememberedText } from '../../lib/memories';
import type { Memory, MemoryInput } from '../../data/types';
import styles from '../../pages/memories/Memories.module.css';
import { MemoryEditor } from './MemoryEditor';

/**
 * One memory as read: when it is about, the words, when it was written and last edited, and the
 * song when the list spans songs. Edit opens the editor in place; delete asks once.
 */
export function MemoryItem({ memory, fmt, showSong, songHref, onUpdate, onDelete }: {
  memory: Memory;
  fmt: Formatter;
  showSong?: boolean;
  songHref(id: string): string;
  onUpdate(id: number, input: MemoryInput): Promise<void>;
  onDelete(id: number): Promise<void>;
}) {
  const [editing, setEditing] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (editing) {
    return (
      <li className={styles.memory}>
        <MemoryEditor initial={memory} onSave={async (input) => { await onUpdate(memory.id, input); setEditing(false); }} onCancel={() => setEditing(false)} />
      </li>
    );
  }
  const edited = memory.updatedAt !== memory.createdAt;
  return (
    <li className={styles.memory}>
      <p className={styles.memoryWhen}>{rememberedText(memory, fmt)}</p>
      <p className={styles.memoryBody}>{memory.body}</p>
      <div className={styles.memoryFoot}>
        {showSong && (
          <span className={styles.song}>
            <Link to={songHref(memory.song.id)}>{memory.song.name}</Link> · {memory.song.artist.name}
          </span>
        )}
        {(memory.rememberedLabel || memory.rememberedOn) && <span>Written {fmt.date(memory.createdAt)}{edited ? `, edited ${fmt.date(memory.updatedAt)}` : ''}</span>}
        {!memory.rememberedLabel && !memory.rememberedOn && edited && <span>Edited {fmt.date(memory.updatedAt)}</span>}
        {confirming ? (
          <span className={styles.actions} role="group" aria-label="Delete this memory">
            <button type="button" className={stateStyles.secondary} disabled={pending} onClick={() => setConfirming(false)}>Keep it</button>
            <button
              type="button"
              className={stateStyles.primary}
              disabled={pending}
              onClick={async () => {
                setPending(true);
                setError(null);
                try {
                  await onDelete(memory.id);
                } catch (e) {
                  setError(e instanceof Error ? e.message : 'The memory could not be deleted.');
                  setPending(false);
                  setConfirming(false);
                }
              }}
            >
              {pending ? 'Deleting' : 'Delete memory'}
            </button>
          </span>
        ) : (
          <>
            <button type="button" className={styles.textButton} onClick={() => setEditing(true)}>Edit</button>
            <button type="button" className={styles.textButton} onClick={() => setConfirming(true)}>Delete</button>
          </>
        )}
      </div>
      {error && <p className={styles.error} role="alert">{error}</p>}
    </li>
  );
}

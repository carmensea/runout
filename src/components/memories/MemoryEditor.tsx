import { useState, type FormEvent } from 'react';
import stateStyles from '../states/States.module.css';
import type { Memory, MemoryInput } from '../../data/types';
import styles from '../../pages/memories/Memories.module.css';

/**
 * Writing or editing one memory: a plain textarea that grows, and the memory's own date or a
 * free label ("the summer I moved") for what time it is about. Nothing is generated; every word
 * is the person's. The text is held only in this component until saved.
 */
export function MemoryEditor({ initial, onSave, onCancel }: { initial?: Memory; onSave(input: MemoryInput): Promise<void>; onCancel(): void }) {
  const [body, setBody] = useState(initial?.body ?? '');
  const [rememberedOn, setRememberedOn] = useState(initial?.rememberedOn ?? '');
  const [rememberedLabel, setRememberedLabel] = useState(initial?.rememberedLabel ?? '');
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const id = `memory-${initial?.id ?? 'new'}`;

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (!body.trim()) return;
    setPending(true);
    setError(null);
    try {
      await onSave({ body: body.trim(), rememberedOn: rememberedOn || null, rememberedLabel: rememberedLabel.trim() || null });
    } catch (e) {
      setError(e instanceof Error ? e.message : 'The memory could not be saved.');
      setPending(false);
    }
  }

  return (
    <form className={styles.editor} onSubmit={submit} aria-label={initial ? 'Edit memory' : 'New memory'}>
      <label className={styles.field} htmlFor={`${id}-body`}>
        <span>{initial ? 'Your memory' : 'What this song means to you'}</span>
        <textarea
          id={`${id}-body`}
          className={styles.textarea}
          value={body}
          onChange={(e) => setBody(e.target.value)}
          maxLength={20000}
          autoFocus
        />
      </label>
      <div className={styles.fields}>
        <label className={styles.field} htmlFor={`${id}-date`}>
          <span>Date it is about, if you know it</span>
          <input id={`${id}-date`} type="date" className={styles.input} value={rememberedOn} onChange={(e) => setRememberedOn(e.target.value)} />
        </label>
        <label className={styles.field} htmlFor={`${id}-label`}>
          <span>Or a time in your own words</span>
          <input
            id={`${id}-label`}
            type="text"
            className={styles.input}
            value={rememberedLabel}
            onChange={(e) => setRememberedLabel(e.target.value)}
            maxLength={80}
            placeholder="the summer I moved, 2012, that winter"
          />
        </label>
      </div>
      <p className={styles.hint}>Private: only you can read your memories. The date you write this is kept separately.</p>
      {error && <p className={styles.error} role="alert">{error}</p>}
      <div className={styles.actions}>
        <button type="submit" className={stateStyles.primary} disabled={pending || !body.trim()}>{pending ? 'Saving' : initial ? 'Save changes' : 'Save memory'}</button>
        <button type="button" className={stateStyles.secondary} disabled={pending} onClick={onCancel}>Cancel</button>
      </div>
    </form>
  );
}

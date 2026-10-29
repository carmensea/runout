import { useRef, type KeyboardEvent } from 'react';
import { Link } from 'react-router-dom';
import type { GenreCategory } from '../../data/types';
import { ratio } from '../../lib/scale';
import styles from './GenreCharts.module.css';

interface Props {
  genres: Array<GenreCategory & { color: string }>;
  selectedId: string | null;
  onSelect(id: string | null): void;
  formatShare(share: number): string;
}

/** Selectable list (role="listbox"). Arrow keys move the selection. */
export function GenreList({ genres, selectedId, onSelect, formatShare }: Props) {
  const refs = useRef<Array<HTMLDivElement | null>>([]);
  const max = Math.max(0, ...genres.map((g) => g.share));
  const selIdx = genres.findIndex((g) => g.id === selectedId);

  function onKeyDown(e: KeyboardEvent, i: number) {
    let next: number | null = null;
    if (e.key === 'ArrowDown') next = Math.min(genres.length - 1, i + 1);
    else if (e.key === 'ArrowUp') next = Math.max(0, i - 1);
    else if (e.key === 'Home') next = 0;
    else if (e.key === 'End') next = genres.length - 1;
    else if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      onSelect(genres[i]!.id);
      return;
    }
    if (next === null) return;
    e.preventDefault();
    onSelect(genres[next]!.id);
    refs.current[next]?.focus();
  }

  return (
    <div role="listbox" aria-label="Genres" className={styles.list}>
      {genres.map((g, i) => {
        const selected = g.id === selectedId;
        return (
          <div
            key={g.id}
            ref={(el) => {
              refs.current[i] = el;
            }}
            role="option"
            aria-selected={selected}
            tabIndex={selected || (selIdx < 0 && i === 0) ? 0 : -1}
            className={styles.option}
            onClick={() => onSelect(g.id)}
            onKeyDown={(e) => onKeyDown(e, i)}
          >
            <span className={styles.key10} style={{ background: g.color }} aria-hidden="true" />
            <span className={styles.optionName}>{g.name}</span>
            <div style={{ height: 6, background: 'var(--ln2)' }} aria-hidden="true">
              <div style={{ height: 6, width: `${ratio(g.share, max) * 100}%`, background: g.color }} />
            </div>
            <span className="mono" style={{ fontSize: 12, textAlign: 'right' }}>{formatShare(g.share)}</span>
          </div>
        );
      })}
    </div>
  );
}

interface PanelProps {
  genre: GenreCategory;
  artistHref(id: string): string;
  formatCount(n: number): string;
  onClear(): void;
}

/** Selected genre: subgenres and the artists contributing most scrobbles. */
export function GenrePanel({ genre, artistHref, formatCount, onClear }: PanelProps) {
  return (
    <div className={styles.panel} aria-live="polite">
      <div className={styles.panelHead}>
        <h4 className={styles.panelTitle}>{genre.name}</h4>
        <button type="button" className={styles.linkButton} onClick={onClear}>Clear selection</button>
      </div>
      {genre.subgenres.length > 0 && (
        <>
          <div className={styles.panelLabel} id={`sub-${genre.id}`}>Subgenres</div>
          <ul className={styles.tags} aria-labelledby={`sub-${genre.id}`}>
            {genre.subgenres.map((s) => <li key={s}>{s}</li>)}
          </ul>
        </>
      )}
      <div className={styles.panelLabel} style={{ marginTop: 16 }} id={`art-${genre.id}`}>Contributing artists</div>
      {genre.topArtists.length === 0 ? (
        <p className="caption" style={{ padding: '8px 0' }}>No artists in this period.</p>
      ) : (
        <ol aria-labelledby={`art-${genre.id}`} style={{ margin: 0, padding: 0, listStyle: 'none' }}>
          {genre.topArtists.map((a, i) => (
            <li key={a.id}>
              <Link to={artistHref(a.id)} className={styles.artistRow}>
                <span className="mono" style={{ fontSize: 11, color: 'var(--mu)' }}>{i + 1}</span>
                <span>{a.name}</span>
                <span className="mono" style={{ fontSize: 12, textAlign: 'right' }}>{formatCount(a.scrobbles)}</span>
              </Link>
            </li>
          ))}
        </ol>
      )}
    </div>
  );
}

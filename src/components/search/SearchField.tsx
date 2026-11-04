import { useEffect, useId, useMemo, useRef, useState, type KeyboardEvent } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { NotConnectedError } from '../../data/api';
import { useAppData } from '../../data/AppDataContext';
import type { SearchResults } from '../../data/types';
import { useDismiss } from '../../hooks/useDismiss';
import { useLoved } from '../../state/LovedContext';
import { usePeriod } from '../../state/PeriodContext';
import { Heart } from '../ui/Heart';
import { Icon } from '../ui/Icon';
import styles from './SearchField.module.css';

const MIN_QUERY = 2;
const DEBOUNCE_MS = 200;

type SearchState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'done'; results: SearchResults }
  | { status: 'error'; notConnected: boolean };

type Settled = Extract<SearchState, { status: 'done' | 'error' }>;

interface Option {
  id: string;
  group: 'Artists' | 'Albums' | 'Tracks';
  name: string;
  sub: string | null;
  path: string;
  loved?: boolean;
}

function toOptions(r: SearchResults, isLoved: (trackKey: string) => boolean): Option[] {
  return [
    ...r.artists.map((a) => ({ id: `artist-${a.id}`, group: 'Artists' as const, name: a.name, sub: null, path: `/artists/${encodeURIComponent(a.id)}` })),
    ...r.albums.map((a) => ({ id: `album-${a.id}`, group: 'Albums' as const, name: a.name, sub: a.artist, path: `/albums/${encodeURIComponent(a.id)}` })),
    ...r.tracks.map((t) => ({ id: `track-${t.id}`, group: 'Tracks' as const, name: t.name, sub: t.artist, path: `/tracks/${encodeURIComponent(t.id)}`, loved: isLoved(t.id) })),
  ];
}

/** Library search: "/" focuses, arrows move, Enter opens, Escape closes then clears. */
export function SearchField({ className, autoFocus }: { className?: string; autoFocus?: boolean }) {
  const { api } = useAppData();
  const { withPeriod } = usePeriod();
  const { isLoved } = useLoved();
  const navigate = useNavigate();
  const listId = useId();
  const inputRef = useRef<HTMLInputElement>(null);
  const wrapRef = useRef<HTMLDivElement>(null);
  const [query, setQuery] = useState('');
  const [open, setOpen] = useState(false);
  const [settled, setSettled] = useState<{ query: string; result: Settled } | null>(null);
  const [active, setActive] = useState(-1);

  const trimmed = query.trim();
  // Status derives from the query: results only count when they answer the current query.
  const state: SearchState =
    trimmed.length < MIN_QUERY ? { status: 'idle' } : settled?.query === trimmed ? settled.result : { status: 'loading' };
  const options = state.status === 'done' ? toOptions(state.results, isLoved) : [];

  // "/" focuses search from anywhere except text inputs.
  useEffect(() => {
    const onKey = (e: globalThis.KeyboardEvent) => {
      if (e.key !== '/' || e.metaKey || e.ctrlKey || e.altKey) return;
      const t = e.target as HTMLElement;
      if (t.closest('input, textarea, select, [contenteditable="true"]')) return;
      e.preventDefault();
      inputRef.current?.focus();
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, []);

  useEffect(() => {
    if (trimmed.length < MIN_QUERY) return;
    const controller = new AbortController();
    const timer = window.setTimeout(() => {
      api.search(trimmed, controller.signal).then(
        (results) => {
          setActive(-1);
          setSettled({ query: trimmed, result: { status: 'done', results } });
        },
        (err: unknown) => {
          if (!controller.signal.aborted) {
            setSettled({ query: trimmed, result: { status: 'error', notConnected: err instanceof NotConnectedError } });
          }
        },
      );
    }, DEBOUNCE_MS);
    return () => {
      window.clearTimeout(timer);
      controller.abort();
    };
  }, [trimmed, api]);

  const refs = useMemo(() => [wrapRef], []);
  useDismiss(open, () => setOpen(false), refs);

  function go(option: Option) {
    setOpen(false);
    setQuery('');
    navigate(withPeriod(option.path));
  }

  function onKeyDown(e: KeyboardEvent<HTMLInputElement>) {
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      if (!options.length) return;
      e.preventDefault();
      setOpen(true);
      const delta = e.key === 'ArrowDown' ? 1 : -1;
      setActive((i) => (i + delta + options.length) % options.length);
    } else if (e.key === 'Enter') {
      const option = options[active];
      if (option) {
        e.preventDefault();
        go(option);
      }
    } else if (e.key === 'Escape') {
      e.preventDefault();
      e.nativeEvent.stopImmediatePropagation();
      if (open && trimmed) setOpen(false);
      else setQuery('');
    }
  }

  const showPanel = open && trimmed.length >= MIN_QUERY;
  const activeOption = options[active];

  return (
    <div ref={wrapRef} className={`${styles.wrap} ${className ?? ''}`}>
      <label className={styles.field}>
        <Icon name="search" />
        <span className="sr-only">Search artists, albums and tracks</span>
        <input
          ref={inputRef}
          autoFocus={autoFocus}
          type="search"
          role="combobox"
          className={styles.input}
          placeholder="Search artists, albums, tracks"
          autoComplete="off"
          spellCheck={false}
          value={query}
          aria-expanded={showPanel}
          aria-controls={listId}
          aria-autocomplete="list"
          aria-activedescendant={showPanel && activeOption ? `${listId}-${activeOption.id}` : undefined}
          onChange={(e) => {
            setQuery(e.target.value);
            setOpen(true);
          }}
          onFocus={() => setOpen(true)}
          onKeyDown={onKeyDown}
        />
        <span className={styles.kbd} aria-hidden="true">/</span>
      </label>
      {showPanel && (
        <div className={styles.panel}>
          {state.status === 'loading' && <p className={styles.message} role="status">Searching your library</p>}
          {state.status === 'error' && (
            <p className={styles.message} role="status">
              {state.notConnected ? (
                <>Search covers your own listening history. <Link to={withPeriod('/settings#lastfm')}>Connect Last.fm</Link> to use it.</>
              ) : (
                'Search is unavailable right now. Try again in a moment.'
              )}
            </p>
          )}
          {state.status === 'done' && options.length === 0 && (
            <p className={styles.message} role="status">No artists, albums or tracks in your history match "{trimmed}".</p>
          )}
          <ul id={listId} role="listbox" aria-label="Search results" style={{ margin: 0, padding: 0, listStyle: 'none' }}>
            {options.map((o, i) => (
              <li key={o.id} role="presentation">
                {(i === 0 || options[i - 1]!.group !== o.group) && (
                  <div className={`eyebrow ${styles.groupLabel}`} aria-hidden="true">{o.group}</div>
                )}
                <div
                  id={`${listId}-${o.id}`}
                  role="option"
                  aria-selected={i === active}
                  aria-label={`${o.name}${o.sub ? `, ${o.sub}` : ''}, ${o.group.slice(0, -1).toLowerCase()}`}
                  className={styles.option}
                  onPointerDown={(e) => e.preventDefault()}
                  onClick={() => go(o)}
                  onPointerEnter={() => setActive(i)}
                >
                  <span className={styles.optionName}>{o.name}{o.loved && <Heart />}</span>
                  {o.sub && <span className={styles.optionSub}>{o.sub}</span>}
                </div>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}

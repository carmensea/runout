import { useCallback, useRef, useState, type KeyboardEvent } from 'react';
import { addDays, isoWeekOf, isoWeekStart } from '../../lib/dates';

/** Where an arrow key, Home or End moves from `current`, or null to ignore the key. */
export type Move = (current: string, key: string) => string | null;

/**
 * One tab stop for a set of buttons or links (a calendar, the year strip). Arrow keys move between
 * them by `move`; Enter and Space press the focused one as usual. Keys `move` returns that aren't
 * in `keys` are ignored, so focus never leaves the set.
 */
export function useRoving(keys: string[], preferred: string | null, move: Move) {
  const [active, setActive] = useState<string | null>(null);
  const current = active !== null && keys.includes(active) ? active : preferred !== null && keys.includes(preferred) ? preferred : keys[0] ?? null;
  const refs = useRef(new Map<string, HTMLElement>());

  const onKeyDown = useCallback((e: KeyboardEvent) => {
    if (e.altKey || e.ctrlKey || e.metaKey || e.shiftKey) return;
    // The item that has the key press, not only the last one seen focused: focus events don't
    // always arrive (focus set by script, a window without focus).
    const from = [...refs.current].find(([, el]) => el === e.target)?.[0] ?? current;
    if (from === null) return;
    const next = move(from, e.key);
    if (next === null) return;
    e.preventDefault();
    if (!keys.includes(next)) return;
    setActive(next);
    refs.current.get(next)?.focus();
  }, [current, keys, move]);

  const itemProps = (key: string) => ({
    tabIndex: key === current ? 0 : -1,
    ref: (el: HTMLElement | null) => {
      if (el) refs.current.set(key, el);
      else refs.current.delete(key);
    },
    onFocus: () => setActive(key),
  });

  return { onKeyDown, itemProps };
}

/** A strip or grid in reading order, `columns` per row: arrows by position. */
export function gridMove(keys: string[], columns: number): Move {
  return (current, key) => {
    const i = keys.indexOf(current);
    const rowStart = i - (i % columns);
    const next = {
      ArrowRight: i + 1, ArrowLeft: i - 1, ArrowDown: i + columns, ArrowUp: i - columns,
      Home: rowStart, End: Math.min(rowStart + columns - 1, keys.length - 1),
    }[key];
    if (next === undefined) return null;
    return keys[Math.max(0, Math.min(keys.length - 1, next))]!;
  };
}

/** A calendar of dates: left and right a day, up and down a week, Home and End to Monday and Sunday. */
export const calendarMove: Move = (date, key) => {
  switch (key) {
    case 'ArrowRight': return addDays(date, 1);
    case 'ArrowLeft': return addDays(date, -1);
    case 'ArrowDown': return addDays(date, 7);
    case 'ArrowUp': return addDays(date, -7);
    case 'Home': {
      const { isoYear, week } = isoWeekOf(date);
      return isoWeekStart(isoYear, week);
    }
    case 'End': {
      const { isoYear, week } = isoWeekOf(date);
      return addDays(isoWeekStart(isoYear, week), 6);
    }
    default: return null;
  }
};

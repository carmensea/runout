import { useEffect, type RefObject } from 'react';

/** Closes a popover on Escape or on a pointer press outside `refs`. */
export function useDismiss(open: boolean, onDismiss: () => void, refs: Array<RefObject<HTMLElement | null>>) {
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation();
        onDismiss();
      }
    };
    const onPointer = (e: PointerEvent) => {
      if (refs.some((r) => r.current?.contains(e.target as Node))) return;
      onDismiss();
    };
    document.addEventListener('keydown', onKey);
    document.addEventListener('pointerdown', onPointer);
    return () => {
      document.removeEventListener('keydown', onKey);
      document.removeEventListener('pointerdown', onPointer);
    };
  }, [open, onDismiss, refs]);
}

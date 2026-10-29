/** Legend keys matching chart encodings: filled = current, outline = comparison, line = series. */
export function Swatch({ kind = 'fill', color = 'var(--ac)', size = 8 }: { kind?: 'fill' | 'outline' | 'line' | 'hatch'; color?: string; size?: number }) {
  if (kind === 'line') return <span aria-hidden="true" style={{ width: 14, height: 0, borderTop: `2px solid ${color}`, flex: 'none' }} />;
  if (kind === 'outline') return <span aria-hidden="true" style={{ width: size, height: size, border: `1.5px solid ${color}`, flex: 'none' }} />;
  if (kind === 'hatch') return <span aria-hidden="true" style={{ width: size, height: size, background: 'var(--hatch)', outline: '1px solid var(--mu)', outlineOffset: -1, flex: 'none' }} />;
  return <span aria-hidden="true" style={{ width: size, height: size, background: color, flex: 'none' }} />;
}

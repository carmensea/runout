import { useState } from 'react';

/**
 * Artwork from Last.fm / Cover Art Archive only. Fallback: --s2 square with the first
 * letter in Newsreader at about half the box.
 */
export function Artwork({ src, name, size = 36 }: { src: string | null; name: string; size?: number }) {
  const [failed, setFailed] = useState(false);
  const box = { width: size, height: size, flex: 'none' } as const;
  if (src && !failed) {
    return <img src={src} alt="" width={size} height={size} loading="lazy" style={{ ...box, objectFit: 'cover', display: 'block' }} onError={() => setFailed(true)} />;
  }
  return (
    <div
      aria-hidden="true"
      style={{
        ...box,
        background: 'var(--s2)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        fontFamily: 'var(--font-display)',
        fontSize: Math.round(size * 0.5),
        color: 'var(--fg2)',
      }}
    >
      {name.trim().charAt(0).toUpperCase() || '?'}
    </div>
  );
}

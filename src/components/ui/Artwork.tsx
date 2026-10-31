import { useState } from 'react';
import { approvedImage } from '../../lib/artwork';

/**
 * Album artwork from the Cover Art Archive, loaded lazily straight from the archive (no cache or
 * proxy), shown whole within the square. Fallback: --s2 square with the first letter in Newsreader
 * at about half the box.
 */
export function Artwork({ src, name, size = 36 }: { src: string | null; name: string; size?: number }) {
  const [failed, setFailed] = useState(false);
  const box = { width: size, height: size, flex: 'none' } as const;
  const url = approvedImage(src);
  if (url && !failed) {
    return (
      <img
        src={url}
        alt=""
        width={size}
        height={size}
        loading="lazy"
        decoding="async"
        referrerPolicy="no-referrer"
        style={{ ...box, objectFit: 'contain', background: 'var(--s2)', display: 'block' }}
        onError={() => setFailed(true)}
      />
    );
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

/** Runout mark: a record with the needle at the run-out groove. */
export function BrandMark({ size = 24 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" aria-hidden="true">
      <circle cx="16" cy="16" r="13" fill="none" stroke="currentColor" strokeWidth="2.2" />
      <circle cx="16" cy="16" r="3.2" fill="currentColor" />
      <line x1="20.4" y1="11.6" x2="25.2" y2="6.8" stroke="var(--ac)" strokeWidth="2.6" />
    </svg>
  );
}

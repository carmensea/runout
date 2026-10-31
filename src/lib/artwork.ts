// Cover Art Archive thumbnails only (docs/milestone-4-plan.md §10.4): HTTPS on the archive's own
// hosts. Anything else is treated as missing, never loaded.
const APPROVED_HOSTS = ['coverartarchive.org', 'archive.org'];

export function approvedImage(src: string | null): string | null {
  if (!src) return null;
  try {
    const url = new URL(src);
    if (url.protocol !== 'https:') return null;
    return APPROVED_HOSTS.some((h) => url.hostname === h || url.hostname.endsWith(`.${h}`)) ? url.href : null;
  } catch {
    return null;
  }
}

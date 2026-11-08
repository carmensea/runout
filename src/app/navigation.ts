/** Primary navigation (HANDOFF.md "Information architecture and routes"). */
export interface NavItem {
  id: string;
  number: string;
  label: string;
  path: string;
  group: 'listening' | 'planned' | 'settings';
  /** Shown only to accounts with this feature (ConnectionState.features). */
  feature?: string;
}

const ALL_ITEMS: readonly Omit<NavItem, 'number'>[] = [
  { id: 'overview', label: 'Overview', path: '/overview', group: 'listening' },
  { id: 'time', label: 'Time Machine', path: '/time-machine', group: 'listening' },
  { id: 'artists', label: 'Artists', path: '/artists', group: 'listening' },
  { id: 'tracks', label: 'Tracks', path: '/tracks', group: 'listening' },
  { id: 'loved', label: 'Loved', path: '/loved', group: 'listening' },
  { id: 'memories', label: 'Memories', path: '/memories', group: 'listening', feature: 'memories' },
  { id: 'lyrics', label: 'Lyrics', path: '/lyrics', group: 'planned' },
  { id: 'mood', label: 'Mood', path: '/mood', group: 'planned' },
  { id: 'settings', label: 'Settings', path: '/settings', group: 'settings' },
];

/** The navigation an account sees, numbered in order, with flagged features it lacks left out. */
export function navItems(features: readonly string[]): NavItem[] {
  return ALL_ITEMS.filter((i) => !i.feature || features.includes(i.feature))
    .map((i, n) => ({ ...i, number: String(n + 1).padStart(2, '0') }));
}

/** Every item, as an account with every feature sees it. */
export const NAV_ITEMS: readonly NavItem[] = navItems(ALL_ITEMS.map((i) => i.feature ?? ''));

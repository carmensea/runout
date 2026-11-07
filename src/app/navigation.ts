/** Primary navigation (HANDOFF.md "Information architecture and routes"). */
export interface NavItem {
  id: string;
  number: string;
  label: string;
  path: string;
  group: 'listening' | 'planned' | 'settings';
}

export const NAV_ITEMS: readonly NavItem[] = [
  { id: 'overview', number: '01', label: 'Overview', path: '/overview', group: 'listening' },
  { id: 'time', number: '02', label: 'Time Machine', path: '/time-machine', group: 'listening' },
  { id: 'artists', number: '03', label: 'Artists', path: '/artists', group: 'listening' },
  { id: 'tracks', number: '04', label: 'Tracks', path: '/tracks', group: 'listening' },
  { id: 'loved', number: '05', label: 'Loved', path: '/loved', group: 'listening' },
  { id: 'memories', number: '06', label: 'Memories', path: '/memories', group: 'listening' },
  { id: 'lyrics', number: '07', label: 'Lyrics', path: '/lyrics', group: 'planned' },
  { id: 'mood', number: '08', label: 'Mood', path: '/mood', group: 'planned' },
  { id: 'settings', number: '09', label: 'Settings', path: '/settings', group: 'settings' },
];

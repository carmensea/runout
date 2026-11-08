import { useMemo } from 'react';
import { useAppData } from '../data/AppDataContext';
import { navItems } from './navigation';

const NONE: readonly string[] = [];

/**
 * The navigation for the signed-in account: its items, whether it has a feature, and a page's
 * eyebrow ("07 / Lyrics"). `loading` while the account is still unknown, so a page behind a flag
 * can wait rather than say "not found" to someone who has it.
 */
export function useNav() {
  const { connection } = useAppData();
  const features = connection.status === 'success' && connection.data.status !== 'signed_out' ? connection.data.features : NONE;
  const loading = connection.status === 'loading';
  return useMemo(() => {
    const items = navItems(features);
    return {
      items,
      loading,
      has: (feature: string) => features.includes(feature),
      eyebrow: (id: string) => { const i = items.find((x) => x.id === id); return i ? `${i.number} / ${i.label}` : ''; },
    };
  }, [features, loading]);
}

import type { Memory } from '../data/types';
import type { Formatter } from './format';

/** What time a memory is about, in the person's words or as a date, or else when it was written. */
export function rememberedText(m: Memory, fmt: Formatter): string {
  if (m.rememberedLabel && m.rememberedOn) return `${m.rememberedLabel} · ${fmt.date(m.rememberedOn)}`;
  if (m.rememberedLabel) return m.rememberedLabel;
  if (m.rememberedOn) return fmt.date(m.rememberedOn);
  return `Written ${fmt.date(m.createdAt)}`;
}

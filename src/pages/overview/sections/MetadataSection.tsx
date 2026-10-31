import { useState } from 'react';
import { Section } from '../../../components/layout/Section';
import { Icon } from '../../../components/ui/Icon';
import { SegmentedControl } from '../../../components/ui/SegmentedControl';
import type { ArtistKindKey } from '../../../data/types';
import { wholePercentages } from '../../../lib/shares';
import type { SectionProps } from '../view';
import styles from '../../../components/charts/MoreCharts.module.css';
import local from './MetadataSection.module.css';

/** Listed values have colours; missing values are hatched, shown and counted, never dropped. */
const KINDS: ReadonlyArray<{ key: ArtistKindKey; label: string; color: string | null }> = [
  { key: 'female', label: 'Person, listed female', color: 'var(--c2)' },
  { key: 'male', label: 'Person, listed male', color: 'var(--c4)' },
  { key: 'nonbinary', label: 'Person, listed non-binary', color: 'var(--c3)' },
  { key: 'other_gender', label: 'Person, other listed gender', color: 'var(--c5)' },
  { key: 'group', label: 'Group', color: 'var(--c6)' },
  { key: 'orchestra_choir', label: 'Orchestra or choir', color: 'var(--c1)' },
  { key: 'other_type', label: 'Other listed type', color: 'var(--c7)' },
  { key: 'person_unlisted', label: 'Person, gender not listed', color: null },
  { key: 'type_unlisted', label: 'Type not listed', color: null },
  { key: 'not_looked_up', label: 'Not looked up yet', color: null },
  { key: 'not_identified', label: 'Not identified (no MusicBrainz ID)', color: null },
];

type Weighting = 'artists' | 'scrobbles';

const DESCRIPTION = 'Plays and artists by the type and gender listed for each artist on MusicBrainz: a description of the listed artist, not of everyone who made the music. A group counts as a group. Nothing is inferred; values that aren’t listed are shown as missing.';

/** Artist metadata arrives with Milestone 4; until then the section says so instead of showing figures. */
export function MetadataSection(props: SectionProps) {
  if (props.data.metadata === null) {
    return (
      <Section id="demographics" minor eyebrow="06 / Artist metadata" title="Artists by listed gender or type" description={DESCRIPTION}>
        <p className="caption" role="status" style={{ padding: '16px 0' }}>
          Artist metadata isn’t available yet. It comes from MusicBrainz, which Runout doesn’t query yet.
        </p>
      </Section>
    );
  }
  return <MetadataContent {...props} metadata={props.data.metadata} />;
}

function MetadataContent({ view, metadata }: SectionProps & { metadata: NonNullable<SectionProps['data']['metadata']> }) {
  const { fmt } = view;
  const [weighting, setWeighting] = useState<Weighting>('artists');
  const counts = weighting === 'artists' ? metadata.byArtists : metadata.byScrobbles;
  const total = KINDS.reduce((a, k) => a + counts[k.key], 0);
  const percent = wholePercentages(counts);
  const shown = KINDS.filter((k) => counts[k.key] > 0);
  const noun = weighting === 'artists' ? 'artists' : 'scrobbles';

  return (
    <Section
      id="demographics"
      minor
      eyebrow="06 / Artist metadata"
      title="Artists by listed gender or type"
      description={DESCRIPTION}
      actions={
        <SegmentedControl
          size="sm"
          label="Weighting"
          value={weighting}
          onChange={setWeighting}
          options={[{ value: 'artists', label: 'Artists' }, { value: 'scrobbles', label: 'Scrobbles' }]}
        />
      }
    >
      <div className={local.body}>
        <div
          className={styles.shareBar}
          role="img"
          aria-label={`Share of ${noun} by listed gender or type: ${shown.map((k) => `${k.label} ${percent[k.key]}%`).join(', ')}.`}
        >
          {shown.map((k) => (
            <div key={k.key} className={k.color ? undefined : styles.hatch} style={{ flex: counts[k.key], background: k.color ?? undefined }} />
          ))}
        </div>
        <ul className={styles.shareLegend}>
          {shown.map((k) => (
            <li key={k.key}>
              <span className={styles.shareName}>
                <span aria-hidden="true" className={k.color ? undefined : styles.hatch} style={{ width: 10, height: 10, background: k.color ?? undefined }} />
                {k.label}
              </span>
              <span className={styles.shareValue}>
                {fmt.count(counts[k.key])} · {percent[k.key]}%
              </span>
            </li>
          ))}
        </ul>
        {total > 0 && (
          <p style={{ marginTop: 16, fontSize: 13, color: 'var(--fg2)' }}>
            <Icon name="info" size={16} className={local.info} /> Type and gender from{' '}
            <a href={metadata.source.url} target="_blank" rel="noreferrer">{metadata.source.provider}</a> ({metadata.source.license}).
            {metadata.unmatchedArtists > 0 && <> {fmt.count(metadata.unmatchedArtists)} artists have no MusicBrainz ID, so nothing can be looked up for them.</>}
          </p>
        )}
      </div>
    </Section>
  );
}

import { useState } from 'react';
import { Link } from 'react-router-dom';
import { Section } from '../../../components/layout/Section';
import { Icon } from '../../../components/ui/Icon';
import { SegmentedControl } from '../../../components/ui/SegmentedControl';
import type { ArtistKindKey } from '../../../data/types';
import type { SectionProps } from '../view';
import styles from '../../../components/charts/MoreCharts.module.css';
import local from './MetadataSection.module.css';

const KINDS: ReadonlyArray<{ key: ArtistKindKey; label: string; color: string | null }> = [
  { key: 'male', label: 'Male', color: 'var(--c4)' },
  { key: 'female', label: 'Female', color: 'var(--c2)' },
  { key: 'nonbinary', label: 'Nonbinary', color: 'var(--c3)' },
  { key: 'group', label: 'Group', color: 'var(--c6)' },
  { key: 'unknown', label: 'Unknown', color: null },
];

type Weighting = 'artists' | 'scrobbles';

const DESCRIPTION = 'Uses the gender and artist-type fields published by MusicBrainz. Nothing is inferred from names, images or sound. Artists without a published value are counted as unknown.';

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
          aria-label={`Share of ${noun} by listed gender or type: ${KINDS.map((k) => `${k.label} ${fmt.percent(total ? counts[k.key] / total : 0)}`).join(', ')}.`}
        >
          {KINDS.filter((k) => counts[k.key] > 0).map((k) => (
            <div key={k.key} className={k.color ? undefined : styles.hatch} style={{ flex: counts[k.key], background: k.color ?? undefined }} />
          ))}
        </div>
        <ul className={styles.shareLegend}>
          {KINDS.map((k) => (
            <li key={k.key}>
              <span className={styles.shareName}>
                <span aria-hidden="true" style={{ width: 10, height: 10, background: k.color ?? 'var(--mu)' }} />
                {k.label}
              </span>
              <span className={styles.shareValue}>
                {fmt.count(counts[k.key])} · {fmt.percent(total ? counts[k.key] / total : 0)}
              </span>
            </li>
          ))}
        </ul>
        {metadata.unmatchedArtists > 0 && (
          <p style={{ marginTop: 16, fontSize: 13, color: 'var(--fg2)' }}>
            <Icon name="info" size={16} className={local.info} /> {fmt.count(metadata.unmatchedArtists)} artists have no MusicBrainz match yet.{' '}
            <Link to={view.withPeriod('/settings#metadata')}>Review unmatched artists</Link>
          </p>
        )}
      </div>
    </Section>
  );
}

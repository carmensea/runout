import { useEffect } from 'react';
import { Link } from 'react-router-dom';
import { LoadingState, MessageState } from '../../components/states/States';
import stateStyles from '../../components/states/States.module.css';
import { NotConnectedError } from '../../data/api';
import { useAppData } from '../../data/AppDataContext';
import type { ConnectionState, OverviewData } from '../../data/types';
import { useActiveSection } from '../../hooks/useActiveSection';
import { useMediaQuery } from '../../hooks/useMediaQuery';
import { parsePeriod, periodLabel, periodShortLabel } from '../../lib/period';
import { usePeriod } from '../../state/PeriodContext';
import { DiscoverySection } from './sections/DiscoverySection';
import { GenresSection } from './sections/GenresSection';
import { HabitsSection } from './sections/HabitsSection';
import { ListeningSection } from './sections/ListeningSection';
import { MetadataSection } from './sections/MetadataSection';
import { TopSection } from './sections/TopSection';
import { MobileOverview } from './mobile/MobileOverview';
import mobileStyles from './mobile/MobileOverview.module.css';
import { useOverview } from './useOverview';
import type { OverviewView } from './view';
import styles from './OverviewPage.module.css';

const SECTIONS = [
  { id: 'overview', label: 'Overview' },
  { id: 'habits', label: 'Habits' },
  { id: 'genres', label: 'Genres' },
  { id: 'top', label: 'Artists and tracks' },
  { id: 'discovery', label: 'Discovery' },
  { id: 'demographics', label: 'Demographics' },
] as const;

export function OverviewPage() {
  const { connection, fmt, timeZone } = useAppData();
  const { current, compare, today, withPeriod } = usePeriod();
  const connected = connection.status === 'success' && connection.data.status !== 'none';
  const overview = useOverview(current, compare, connected);

  const currentLabel = periodShortLabel(current, today);
  const compareLabel = compare ? periodShortLabel(compare, today) : null;
  const eyebrowPeriod = compareLabel ? `${currentLabel} compared with ${compareLabel}` : periodLabel(current, today);

  useEffect(() => {
    document.title = `Overview · ${periodLabel(current, today)} · Runout`;
  }, [current, today]);

  const view: OverviewView = { fmt, today, timeZone, current, compare, compareLabel, currentLabel, withPeriod };
  const ready = overview.main.status === 'success' && overview.main.data.stats.scrobbles > 0;
  const compact = useMediaQuery('(max-width: 767px)');

  if (compact) {
    // Mobile composition: the page title lives in the top bar (Mobile.dc.html, M1).
    return (
      <main id="main" className={mobileStyles.main}>
        <h1 className="sr-only">Overview, {eyebrowPeriod}</h1>
        <Body connection={connection} overview={overview} view={view} compact />
      </main>
    );
  }

  return (
    <main id="main" className={styles.main}>
      <header className={styles.header}>
        <div>
          <div className="eyebrow">Overview · {eyebrowPeriod}</div>
          <h1 className={styles.title}>Your listening, at a glance</h1>
          <p className={styles.intro}>
            Every scrobble in your Last.fm history for the selected period. Times use your timezone, {timeZone.replace(/_/g, ' ')}.
          </p>
        </div>
        {ready && <SectionNav />}
      </header>

      <Body
        connection={connection}
        overview={overview}
        view={view}
      />

      <footer className={styles.footer}>
        <span>Scrobbles from Last.fm. Artist metadata from MusicBrainz.</span>
        <SyncNote connection={connection.status === 'success' ? connection.data : null} />
      </footer>
    </main>
  );
}

function SectionNav() {
  const active = useActiveSection(SECTIONS.map((s) => s.id));
  return (
    <nav aria-label="Sections" className={styles.sectionNav}>
      <ul>
        {SECTIONS.map((s) => (
          <li key={s.id}>
            <a href={`#${s.id}`} aria-current={active === s.id ? 'true' : undefined}>{s.label}</a>
          </li>
        ))}
      </ul>
    </nav>
  );
}

interface BodyProps {
  connection: ReturnType<typeof useAppData>['connection'];
  overview: ReturnType<typeof useOverview>;
  view: OverviewView;
  compact?: boolean;
}

function Body({ connection, overview, view, compact = false }: BodyProps) {
  const { withPeriod, today, current } = view;

  if (connection.status === 'loading') return <LoadingState label="Checking your Last.fm connection" />;
  if (connection.status === 'error') {
    return (
      <MessageState icon="error" tone="error" message="Runout could not be reached." detail="Your listening data is safe. Check your connection and try again.">
        <div className={stateStyles.actions}>
          <button type="button" className={stateStyles.secondary} onClick={connection.retry}>Try again</button>
        </div>
        <p className={stateStyles.technical}>{connection.error.message}</p>
      </MessageState>
    );
  }
  if (connection.data.status === 'none') {
    return (
      <MessageState
        icon="link_off"
        message="Connect your Last.fm account to see your listening."
        detail="Runout imports your scrobble history from Last.fm and builds every chart on this page from it. Nothing is shown until an account is connected and imported."
      >
        <div className={stateStyles.actions}>
          <Link to={withPeriod('/connect')} className={stateStyles.primary}>Connect Last.fm</Link>
        </div>
      </MessageState>
    );
  }

  const main = overview.main;
  if (main.status === 'loading') {
    return <LoadingState label={`Loading scrobbles for ${periodLabel(current, today)}`} />;
  }
  if (main.status === 'error') {
    if (main.error instanceof NotConnectedError) {
      return <MessageState icon="link_off" message="Your Last.fm account is no longer connected." detail={<Link to={withPeriod('/settings#lastfm')}>Reconnect in Settings</Link>} />;
    }
    return (
      <MessageState icon="error" tone="error" message={`Scrobbles for ${periodLabel(current, today)} could not be loaded.`}>
        <div className={stateStyles.actions}>
          <button type="button" className={stateStyles.secondary} onClick={main.retry}>Try again</button>
        </div>
        <p className={stateStyles.technical}>{main.error.message}</p>
      </MessageState>
    );
  }
  if (main.data.stats.scrobbles === 0) return <EmptyPeriod data={main.data} view={view} importing={connection.data.status === 'importing'} />;

  const vs = overview.compare?.status === 'success' ? overview.compare.data : null;
  const props = { data: main.data, vs, view };
  if (compact) return <MobileOverview {...props} />;
  return (
    <>
      {overview.compare?.status === 'error' && (
        <p className="caption" role="status" style={{ marginTop: 24 }}>
          Comparison figures for {view.compareLabel} could not be loaded. <button type="button" onClick={overview.compare.retry} style={{ border: 0, padding: 0, background: 'none', color: 'var(--fg)', textDecoration: 'underline', fontSize: 'inherit' }}>Try again</button>
        </p>
      )}
      <ListeningSection {...props} />
      <HabitsSection {...props} />
      <GenresSection {...props} />
      <TopSection {...props} />
      <DiscoverySection {...props} />
      <MetadataSection {...props} />
    </>
  );
}

function EmptyPeriod({ data, view, importing }: { data: OverviewData; view: OverviewView; importing: boolean }) {
  const label = periodLabel(view.current, view.today);
  const nearest = data.nearestWithData.flatMap((raw) => {
    const p = parsePeriod(raw);
    return p ? [{ raw, p }] : [];
  });
  return (
    <MessageState
      message={importing ? `Scrobbles for ${label} have not been imported yet.` : `No scrobbles in ${label}.`}
      detail={importing ? 'The import is still running. This period fills in when its pages arrive.' : nearest.length > 0 ? 'Nearest periods with listening:' : undefined}
    >
      {!importing && nearest.length > 0 && (
        <div className={stateStyles.links}>
          {nearest.map(({ raw, p }) => (
            <Link key={raw} to={`/overview?period=${encodeURIComponent(raw)}`}>{periodLabel(p, view.today)}</Link>
          ))}
        </div>
      )}
    </MessageState>
  );
}

function SyncNote({ connection }: { connection: ConnectionState | null }) {
  const { fmt, timeZone } = useAppData();
  if (!connection || connection.status === 'none') return <span>Not synced</span>;
  if (connection.status === 'importing') return <span>Import in progress</span>;
  if (!connection.lastSyncedAt) return <span>Not synced yet</span>;
  return <span>Last synced {fmt.dateTime(connection.lastSyncedAt, timeZone)}</span>;
}

import { useEffect } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { SignIn } from '../../components/auth/SignIn';
import { LoadingState, MessageState } from '../../components/states/States';
import stateStyles from '../../components/states/States.module.css';
import { NotAvailableError, NotConnectedError } from '../../data/api';
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
import { localDaysLabel } from '../../lib/ranges';

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
  // A signed-in account can hold plays without a Last.fm import: Spotify records them directly.
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
        <p className={mobileStyles.credit}><LastfmCredit /></p>
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
        <LastfmCredit />
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
  const { api, auth } = useAppData();
  const [params] = useSearchParams();

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
    const signIn = api.signInUrl();
    const authError = authErrorMessage(params.get('auth_error'));
    return (
      <MessageState
        icon="link_off"
        message="Connect your Last.fm account to see your listening."
        detail="Runout imports your scrobble history from Last.fm and builds every chart on this page from it. Nothing is shown until an account is connected and imported."
      >
        {authError && <p className={stateStyles.technical} role="alert" style={{ color: 'var(--err)' }}>{authError}</p>}
        {auth.status === 'success' && auth.data ? (
          <SignIn lastfmUrl={signIn} />
        ) : (
          <div className={stateStyles.actions}>
            {signIn ? (
              // A full page navigation: the server redirects to Last.fm.
              <a href={signIn} className={stateStyles.primary}>Connect Last.fm</a>
            ) : (
              <Link to={withPeriod('/connect')} className={stateStyles.primary}>Connect Last.fm</Link>
            )}
          </div>
        )}
      </MessageState>
    );
  }
  const main = overview.main;
  if (main.status === 'loading') {
    return <LoadingState label={`Loading scrobbles for ${periodLabel(current, today)}`} />;
  }
  if (main.status === 'error') {
    if (main.error instanceof NotAvailableError) {
      return (
        <MessageState
          icon="hourglass_empty"
          message="Your history is stored in Runout. Charts arrive in the next version."
          detail={<Link to={withPeriod('/settings#history')}>See import and sync status in Settings</Link>}
        />
      );
    }
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
  if (connection.data.status === 'connected' && main.data.stats.scrobbles === 0 && main.data.nearestWithData.length === 0) {
    return (
      <MessageState
        icon="link"
        message={`Signed in as ${connection.data.username}.`}
        detail={<>Your listening history hasn’t been imported yet. <Link to={withPeriod('/settings#history')}>Start the import in Settings</Link>. Charts appear here once it has.</>}
      />
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
      <CoverageNote coverage={main.data.coverage} view={view} />
      <ListeningSection {...props} />
      <HabitsSection {...props} />
      <GenresSection {...props} />
      <TopSection {...props} />
      <DiscoverySection {...props} />
      <MetadataSection {...props} />
    </>
  );
}

/**
 * Part of the period isn't imported: the figures cover imported history only, and the missing
 * dates are listed (docs/milestone-3-plan.md §1, coverage).
 */
function CoverageNote({ coverage, view }: { coverage: OverviewData['coverage']; view: OverviewView }) {
  if (coverage.status === 'complete') return null;
  const shown = coverage.missing.slice(0, 3).map((r) => localDaysLabel(r, view.fmt, view.timeZone));
  const more = coverage.missing.length - shown.length;
  return (
    <p className="caption" role="status" style={{ marginTop: 24 }}>
      Part of this period isn’t imported{shown.length > 0 ? `: ${shown.join(', ')}${more > 0 ? ` and ${more} more` : ''}` : ''}. Figures cover imported
      history only. <Link to={view.withPeriod('/settings#history')}>Import status</Link>
    </p>
  );
}

function EmptyPeriod({ data, view, importing }: { data: OverviewData; view: OverviewView; importing: boolean }) {
  const label = periodLabel(view.current, view.today);
  const nearest = data.nearestWithData.flatMap((raw) => {
    const p = parsePeriod(raw);
    return p ? [{ raw, p }] : [];
  });
  // No scrobbles and nothing imported for the period: unknown, not "no listening".
  const notImported = data.coverage.status === 'none';
  const message = importing || notImported ? `Scrobbles for ${label} have not been imported${importing ? ' yet' : ''}.` : `No scrobbles in ${label}.`;
  const partial = data.coverage.status === 'partial' ? ' Part of this period isn’t imported, so there may be scrobbles that aren’t shown.' : '';
  return (
    <MessageState
      message={message}
      detail={
        importing ? 'The import is still running. This period fills in when its pages arrive.'
          : nearest.length > 0 ? `${partial.trim()}${partial ? ' ' : ''}Nearest periods with listening:`
            : partial.trim() || undefined
      }
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

/** One message per server code (server/app/controllers/api/lastfm_auth_controller.rb). */
const AUTH_ERRORS: Record<string, string> = {
  state: 'That sign-in link expired or was opened in another browser. Try again.',
  denied: 'Sign-in was cancelled or not confirmed on Last.fm. Nothing was changed.',
  lastfm_unavailable: 'Last.fm could not be reached to finish signing in. Try again in a moment.',
  lastfm_rejected: 'Last.fm rejected the sign-in request. Nothing was changed. Try again.',
  server_misconfigured: "Last.fm rejected this server's API key. Check the Last.fm API settings on the server.",
  rate_limited: 'Too many sign-in attempts. Wait a minute and try again.',
  unavailable: 'Signing in with Last.fm is not set up on this server.',
  account_not_allowed: 'This Runout is set up for a different Last.fm account. Sign in with the account it was set up for.',
  relink_required:
    'This Last.fm username does not match the account linked to this Runout. If you renamed your Last.fm account, relink it on the server (see "Relinking after a username change" in server/README.md). Nothing was changed.',
  identity_changed:
    'This Last.fm username now looks like a different account from the one linked to this Runout, so sign-in was stopped. Nothing was changed.',
  identity_unverified: 'Last.fm did not return enough account details to confirm who signed in, so sign-in was stopped. Nothing was changed.',
};

function authErrorMessage(code: string | null): string | null {
  if (!code) return null;
  return AUTH_ERRORS[code] ?? 'Signing in did not complete. Try again.';
}

/** Attribution required by the Last.fm API terms (§2.7). */
function LastfmCredit() {
  return (
    <span>
      Scrobbles from <a href="https://www.last.fm" target="_blank" rel="noreferrer">Last.fm</a>, powered by AudioScrobbler. Artist metadata from MusicBrainz.
    </span>
  );
}

function SyncNote({ connection }: { connection: ConnectionState | null }) {
  const { fmt, timeZone } = useAppData();
  if (!connection || connection.status === 'none') return <span>Not synced</span>;
  if (connection.status === 'connected') return <span>Not synced yet</span>;
  if (connection.status === 'importing') return <span>Import in progress</span>;
  if (!connection.lastSyncedAt) return <span>Not synced yet</span>;
  return <span>Last synced {fmt.dateTime(connection.lastSyncedAt, timeZone)}</span>;
}

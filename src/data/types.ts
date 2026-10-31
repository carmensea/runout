/**
 * Contracts between the UI and the Runout API. All counts are scrobbles (never minutes).
 * Dates are YYYY-MM-DD and bucket keys use the Time Machine grammar
 * (2014 | 2014-03 | 2014-W11 | 2014-03-15), already bucketed in the user's timezone.
 */

/**
 * `attention`: review items and problems that need the owner (never background work or automatic
 * retries). `syncPaused`: the owner paused automatic synchronisation.
 */
export type ConnectionState =
  | { status: 'none' }
  /** Signed in with Last.fm; listening history has not been imported. */
  | { status: 'connected'; username: string; timezone: string }
  | { status: 'importing'; username: string; timezone: string; progress: number; attention?: number }
  | { status: 'synced'; username: string; timezone: string; lastSyncedAt: string; syncPaused?: boolean; attention?: number }
  | { status: 'failed'; username: string; timezone: string; lastSyncedAt: string | null; message: string; attention?: number };

export type ConnectedState = Exclude<ConnectionState, { status: 'none' }>;

export interface ActivityBucket {
  key: string;
  scrobbles: number;
  topArtist: string | null;
}

export interface RankedPeriod {
  /** YYYY-MM-DD for days, YYYY-MM for months. */
  key: string;
  scrobbles: number;
}

export interface OverviewStats {
  scrobbles: number;
  firstScrobbleDate: string | null;
  uniqueArtists: number;
  artistsPlayedOverTen: number;
  uniqueTracks: number;
  tracksPlayedOnce: number;
  uniqueAlbums: number;
  /** Null until artwork is tracked (Milestone 4). */
  albumsWithoutArtwork: number | null;
}

export interface Habits {
  /** 24 values, index = hour 0..23. */
  byHour: number[];
  /** 7 values, Monday first. */
  byWeekday: number[];
  /** 7 rows (Monday first) × 24 hours. */
  byWeekdayHour: number[][];
  /** 12 values, average scrobbles per day for each calendar month, January first. */
  avgPerDayByMonth: number[];
}

export interface ArtistRef {
  id: string;
  name: string;
}

export interface GenreCategory {
  id: string;
  name: string;
  /** Share of scrobbles in the period, 0..1. */
  share: number;
  subgenres: string[];
  topArtists: Array<ArtistRef & { scrobbles: number }>;
}

export interface GenreBreakdown {
  /** Ordered by share, max seven entries mapped to chart slots c1..c7. */
  categories: GenreCategory[];
  /** Share of scrobbles with no mapped tag, 0..1. */
  untaggedShare: number;
  /** Per-year shares keyed by category id; "untagged" holds the remainder. */
  byYear: Array<{ year: number; shares: Record<string, number> }>;
}

export interface TopEntry {
  id: string;
  name: string;
  /** Artist name for albums and tracks. */
  artist: string | null;
  /** Distinct tracks played (artists only). */
  tracksPlayed: number | null;
  imageUrl: string | null;
  scrobbles: number;
  firstScrobble: string;
  latestScrobble: string;
  /** Evenly spaced scrobble counts across the period, oldest first. */
  trend: number[];
}

export type TopKind = 'artists' | 'albums' | 'tracks';

export interface TopLists {
  artists: TopEntry[];
  albums: TopEntry[];
  tracks: TopEntry[];
  totals: Record<TopKind, number>;
}

export interface RankHistory {
  years: number[];
  /** Up to five artists, each with a rank per year (null when outside the top 10). */
  series: Array<ArtistRef & { ranks: Array<number | null> }>;
}

export interface OnRepeatEntry {
  trackId: string;
  name: string;
  artist: string;
  plays: number;
  date: string;
}

export interface ReturnEntry extends ArtistRef {
  awayMonths: number;
  /** YYYY-MM */
  backMonth: string;
}

export interface Discovery {
  months: Array<{ key: string; newArtists: number; explorationShare: number }>;
  firstHeard: Array<ArtistRef & { firstScrobble: string; scrobbles: number }>;
  rediscovered: Array<ArtistRef & { lastYearBefore: number }>;
}

export type ArtistKindKey = 'male' | 'female' | 'nonbinary' | 'group' | 'unknown';

export interface ArtistMetadata {
  byArtists: Record<ArtistKindKey, number>;
  byScrobbles: Record<ArtistKindKey, number>;
  unmatchedArtists: number;
}

export interface OverviewData {
  /** Echo of the requested period, serialised. */
  period: string;
  stats: OverviewStats;
  activity: {
    month: ActivityBucket[];
    year: ActivityBucket[];
    /** Provided only for periods up to two years. */
    week: ActivityBucket[] | null;
  };
  mostActiveDays: RankedPeriod[];
  mostActiveMonths: RankedPeriod[];
  habits: Habits;
  /** Null until genres are available (Milestone 4); never estimated. */
  genres: { broad: GenreBreakdown; sub: GenreBreakdown | null } | null;
  top: TopLists;
  rankHistory: RankHistory;
  onRepeat: OnRepeatEntry[];
  backInRotation: ReturnEntry[];
  discovery: Discovery;
  /** Null until artist metadata is available (Milestone 4); never estimated. */
  metadata: ArtistMetadata | null;
  /** Nearest periods that do have scrobbles, offered when this one is empty. */
  nearestWithData: string[];
  /** Whether the period lies within imported history (docs/milestone-3-plan.md §1). */
  coverage: OverviewCoverage;
}

export interface OverviewCoverage {
  /** complete: all of the period is imported; partial: some; none: none of it. */
  status: 'complete' | 'partial' | 'none';
  /** Ranges with no imported history, as local days. */
  missing: LocalDays[];
}

/**
 * A UTC interval [startsAt, endsAt) as the local calendar days it touches, inclusive
 * (Analytics::Period.local_days on the server, src/lib/ranges.ts here). The end is exclusive: an
 * interval ending at local midnight doesn't touch the next day.
 */
export interface LocalDays {
  from: string;
  to: string;
  startsAt: string;
  endsAt: string;
  /** The first or last day is only partly inside the interval. */
  partialFrom: boolean;
  partialTo: boolean;
}

// ---------- Time Machine (server/app/services/analytics/calendar.rb, plays.rb, on_this_day.rb) ----------

/** The whole history at a glance. `lastDay` is the latest local day with a play, not today. */
export interface HistoryCalendar {
  firstDay: string | null;
  lastDay: string | null;
  years: Array<{ key: string; scrobbles: number }>;
  months: Array<{ key: string; scrobbles: number }>;
  coverage: OverviewCoverage;
}

/** Plays per local day from `from` to `to` (inclusive). Days without plays are left out. */
export interface CalendarDays {
  from: string;
  to: string;
  days: Array<{ date: string; scrobbles: number }>;
  coverage: OverviewCoverage;
}

/** Identity keys as in the Overview; names exactly as scrobbled. */
export interface PlayRef {
  id: string;
  name: string;
}

export interface Play {
  /** Stable per play: same-second plays differ. */
  id: string;
  /** UTC instant, ISO 8601. */
  playedAt: string;
  /** Local date and time in the reporting timezone. */
  date: string;
  time: string;
  artist: PlayRef;
  track: PlayRef;
  album: PlayRef | null;
}

export interface PlaysPage {
  period: string;
  /** Plays in the whole period, not just this page. */
  total: number;
  plays: Play[];
  /** Pass back for the next page; null on the last one. */
  nextCursor: string | null;
  coverage: OverviewCoverage;
}

export interface OnThisDayYear {
  date: string;
  scrobbles: number;
  /** complete: a zero is a day without listening; none: nothing is known about it. */
  coverage: OverviewCoverage['status'];
  topArtists: Array<{ id: string; name: string; scrobbles: number }>;
  topTrack: { id: string; name: string; artist: string; scrobbles: number } | null;
}

export interface OnThisDay {
  date: string;
  /** 29 February: only leap years are listed. */
  leapDay: boolean;
  /** Every other year of the history, newest first. */
  years: OnThisDayYear[];
}

export interface SearchResults {
  artists: ArtistRef[];
  albums: Array<{ id: string; name: string; artist: string }>;
  tracks: Array<{ id: string; name: string; artist: string }>;
}

/* ---- Listening-history import, sync and review (GET /api/import, /api/sync, /api/reviews) ---- */

/** UTC instants, ISO 8601, half-open [from, to). */
export interface PeriodRange {
  from: string;
  to: string;
}

/** What the archive is doing now, as a code the UI words (pages/settings/copy.ts). */
export type HistoryActivity =
  | 'idle' | 'importing' | 'syncing' | 'catching_up' | 'comparing' | 'paused' | 'sync_paused' | 'waiting_for_review' | 'working';

/** Why a period stopped. Codes from the server; see pages/settings/copy.ts. */
export type StopReason =
  | 'attempts_exhausted' | 'budget_exhausted' | 'unstable' | 'malformed_rows' | 'undated_rows' | 'out_of_range_rows'
  | 'too_large' | 'reconciliation_check' | 'incomplete_answer' | 'staging_inconsistent' | 'commit_error' | 'gave_up';

/** A period whose import or check stopped, or whose stored count disagrees. */
export interface ProblemPeriod extends PeriodRange {
  id: number;
  status: 'check_stopped' | 'inconsistent';
  /** Imported before: its plays still count; only its latest check stopped. */
  imported: boolean;
  reason: StopReason | null;
  /** Technical detail, for "Technical details". */
  message: string | null;
  retriesAutomatically: boolean;
  attempts: number;
  httpStatus: number | null;
  lastfmError: number | null;
}

/** A range with no imported plays, between the first period and the last. Never shown as complete. */
export interface MissingPeriod extends PeriodRange {
  state: 'needs_review' | 'retrying_later' | 'importing';
  reason: StopReason | null;
  message: string | null;
}

export interface ImportStatus {
  /** History storage is switched on for this server. */
  enabled: boolean;
  state: 'not_started' | 'planning' | 'running' | 'paused' | 'needs_review' | 'completed' | 'failed' | 'cancelled';
  complete: boolean;
  /** The import has gone quiet; it restarts automatically. */
  stalled: boolean;
  activity: HistoryActivity;
  /** Below 100 until complete; null until Last.fm's total is known. */
  percent: number | null;
  importedScrobbles: number;
  lastfmPlaycount: number | null;
  historyFrom: string | null;
  cutoffAt: string | null;
  currentPeriod: PeriodRange | null;
  periods: { pending: number; processing: number; committed: number; failed: number; review: number };
  startedAt: string | null;
  finishedAt: string | null;
  lastImportedAt: string | null;
  error: string | null;
  failures: ProblemPeriod[];
  missingPeriods: MissingPeriod[];
  attention: number;
  canStart: boolean;
}

export interface SyncRun {
  kind: 'full' | 'sync' | 'catch_up' | 'reconcile' | 'recheck';
  state: string;
  startedAt: string | null;
  finishedAt: string | null;
  checkedFrom: string | null;
  checkedTo: string | null;
  newScrobbles: number;
  error: string | null;
}

export interface SyncHealth {
  enabled: boolean;
  importComplete: boolean;
  connectionState: 'not_started' | 'importing' | 'imported' | 'failed' | null;
  syncPaused: boolean;
  activity: HistoryActivity;
  /** An account problem that stopped synchronisation. */
  message: string | null;
  lastSuccessfulSyncAt: string | null;
  lastAttemptedSyncAt: string | null;
  syncedThrough: string | null;
  /** Where coverage from the first period stops being contiguous. */
  coveredThrough: string | null;
  coverage: PeriodRange[];
  missingPeriods: MissingPeriod[];
  activeRun: SyncRun | null;
  lastRun: SyncRun | null;
  newScrobbles: { lastRun: number; last24Hours: number };
  periods: Record<string, number>;
  awaitingRecheck: number;
  problemPeriods: ProblemPeriod[];
  stalePeriods: number;
  reviews: { disputes: number; suspectedRemovals: number; pendingRemovals: number; reappeared: number };
  attention: { reviews: number; periods: number; account: number; total: number };
  nextDue: { reconcile: string | null; catch_up: string | null; sync: string | null };
}

export interface PlayNames {
  artist: string;
  track: string;
  album: string | null;
}

export interface ReviewPlay extends PlayNames {
  id: number;
  seq: number;
}

export interface ReviewHistoryEntry {
  action: string;
  source: string;
  at: string;
}

interface ReviewItemBase {
  id: number;
  /** The version the decision must name; a changed item is refused, not decided blind. */
  version: string;
  playedAt: string;
  history: ReviewHistoryEntry[];
}

export type ReviewItem =
  /** Missing from Last.fm in two independent checks; removing hides it (it can be restored). */
  | (ReviewItemBase & { kind: 'removal'; play: ReviewPlay; removedAt: null; firstMissingAt: string; confirmedMissingAt: string | null })
  /** Removed earlier, but Last.fm returns it again. */
  | (ReviewItemBase & { kind: 'reappeared'; play: ReviewPlay; removedAt: string; firstMissingAt: string; confirmedMissingAt: string | null })
  /** Plays in one second differ on both sides: a correction, or different plays. */
  | (ReviewItemBase & { kind: 'dispute'; stored: ReviewPlay[]; fetched: Array<PlayNames & { index: number }>; firstSeenAt: string; lastSeenAt: string });

export interface ReviewQueue {
  items: ReviewItem[];
  total: number;
  offset: number;
  /** Seen missing once; waiting for a second independent check before anyone can decide. */
  waiting: number;
}

export type ReviewDecisionName = 'approve' | 'dismiss' | 'restore' | 'keep' | 'resolve';

export interface ReviewDecisionResult {
  result: string;
  /** The item as it is now, or null once it no longer needs review. */
  item: ReviewItem | null;
}

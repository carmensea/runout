/**
 * Contracts between the UI and the Runout API. All counts are scrobbles (never minutes).
 * Dates are YYYY-MM-DD and bucket keys use the Time Machine grammar
 * (2014 | 2014-03 | 2014-W11 | 2014-03-15), already bucketed in the user's timezone.
 */

export type ConnectionState =
  | { status: 'none' }
  | { status: 'importing'; username: string; timezone: string; progress: number }
  | { status: 'synced'; username: string; timezone: string; lastSyncedAt: string }
  | { status: 'failed'; username: string; timezone: string; lastSyncedAt: string | null; message: string };

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
  albumsWithoutArtwork: number;
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
  genres: { broad: GenreBreakdown; sub: GenreBreakdown | null };
  top: TopLists;
  rankHistory: RankHistory;
  onRepeat: OnRepeatEntry[];
  backInRotation: ReturnEntry[];
  discovery: Discovery;
  metadata: ArtistMetadata;
  /** Nearest periods that do have scrobbles, offered when this one is empty. */
  nearestWithData: string[];
}

export interface SearchResults {
  artists: ArtistRef[];
  albums: Array<{ id: string; name: string; artist: string }>;
  tracks: Array<{ id: string; name: string; artist: string }>;
}

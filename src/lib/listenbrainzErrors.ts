import { ApiError } from '../data/api';

const LISTENBRAINZ_ERRORS: Record<string, string> = {
  invalid_token: 'ListenBrainz didn’t recognise that token. Copy it again from listenbrainz.org → Settings.',
  account_taken: 'That ListenBrainz account is already connected to another Runout account.',
  ingestion_disabled: 'ListenBrainz isn’t switched on on this server yet.',
  rate_limited: 'Too many attempts. Wait a minute and try again.',
  unavailable: 'ListenBrainz couldn’t be reached. Try again in a few minutes.',
  not_connected: 'ListenBrainz isn’t connected.',
  too_soon: 'Started moments ago. Give it a minute.',
};

/** The sentence for a ListenBrainz API error code, or a general one. */
export function describeListenbrainzError(e: unknown): string {
  const code = e instanceof ApiError ? e.code : null;
  return (code && LISTENBRAINZ_ERRORS[code]) ?? 'That didn’t work. Check your connection and try again.';
}

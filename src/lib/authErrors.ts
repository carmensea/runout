import { ApiError } from '../data/api';
import { PasskeyCancelledError, PasskeyUnsupportedError } from './webauthn';

const ERRORS: Record<string, string> = {
  passkey_rejected: 'The browser’s passkey wasn’t accepted. Try again.',
  challenge_expired: 'That took too long. Try again.',
  last_passkey: 'This is your only passkey and you have no recovery codes, so it has to stay. Generate recovery codes first.',
  rate_limited: 'Too many attempts. Wait a while and try again.',
};

/** Plain words for a passkey or recovery-code failure in Settings and onboarding. */
export function describeAuthError(e: unknown): string {
  if (e instanceof PasskeyCancelledError) return 'The passkey prompt was closed before it finished.';
  if (e instanceof PasskeyUnsupportedError) return e.message;
  const known = e instanceof ApiError && e.code ? ERRORS[e.code] : undefined;
  if (known) return known;
  return 'That didn’t work. Check your connection and try again.';
}

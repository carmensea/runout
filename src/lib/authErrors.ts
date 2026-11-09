import { ApiError } from '../data/api';
import { PasskeyCancelledError, PasskeyUnsupportedError } from './webauthn';

const ERRORS: Record<string, string> = {
  passkey_rejected: 'The browser’s passkey wasn’t accepted. Try again.',
  challenge_expired: 'That took too long. Try again.',
  last_passkey: 'This is your only passkey and you have no recovery codes, so it has to stay. Generate recovery codes first.',
  rate_limited: 'Too many attempts. Wait a while and try again.',
  confirm_first: 'Confirm it’s you first: sign in again, then make this change.',
  last_method: 'Google is your only way in, so it stays linked. Add a passkey first.',
};

const GOOGLE_ERRORS: Record<string, string> = {
  no_account: 'That Google account isn’t linked to a Runout account. Runout is by invitation: sign in the way you usually do, then link Google in Settings.',
  unavailable: 'That Google account can’t be linked to this Runout account.',
  already_linked: 'This account already has a Google account linked. Unlink it first to use another.',
  confirm_first: 'Confirm it’s you first: sign in again, then link Google.',
  signed_out: 'Sign in first, then link Google in Settings.',
  denied: 'Google sign-in was cancelled.',
  state: 'That took too long, or was started in another browser. Try again.',
};

/** Plain words for what came back from Google (`?google_error=` on the return to the app). */
export function googleErrorMessage(code: string | null): string | null {
  if (!code) return null;
  return GOOGLE_ERRORS[code] ?? 'Google sign-in didn’t complete. Try again.';
}

/** Plain words for a passkey or recovery-code failure in Settings and onboarding. */
export function describeAuthError(e: unknown): string {
  if (e instanceof PasskeyCancelledError) return 'The passkey prompt was closed before it finished.';
  if (e instanceof PasskeyUnsupportedError) return e.message;
  const known = e instanceof ApiError && e.code ? ERRORS[e.code] : undefined;
  if (known) return known;
  return 'That didn’t work. Check your connection and try again.';
}

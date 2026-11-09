# Google sign-in and optional passkeys

Google as a way to sign in to Runout, beside passkeys, and passkeys no longer required of invited
people. Google authenticates; it is never a listening source and no Google data is read.

## 1. Design in one page

- **One more kind of identity, no new system.** A Google account is a row in the existing
  `identities` table: `provider = "google"`, `uid` = Google's stable subject (`sub`), `username` =
  the verified address, shown to its owner in Settings and never used to find or match anything.
  No migration. Sessions, cookies, CSRF protection and `Authentication` are unchanged.
- **OpenID Connect, Authorization Code flow, on the server.** `GET /api/auth/google` sends the
  browser to Google with `scope=openid email`, a random `state` and a random `nonce`, both kept in
  an encrypted, http-only, 10-minute cookie scoped to `/api/auth/google`. Google returns to
  `GET /api/auth/google/callback`; Runout checks the state against the cookie (spent on first use),
  exchanges the code server to server with the client secret, and verifies the ID token with the
  `jwt` library: RS256 signature against Google's published keys, issuer, audience (our client id),
  expiry, and the nonce. Tokens and the secret never reach the browser or the logs.
- **Two intents, fixed when the flow starts** and carried in that cookie:
  - `sign_in`: a Google account already linked to a Runout account opens a session for it. A Google
    account nobody linked signs nobody in and creates nothing.
  - `link`: the signed-in person attaches Google to their own account. The cookie names the account
    that started; the callback requires that same account's session.
- **Invitation-only, unchanged.** No request creates an account. An invited person opens their
  invitation (which signs them in to an empty account), then chooses Google or a passkey on the
  welcome page. The binding is the session the invitation opened: the Google identity is linked to
  that account by the `link` intent, never by an address. The invitation stays open until the
  account has a sign-in method (`User#sign_in_method?`: a passkey, Google or Last.fm), then dies.
- **Passkeys are optional.** Someone who chose Google has no passkey and no recovery codes; codes
  still come with the first passkey. An account can hold Google, passkeys or both.

## 2. Rules the code enforces

| Rule | Where |
|---|---|
| An identity is found only by `sub` | `GoogleSignIn::Account.sign_in` |
| Never merge or claim by address | no code reads `username` for lookup; test "an address is never an account" |
| A Google account linked to another Runout account is refused, nothing moves | `Account.link!` raises `Unavailable` |
| An account's linked Google is never overwritten; unlink first | `Account.link!` raises `AlreadyLinked` |
| The last usable sign-in method stays | `Account.unlink!` (needs a passkey or Last.fm to remain); `PasskeysController#destroy` (needs another passkey, recovery codes or Google to remain) |
| Linking and unlinking need a fresh sign-in (session opened within 10 minutes) | `GoogleAuthController#may_change_methods?`; an invited account with no method yet is exempt, its invitation being its only proof |
| Unlinking ends the account's other sessions | `Account.unlink!` |
| Login CSRF and link confusion | state cookie bound to the browser, single use, 10 minutes; `link` requires the session of the account that started it |
| Operator sessions cannot start, finish or undo a Google flow | `api/google_auth` is in `Authentication::OPERATOR_BLOCKED_CONTROLLERS` (403 on every verb) |
| Errors name nobody | the return carries a short code (`no_account`, `unavailable`, `state`, `failed`, …); a refusal to link says only that this Google account can't be linked here |
| Off unless configured | every route is 404 without `RUNOUT_PASSKEYS_ENABLED` and both Google variables; `GET /api/session` reports `providers.google` |

Fresh sign-in in practice: Settings shows "Confirm it's you" with the passkey or Google itself;
either opens a new session, and the change is tried again.

## 3. Endpoints

| Endpoint | Who | Does |
|---|---|---|
| `GET /api/auth/google?intent=sign_in\|link&return=overview\|settings\|welcome` | anyone (link: signed in, fresh) | sets the state cookie, redirects to Google |
| `GET /api/auth/google/callback` | the browser that started | verifies, then signs in or links; redirects back with `?google=linked` or `?google_error=<code>` |
| `DELETE /api/auth/google` | signed in, fresh | unlinks; 403 `confirm_first`, 409 `last_method` |
| `GET /api/session` | anyone | adds `methods.google`, `methods.googleEmail`, `providers.google` |

## 4. Google Cloud configuration

In the Google Cloud console, one project for Runout:

1. **OAuth consent screen:** user type External; app name Runout; support and developer contact
   addresses that are not personal ones you mind showing; scopes `openid` and
   `.../auth/userinfo.email` only. No sensitive or restricted scopes, so no verification review is
   needed. While the app is in "Testing", only listed test users can sign in; publish it ("In
   production") when invited people outside that list should be able to.
2. **Credentials → Create credentials → OAuth client ID → Web application.**
   - Authorized JavaScript origins: `https://runout.idlewinny.com` (not used by this server-side
     flow, harmless to list); locally `http://localhost:5173`.
   - Authorized redirect URIs, exactly: `https://runout.idlewinny.com/api/auth/google/callback`;
     locally `http://localhost:5173/api/auth/google/callback`. The callback is always on the
     canonical origin (`APP_ORIGIN`): a flow started on the Railway fallback address moves there
     first, so the fallback needs no redirect URI of its own.
3. Copy the client ID and secret into the environment. Never commit them.

## 5. Environment

| Variable | Value |
|---|---|
| `GOOGLE_CLIENT_ID` | the OAuth client ID |
| `GOOGLE_CLIENT_SECRET` | the client secret (server only) |
| `RUNOUT_PASSKEYS_ENABLED` | already `true` in production; Google sign-in is part of Runout's own sign-in and follows it |

Locally both go in `server/.env`. On Railway: `railway variables --service runout --set
GOOGLE_CLIENT_ID=… --set GOOGLE_CLIENT_SECRET=…`, which redeploys. Removing either variable switches
Google sign-in off: the button disappears and the routes answer 404. Linked identities stay in the
table and work again when it is switched back on; people who have only Google need the operator's
recovery link meanwhile, so don't switch it off without telling them.

## 6. Rollout and rollback

1. Merge and deploy: nothing changes for anyone until the two variables are set.
2. Set the variables (the owner's go). The sign-in screen shows "Continue with Google".
3. The owner links their own Google account in Settings → Account → Sign-in and signs in with it once.
4. Invited people may link Google in Settings, and new invitations offer it on the welcome page.

Rollback: delete the variables (above). No data migration either way.

## 7. Not built

- Google as the operator's proof for signing in as someone (`docs/operator-access.md` §3 stays the plan).
- Automatic account creation for any Google account, and any matching by address: by decision.
- Other providers (Apple, GitHub): the identity model would take them the same way.

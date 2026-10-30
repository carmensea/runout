# Milestone 1 acceptance: real Last.fm sign-in

Run on 2026-10-29 against the real Last.fm API, locally (Rails on `localhost:3000`, Vite on
`localhost:5173` proxying `/api`). Account: the configured `LASTFM_ALLOWED_USERNAME`.
No credentials, session keys or tokens were printed or logged; Rails filters `api_key`, `token`,
`state`, `sk` and `api_sig`, and log checks confirmed the API key never appeared.

## Results

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | Real authorization and callback | **Pass** | Redirect to `last.fm/api/auth` with a state-bearing callback; callback verified the state and exchanged the token |
| 2 | `user.getInfo` response | **Finding** | No numeric `id` in JSON or XML, for a public profile and for the signed-in account (signed request). Present: `name`, `url`, `registered` (Unix seconds), `playcount` and other counters. The first attempt failed closed: no account created |
| 3 | Safe parsing without the ID | **Pass, after the identity change below** | The XML has no `id` either, so better parsing cannot help. Identity redesigned (backend-plan §2); usernames never become permanent identifiers |
| 4 | Account creation and connection state | **Pass** | 1 user (Runout UUID), 1 identity (`uid` = normalised username, `registered_at` recorded), 1 connection (`not_started`), 1 session. Session key stored encrypted (Active Record Encryption envelope, no plaintext). Session token stored only as SHA-256. The Overview showed "Signed in as …" |
| 5 | Persistence across reloads | **Pass** | After a reload, `/api/connection` resolved the session (session, user, identity and connection loaded) and the page stayed signed in |
| 6 | Sign-out, then sign-in again, no duplicates | **Pass** | Sign-out returned 204 and the next request was anonymous. Two further sign-ins succeeded. Afterwards: 1 user, 1 identity, 1 connection; only the current session remains |
| 7 | Failed or cancelled authorization | **Partly verified** | Failure: the first attempts (missing ID) showed an error and created nothing. Cancellation: one attempt left for Last.fm and never returned, consistent with Last.fm not redirecting when access is declined; the user stayed signed out and nothing was created. Once Runout is approved, Last.fm returns immediately without an approval screen, so a decline can't be repeated without revoking access, which was out of scope. Callbacks that do return without a token show the `denied` message (covered by automated tests) |

**Check 7 accepted as a known limitation (2026-10-29).** Real cancellation can't be repeated
without revoking access, so it is not a blocker. The automated tests for callbacks that return
without a token (`denied`) and for expired or invalid tokens remain the coverage. The observed
behaviour (no callback from Last.fm, nothing created, still signed out) is safe; the only gap is
that Runout shows no message in that case, because it is never told.

## Identity change made during acceptance

Last.fm exposes no stable account ID, so Milestone 1 now:

- **Allows one configured account.** Sign-in is allowed only for `LASTFM_ALLOWED_USERNAME`; any
  other account gets `account_not_allowed`.
- **Requires agreement.** `auth.getSession` and `user.getInfo` must agree on the username;
  otherwise `identity_unverified`.
- **Checks the registration time.** It must be present and match the stored value on every
  sign-in; otherwise `identity_changed`. It is never a lookup key and never grounds for a merge.
- **Never creates a second user.** In single-account mode a different username gets
  `relink_required`. Recovery is the operator's `bin/rails "lastfm:relink[old,new]"` followed by a
  fresh sign-in.
- **Gives each failure an accurate message.** "Last.fm could not be reached" is now used only for
  real outages.

## Not verified here

- Behaviour after a real Last.fm username change (not something we can trigger). Covered by
  automated tests of the refusal and the relink task.
- Production deployment (Render, Neon). Milestone 5.

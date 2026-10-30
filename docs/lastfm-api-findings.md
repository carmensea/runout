# Last.fm API findings (Milestone 2, Stage 2.0)

Verified 2026-10-29 against the live API with `bin/rails lastfm:probe` and one structure check.
Account: the configured `LASTFM_ALLOWED_USERNAME` (public profile, about 209,000 scrobbles since
2004).

The probe is read-only:
- it stores nothing and holds every response in memory only;
- it prints only booleans and counts;
- it used 11 requests, at least 1.25 s apart.

No credentials, session keys or track data were printed or logged.

## Results

| # | Question | Finding | Consequence |
|---|---|---|---|
| A1 | Count information | `@attr` has `page`, `perPage`, `totalPages` **and `total`**, all as strings. The documentation's sample shows no `total`. `totalPages = ceil(total / limit)` at `limit=200`; at `limit=1`, `totalPages = total`. `total` was unchanged between two reads | Verification and reconciliation can use `total` directly; `limit=1` also works as a cheap count |
| A2 | Range boundaries | **`from` is inclusive, `to` is exclusive.** `from = to` returns nothing. Single-page ranges: `total` equals the rows returned | The API natively uses half-open `[from, to)` windows, so the overlap and filter step planned in §4.2 is no longer needed. The plan keeps the in-window filter as a defensive check only |
| A3 | Ordering and stability | Newest first within pages and across pages. A historical page was identical on a second read. One same-second pair seen in a 379-row sample | Confirms paging by `totalPages` and the `seq` design for same-second plays |
| A4 | Now playing | Not present during the probe (nothing playing). Not seen on pages other than page 1. Synthetic tests cover its shape: `@attr.nowplaying = "true"`, no `date` | Parser excludes it; undated rows are counted, never dropped silently |
| A5 | Signed versus unsigned | A request signed with the session key returned the same `total` and newest play as an unsigned one. This profile is **public**, so private-profile behaviour is still **unverified** | Sign sync requests anyway (no cost). Revisit if a private profile is ever used |
| A6 | Rename behaviour | Not testable on demand | Covered by the account verification design (plan §5.1): a mismatch stops sync until an explicit relink |
| A7 | Rate limits | No rate limiting during 11 requests at 1.25 s intervals. The limit itself was **not** measured: no burst testing, by design | Keep the plan's default of about 1 request per second, and back off on error 29 or HTTP 429 |
| A8 | Back-dating limit | Not testable safely | Keep the 14-day catch-up window as an assumption |

## Other observations

- **Single result:** with `limit=1`, `track` is still an array. The parser also accepts a single
  object, a known Last.fm quirk elsewhere.
- **Past the last page:** a page beyond `totalPages` returns no rows (not a repeat of the last
  page), with `page` echoed back. Loops must stop on `totalPages`, not on an empty page.
- **Empty range:** returns `total: 0` and `totalPages: 0`.
- **No caching or rate headers.** There is no `Cache-Control`, `Expires`, `Age`, `Retry-After` or
  `X-RateLimit-*` header. The ToS asks for caching "in accordance with the HTTP headers"
  (§4.3.4), and there are none to follow. This is worth mentioning in the permission email.
- **Metadata coverage** (379-row sample, oldest and newest pages):
  - 66% of plays have an artist MBID, 66% a track MBID, 57% an album MBID;
  - 75% have an album name.

  Name-based catalogue matching (plan §6.4) will carry a large share of resolution.
- **Storage estimate for this account:** about 209,000 scrobbles at 150 to 200 bytes each
  (including indexes) is roughly **31 to 42 MB of scrobble rows, before name variants and the
  catalogue**. Still an estimate; Stage 2.9 measures it.

## Not verified

- Private-profile behaviour (A5), username changes (A6), the actual rate limit (A7) and the
  back-dating limit (A8).
- Behaviour under concurrent new scrobbles during a long fetch. The plan's two-read verification
  (§4.3) is designed for it; Stage 2.3 tests it against the synthetic server.

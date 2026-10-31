# Runout long-term architecture: an independent listening archive

Status: **direction, not built.** Recorded 2026-10-30. Nothing here is implemented, and nothing
here changes the working Last.fm import and sync (Milestone 2). The current roadmap is finished
first; new ingestion sources come after it (§9).

## 1. Product direction

Runout starts as an archive of Last.fm history. It is meant to become an independent scrobbling
service that can replace Last.fm entirely:

- **Runout's PostgreSQL database is the authoritative record** of the owner's listening history.
- **Last.fm becomes one optional import source**, alongside Spotify, other streaming services,
  local players and Runout's own ingestion API.
- **Core features work on Runout's own data only:** analytics, Time Machine, artist and track
  history, genres, listening patterns, and later lyrics search and mood analysis. None of them
  may call Last.fm, or any other music service, to answer a request.
- **Disconnecting a source loses no history.** The owner keeps 20+ years of listening history and
  keeps adding to it after Last.fm is gone.
- **The owner controls the archive:** a complete export in a documented format, backups that can
  be restored, and an import path for the export. Replacing one vendor lock-in with another is a
  failure.

## 2. Principles for every future change

1. **Store what each source said, then derive.** Each source's report of a play is kept as it
   arrived (its fields, timestamp convention, identifiers). The canonical listening event and its
   catalogue links are derived from those reports, and can be derived again.
2. **No assumption that sources agree.** Sources differ in timestamps (start or end of play),
   precision, identifiers, metadata and completeness. Code states which convention it relies on.
3. **Never merge or discard silently.** Cross-source duplicates are linked only on reliable
   evidence; ambiguous cases go to review, as reconciliation disputes do today.
4. **Legitimate repeats survive.** Two plays of the same track remain two events, whatever the
   source. One-to-one matching, never set-based collapsing.
5. **Coverage is per source and explicit.** "Complete" means something different for a verified
   Last.fm month than for a Spotify poll; analytics say which periods are known to be complete.
6. **Licensing gates are per source.** A source's terms decide what Runout may keep from it; the
   owner's directly scrobbled data isn't gated by Last.fm's terms.

## 3. Licensing and terms (unresolved; decide before building)

| Question | Why it matters | Status |
|---|---|---|
| **Last.fm API ToS §9.3: "Delete all Last.fm Data on termination."** | §9.3 applies when the **API agreement is terminated**. Stopping API calls, disconnecting Last.fm in Runout, or cancelling a Last.fm subscription does not by itself necessarily terminate that agreement, so these are separate questions. What happens to history obtained through the API if the agreement is terminated (by either side), and whether any of it may be kept, is not established here. | **Unresolved, highest risk.** Asked as question 7 in `docs/lastfm-permission-email.md`. No retention right is assumed. A personal-data (data portability) export of the owner's own scrobbles may be a different basis for keeping a copy; whether it is, is also unconfirmed. Not legal advice. |
| Last.fm storage cap and caching (§4.3.4) | Already gating Milestone 2 (`LASTFM_HISTORY_STORAGE_ENABLED`). | Unresolved (permission email). |
| Spotify Developer Terms | Storage of Spotify data, display and attribution rules, development-mode user limits, restrictions on machine-learning use of Spotify content (relevant to mood analysis). | **To review** before the Spotify milestone. |
| Spotify audio features | Spotify restricted audio features and analysis for new Web API apps (announced November 2024). Mood analysis can't assume them. | **To verify** for Runout's app. |
| Lyrics | Lyrics are licensed content; search over them needs a licensed provider or the owner's own files. | To decide in the lyrics milestone. |
| MusicBrainz | Core data is CC0; it can be mirrored, so metadata needn't depend on a live service. | Low risk. |

## 4. Sources and their real limits (assumptions to verify before each build)

| Source | What it can provide | Limits to design around |
|---|---|---|
| **Last.fm API** (built) | Full history by time window, verified by pagination totals. Second-precision start timestamps; names and MusicBrainz IDs; no event ID. | Terms (§3). Plays can be edited or deleted upstream; no stable account ID. |
| **Last.fm personal data export** (possible) | The owner's own history, outside the API. | Format, completeness and availability to verify. |
| **Spotify Web API, recently played** | The last 50 played tracks, cursor-paged by time; a `played_at` timestamp; Spotify track, artist and album IDs, and ISRC. | No history beyond the last 50; polling only (no push or webhooks); whether `played_at` marks the start or the end of a play, and how offline plays appear, must be measured; tracks only. Missing a poll window loses plays: polling must run more often than 50 tracks are played. |
| **Spotify extended streaming history** (account privacy download) | Full history: end timestamp, milliseconds played, track URI, names, skip, offline and shuffle flags. | Manual request with a delay of days to weeks; one-off files, not a feed; format to verify against a real download. |
| **Scrobble ingestion API** (Runout's own) | Any player that can submit listens. Proposed: a ListenBrainz-compatible submission endpoint, since many players and tools already support configurable ListenBrainz servers (prior art: Maloja, multi-scrobbler). | Client support per player to verify; Last.fm-protocol compatibility is a separate, older option. |
| **Local players / companion app** | Plays from players without a network integration. | Build only if an existing client or bridge can't cover it. |

Background collection never depends on the website being open: polling and ingestion run in
Solid Queue jobs and API endpoints, as sync does today.

## 5. Unified listening-event model (proposed schema; not implemented)

The existing `scrobbles` table stays the canonical event (renaming it would rewrite every query
and index for no benefit). What changes is that each event gains **observations**: the reports
from sources that attest it.

**`listen_sources`**: one row per connected source per user.
`user_id`, `kind` (`lastfm`, `lastfm_export`, `spotify`, `spotify_history_file`,
`ingestion_api`, `runout_export`), `external_account_id`, `display_name`, `state`,
`connected_at`, `disconnected_at`, `settings` (jsonb). `lastfm_connections` becomes the Last.fm
row's detail (kept, not rewritten).

**`scrobble_observations`**: one row per source report of a play.

| Column | Notes |
|---|---|
| `scrobble_id` | The canonical event it attests (null while a duplicate decision is pending) |
| `user_id`, `listen_source_id` | |
| `source_event_id` | The source's own ID when it has one; unique per source when present |
| `reported_at`, `timestamp_kind` | The source's timestamp at full precision, and whether it marks the start or end of the play |
| `ms_played`, `duration_ms` | When the source reports them, so a "counted play" rule can be applied again later |
| `name_variant_id` | The exact strings this source sent (shared, immutable, as today) |
| `external_ids` | jsonb: Spotify URIs, ISRC, MBIDs as sent |
| `raw` | jsonb: the original payload, minimised to what the format documents |
| `ingestion_batch_id`, `received_at` | Provenance and idempotency |
| `link_state`, `linked_by` | `linked`, `pending_review`, `rejected`; `rule` or `person` |
| `retracted_at` | The source stopped reporting it (today's "missing upstream") |

**`ingestion_batches`**: one per Last.fm fetch, API submission or file import, with an idempotency
key, so a resent batch is applied once.

**`listen_match_reviews`**: ambiguous cross-source cases, with evidence, like
`reconciliation_disputes` (open, resolved, dismissed, superseded; audited in `review_decisions`).

**Catalogue:** `catalogue_external_ids` (`entity_type`, `entity_id`, `provider`, `external_id`;
unique per provider and type) for Spotify IDs and ISRCs. `name_variants` stays exact strings plus
MBIDs; source-specific IDs are not added to its hash.

**Ingestion credentials:** `api_tokens` (`user_id`, `token_digest`, `scopes`, `last_used_at`,
`revoked_at`).

**Canonical event fields:** `played_at` remains the canonical start time in UTC at second
precision, with `seq` slots, so today's identity, indexes and analytics keep working. The
displayed names come from a configurable precedence among a play's observations; canonical
artist and track links come from Stage 2.5 matching, improved by external IDs.

**Migration path (additive):** create one observation per existing scrobble, attributed to the
user's Last.fm source and to the fetch in `first_seen_fetch_id`, with the original strings from
`scrobble_corrections` where a correction was applied. No user account and no existing row
changes owner.

## 6. Cross-source deduplication

During the transition the same play may arrive from Last.fm (via Spotify's own Last.fm scrobbling)
and from Spotify directly.

1. **Same source, same event ID:** the same observation; idempotent.
2. **Candidate match:** another source's observation of the same track (same canonical track, or
   same ISRC or Spotify ID, or identical normalised names when nothing better exists), whose
   *start* time (computed from the source's convention, for example end time minus
   `ms_played`) falls within a tolerance of the event's start. Tolerances are measured from real
   data per source pair, not assumed.
3. **One-to-one assignment in time order.** Each observation attests at most one event and each
   event at most one observation per source, so repeated plays stay separate.
4. **Ambiguity goes to review:** several candidates within tolerance, conflicting names, or counts
   that don't line up. Nothing is merged or dropped automatically.
5. **Retractions are per observation.** When Last.fm stops reporting a play that Spotify still
   attests, the Last.fm observation is retracted; the event stays. An event with no remaining
   observation follows today's removal rules (two independent checks, then a person approves).

## 7. Independent authentication

Users, sessions and history already belong to Runout's own UUIDs; identities are rows with a
`provider` (backend-plan §2). That makes this additive:

- Add a Runout-native credential as another identity provider: passkeys (WebAuthn) first, with
  recovery codes. Email and password only if needed; no third-party identity provider required.
- Link it to the existing user while signed in with Last.fm; then Last.fm sign-in can be removed
  without touching history.
- Replace Last.fm-specific checks: the allowlist (`LASTFM_ALLOWED_USERNAME`) becomes per
  provider, and account deletion's confirmation stops requiring the Last.fm username.

## 8. Data ownership and portability

- **Export:** a "Runout listening archive" format, versioned and documented: a manifest (format
  version, export time, counts, checksums), listens as JSON Lines with their observations and
  provenance, the catalogue with MusicBrainz and external IDs, review decisions and corrections,
  and coverage per source. A CSV convenience export alongside it.
- **Stable export IDs:** listens need a stable public ID (a UUID column) so re-importing an export
  is idempotent; `scrobbles.id` alone is a database detail.
- **Import of an export:** into an empty or existing archive, idempotent by public ID and
  `(source, source_event_id)`; conflicts go to review; nothing is overwritten.
- **Backups:** scheduled `pg_dump` to storage the owner controls (not only the hosting provider's
  point-in-time recovery), encrypted, with a documented and tested restore drill.
- **Acceptance test:** export, restore into an empty instance, export again: identical archives.
- Data obtained under a service's terms stays subject to them (§3), including in exports.

## 9. What in today's design would make this harder, and when to change it

**Update 2026-10-31:** #1, #2 (Last.fm side), #5 (for new sources) and #10 are addressed by the
Spotify work (`docs/spotify-plan.md` §2, §5).

| # | Current decision | Impact on the direction | Severity | Change in |
|---|---|---|---|---|
| 1 | One flag, `LASTFM_HISTORY_STORAGE_ENABLED`, gates **all** history models (`HistoryStorage`) | Directly scrobbled data would be blocked by Last.fm's licensing | High | Source model milestone: one gate per source |
| 2 | The reconciler compares a Last.fm snapshot with **every** stored play in the range | With a second source it would propose removing plays Last.fm never had, and insert duplicates of plays another source recorded | **High (correctness)** | Before any second source: reconcile against Last.fm observations only; link instead of insert when §6 matches |
| 3 | Sign-in is Last.fm only; the allowlist and account-deletion confirmation use the Last.fm username; `ConnectionState` is "none" without a Last.fm identity | Can't stop using Last.fm | High | Independent authentication milestone (§7) |
| 4 | Frontend states and HTTP 409 mean "no Last.fm account connected" | Wording and flows assume Last.fm | Medium | With §7; the API should describe sources generically |
| 5 | `scrobbles` has no source column; provenance is `first_seen_fetch_id` (a Last.fm fetch) | No record of which source attests a play | Medium | Observations (§5), backfilled additively |
| 6 | Removals mean "missing from Last.fm" | Retraction must be per source | Medium | With #2 |
| 7 | Coverage is the union of Last.fm import windows; windows start at the Last.fm registration month | "Complete" is Last.fm-specific | Medium | Coverage per source; analytics label completeness |
| 8 | Milestone 4 planned genres from Last.fm artist tags | Genre analysis would depend on Last.fm | Medium | Milestone 4: MusicBrainz genres and tags first, Runout's own taxonomy; Last.fm tags optional and licence-gated |
| 9 | `played_at` at second precision; `seq` slots | Fine for the canonical event; sub-second precision belongs to observations | Low | — |
| 10 | `name_variants` holds Last.fm's six fields | Spotify IDs and ISRCs don't fit | Low | `catalogue_external_ids` (§5) |
| 11 | `import_runs` and `import_windows` are Last.fm machinery | Fine: they stay the Last.fm importer's | Low | Add a source reference when §5 lands |
| 12 | Analytics (Milestone 3) not built yet | An opportunity: build on canonical events and catalogue links only, never on Last.fm API calls or Last.fm-specific fields | — | Milestone 3 rule |

Things that already fit: Runout-owned UUIDs for users; history owned by `user_id`, not by a
username; provider-typed identities; a shared, immutable catalogue of exact strings with
canonical links; audited, never-silent review decisions; account deletion that cascades.

## 10. Order of work (proposed)

1. Finish Milestone 2 (Stage 2.8), then Milestones 3 to 5 as planned, applying rules #8 and #12.
2. **Data ownership early:** export, backup and restore before the archive becomes the only copy.
3. **Independent authentication** (§7).
4. **Source-independent events** (§5): migration and backfill, per-source licensing gates, and the
   reconciler change (#2). No new source yet; Last.fm behaviour unchanged, proven by the existing
   suites.
5. **Spotify:** extended-history file import first (bounded, offline, best for deduplication
   tuning), then recently-played polling with gap detection.
6. **Scrobble ingestion API** (ListenBrainz-compatible), then a companion app only where needed.
7. **Last.fm optional:** disconnect without loss, once §3 allows keeping the history.

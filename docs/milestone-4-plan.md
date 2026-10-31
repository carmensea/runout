# Milestone 4 plan: genres, artist metadata and artwork

Status: **approved 2026-10-31**, with the owner's decisions in §10. Implementation in progress. It extends the approved taxonomy design
(`docs/backend-plan.md` §6) and the long-term rule that genres must not depend on Last.fm
(`docs/long-term-architecture.md` §9, #8).

## 1. What the catalogue can support today (measured 2026-10-31)

Read-only, from the imported history (209,383 plays), after the duplicate-artist correction:

| | |
|---|---|
| Plays by an artist with a MusicBrainz ID | 176,629 (84.4%), across 7,266 artists |
| Plays by name-only artists | 15.6%, across 3,987 artists: no ID, so nothing can be looked up without guessing |
| Artists needed for 50 / 80 / 90 / 95% of identified-artist plays | 268 / 1,092 / 1,891 / 2,839 |
| Plays with a release MusicBrainz ID | 135,026 (64.5%), across 11,890 releases |
| Releases needed for 50 / 80 / 90 / 95% of those plays | 693 / 2,313 / 3,990 / 6,144 |
| Plays with no album name at all | 3.5% |

A small live sample (30 artists, 20 releases; one request per second, public IDs only, nothing
stored), indicative only:

| Sample | Found | Has genres | Other fields |
|---|---|---|---|
| Your top 15 artists | 15 / 15 | 14 | Type on all (11 groups, 4 people); gender on every person; area on all; Wikidata link on 14 |
| 15 random identified artists | 14 / 15 | 8 | Type on 13; gender on 5 of 6 people; Wikidata link on 7 |
| Your top 10 releases | 10 / 10 | 9 (release group) | Front artwork on all 10: 6 on the release, 4 only on its release group |
| 10 random releases | 9 / 10 | 5 (release group) | Front artwork on 6; one release ID is gone (merged or deleted upstream) |

Because listening is concentrated on well-documented artists, expect very roughly three quarters of
plays to get a genre and artwork from MusicBrainz and the Cover Art Archive alone. The long tail
will stay "unclassified" or "no artwork" more often. Stage 2 measures the real figures.

## 2. Sources

| Source | Provides | Licence and terms | Limits | Use |
|---|---|---|---|---|
| **MusicBrainz API** | Artist type, gender, area, life span; curated **genres** and free-form **tags** with vote counts on artists, release groups and recordings; links to Wikidata and Discogs | Core data CC0. Tags and genres are "supplementary data", **CC BY-NC-SA 3.0**: fine for a personal, non-commercial archive with attribution, but not for a commercial product | 1 request per second per IP, with an identifying User-Agent; crowd-sourced, uneven in the long tail | **Primary**, from Stage 2 |
| **Cover Art Archive** | Front and back images for releases and release groups, with 250, 500 and 1200 px thumbnails | Images remain their rights holders' copyright; the archive serves them for display. Runout links to them and doesn't store copies; credit "Cover Art Archive" | Redirects to archive.org; can be slow; no artwork for many small releases | Album artwork, Stage 4 |
| **Wikidata / Wikimedia Commons** | Artist images (P18) | Wikidata CC0; each Commons file has its own licence (often CC BY-SA), whose author and licence must be shown | Image on about half of the sampled artists; quality varies | Optional artist images, Stage 4, only with licence and credit shown |
| **Discogs** | Release genres and styles (a good taxonomy) | Data dumps CC0; the API needs a token; images aren't redistributable | Needs Discogs IDs (MusicBrainz often links them) | **Not in Milestone 4.** A possible later second genre source |
| **Last.fm tags** | Artist and track tags | Last.fm terms (unresolved) | Would tie genres to Last.fm | **Off.** Optional and licence-gated, as already decided |
| **Spotify** | Artist genres, images | Developer terms restrict storage and caching; artist genres reported thin for new apps (to verify) | Needs the Spotify milestone first | Not in Milestone 4 |

Everything is keyed by MusicBrainz IDs, so direct scrobbling (Spotify, players, Runout's own
ingestion API) gets the same metadata once a play is matched to the catalogue. No source is
asked anything about listening history.

## 3. Taxonomy and classification

**Tables** (as in `docs/backend-plan.md` §6, plus `source`):
- `tags`: original strings, never discarded.
- `entity_tags`: artist and release-group tags.
- `genres`: broad genres and their subgenres.
- `tag_genre_mappings`: weight 0–1, origin `seed`, `musicbrainz` or `manual`; one tag may map to several genres.
- `taxonomy_settings`: tuning values.

Seeds come from `server/db/seeds/taxonomy.yml` and never overwrite `manual` rows.
`rake taxonomy:unmapped` lists unmapped tags by the plays they cover.

**Broad genres** (seeded and editable; about 14, chosen to fit an indie-heavy history):
- Rock; Indie & alternative; Pop; Electronic; Hip hop; R&B & soul; Folk & country;
- Metal; Punk & hardcore; Jazz & blues; Classical; Soundtrack & stage; Latin & world;
- Experimental & ambient.

**Subgenres** are MusicBrainz's curated genre names (for example `indie rock`, `emo`, `synth-pop`,
`shoegaze`), each mapped to one or more broad genres with weights. For example, `indie rock` maps
0.5 to Indie & alternative and 0.5 to Rock, and `indie pop` maps 0.5 and 0.5 to Indie & alternative
and Pop. MusicBrainz's own "subgenre of" relationships propose parents for new genre names, as
`musicbrainz` mappings you can review.

**What counts as a genre signal**
- MusicBrainz **genres** (its curated vocabulary) on the release group, otherwise the artist.
- Free-form MusicBrainz **tags** are stored but count only once a mapping exists for them, so
  noise such as "seen live" never becomes a genre.

**Weighting** (unchanged from §6, so the arithmetic is transparent and consistent)
1. An item's tag weight is its vote count scaled to its strongest tag (strongest = 100). Tags below
   `min_tag_weight` are dropped.
2. Broad score `S(x,g) = Σ w(x,t) · m(t,g)`.
3. If the mapped total is at least `min_mapped_weight`, then `p(x,g) = S(x,g) / Σ S`; otherwise the
   item is Unclassified.
4. Each play takes its release group's distribution when that has enough mapped weight, otherwise its
   artist's. **Every play contributes exactly 1**, split across broad genres and Unclassified.
5. A period's share of genre g is `Σ p(s,g) / N`. Broad genres plus Unclassified add up to exactly
   100%, with largest-remainder rounding. Subgenres split their broad genre's share, so they also
   total 100%.

**Two different numbers, never confused**
- **Share** (allocated, mutually exclusive): used for the stacked chart, the genre list and "by
  year". It always adds up to 100%.
- **Reach** (overlapping): "34% of your plays were by artists with any indie rock". Shown only as a
  sentence or a single bar in a genre's drill-down, captioned "artists can have several genres, so
  these overlap". Never stacked, never in a pie, never summed.
- Contributing artists and tracks are ranked by allocated plays (fractional, rounded for display,
  and captioned so).

## 4. Artist metadata ("demographics")

From MusicBrainz only, as published. Nothing is inferred from names, members, vocalists, images or
sound.

| Shown as | From MusicBrainz |
|---|---|
| Person: male / female / non-binary / other gender | type Person (or Character) with that gender |
| Person, gender not listed | type Person, no gender |
| Group | type Group, regardless of its members |
| Orchestra or choir | type Orchestra or Choir |
| Character / Other type | as published |
| Type not listed | found, but no type |
| Not identified | no MusicBrainz ID (name-only artists): unknown, not "none" |

Area (country) and active years come from the same record, shown only where present. Counts are
offered by artists and by plays, as the section already does. The frontend's `ArtistKindKey` grows
to these categories.

## 5. Enrichment of the existing catalogue

**Scope**
- Identified artists (7,266) and played releases (11,890), most-played first, so the Overview
  improves early: about 1,100 artists in the first 20 minutes cover 80% of identified-artist plays.
- Name-only artists are never looked up by name automatically. That would guess. They stay "Not
  identified" or "Unclassified". A later, optional review step could offer MusicBrainz search
  candidates for you to confirm, like catalogue reviews today.

**Requests**

| Request | Host | Count |
|---|---|---|
| Artist: `artist/{mbid}?inc=genres+tags+url-rels` | musicbrainz.org | 1 per identified artist |
| Release group with genres: browse `release-group?release={mbid}&inc=genres` | musicbrainz.org | 1 per played release |
| Front artwork: `coverartarchive.org/release/{mbid}`, falling back to `release-group/{id}` | coverartarchive.org (separate host) | 1–2 per played release |
| Optional artist image: one Wikidata and one Commons lookup | wikidata.org, commons.wikimedia.org | 2 per artist with a Wikidata link, only if approved |

- **First run:** about 19,000 MusicBrainz requests at one per second, about 5½ hours of background
  time. The Cover Art Archive runs alongside on its own host. Useful coverage comes within the first
  hour.
- **Afterwards:** a handful of requests a day for newly played artists and releases. Each item is
  refreshed about every 180 days, staggered (about 40 artists and 65 releases a day).

**Jobs**
- Solid Queue (already there), with no new infrastructure:
  - a recurring `MetadataEnrichJob` works through a queue table (`metadata_fetches`: entity, source,
    status, attempts, next fetch, ETag);
  - pacing per host reuses the request slots built for Last.fm.
- Resumable and idempotent. 503 and rate-limit answers back off.
- Retired or merged IDs follow MusicBrainz's redirect and record the new ID. A 404 marks the item
  `gone` and is retried rarely.
- Switched on by its own flag, `METADATA_ENRICHMENT_ENABLED`, off by default, and independent of
  history storage: enrichment fetches public metadata, never listening data. Rake tasks:
  `enrich:status`, `enrich:run LIMIT=…`, `taxonomy:unmapped`.
- **Storage:** a few MB of rows. Images aren't stored. The browser loads Cover Art Archive
  thumbnails directly; local caching is a later option if you'd rather not have the browser contact
  archive.org.

## 6. Missing, ambiguous and conflicting data

- **Provenance:** every stored value has its source, the source's ID, when it was fetched and the
  raw value. Original tag strings and vote counts are kept as fetched.
- **Missing** is shown as missing:
  - Unclassified (hatched, as the Overview already draws "untagged");
  - "Type not listed" and "Not identified";
  - "No artwork": a lettered placeholder, as today.
  - `stats.albumsWithoutArtwork` counts them.
- **Ambiguous:**
  - IDs in `mbid_disputes` are not used for enrichment.
  - Inferred artist links use the identified artist's metadata, and keep their inference record.
  - Nothing is ever matched by name.
- **Conflicting:**
  - Demographics come from one source (MusicBrainz), so they are never merged across sources.
  - Genre signals from several sources would combine through explicit per-source weights in
    `taxonomy_settings`, each tag keeping its source. Milestone 4 has a single source.
- **Your edits:** taxonomy mappings and settings are editable and win over seeds. Per-artist genre
  overrides, if wanted, are a small later addition with origin `manual`.

## 7. API and frontend changes

**`GET /api/overview`** (the shapes the frontend already expects, filled in)
- `genres`: `{ broad, sub }`.
  - Categories with allocated `share`, subgenres, top artists, and `byYear` (the same slots every
    year, each year summing to 100%).
  - `untaggedShare` becomes the Unclassified share.
  - Adds `sources` and `classifiedPlays`, so captions can say what the figures rest on.
- `metadata`: the categories in §4, by artists and by plays, plus "not identified".
- `stats.albumsWithoutArtwork`, and `imageUrl` on top albums and tracks (release artwork), and on
  artists only where a licensed image exists.

**New endpoint and page**
- `GET /api/genres/:slug?period=`: a genre's drill-down.
  - Its share and reach, with their difference explained.
  - Subgenres; contributing artists and tracks by allocated plays.
  - By year; and the source tags behind it.
- A genre page (`/genres/:slug`) built from existing Overview components (Section, tables,
  stacked-share chart). Linked from the genre list, so you can drill in.

**Comparisons and change over time** already exist in the Overview: by-year bands, and comparing
two periods side by side. Genres follow them.

**Copy**
- The genre section's description changes from "Last.fm artist tags" to MusicBrainz genres.
- Captions credit MusicBrainz (CC BY-NC-SA) and the Cover Art Archive.
- No new design elements: same tokens, sections and dark editorial style.

## 8. Performance

- Each artist's and release group's genre distribution is precomputed into a small table (about
  7,000 artists by a few genres). It is recomputed when enrichment or the taxonomy changes, which
  takes seconds.
- The Overview already counts plays per artist (and album). Genres are those counts multiplied by
  the distributions: work proportional to artists, not plays. Expected cost: tens of milliseconds
  per Overview, measured at 209k and 1M plays as before.
- The genre drill-down uses the same counts filtered to one genre.
- Enrichment runs in the background at one request per second and never blocks a page.

## 9. Stages

1. **Taxonomy and classification, offline.**
   - Tables and seeds; the calculation library.
   - Tests on synthetic fixtures: shares sum to exactly 1; rounding; overlapping genres;
     unclassified handling; subgenre splits; reach versus share.
   - No network calls.
2. **MusicBrainz enrichment.**
   - Client (User-Agent, pacing, retries, redirects); jobs, flag, rake tasks; provenance.
   - A short supervised run on the top 100 artists, then, with your approval, the whole catalogue in
     the background.
   - Report measured coverage: classified plays; type and gender listed; unmapped tags.
3. **Overview genres and metadata.**
   - Fill `genres` and `metadata`; the genre drill-down endpoint and page.
   - Contract tests, benchmarks, and a visual check on the real data.
4. **Artwork.**
   - Cover Art Archive for albums (release, then release group), `albumsWithoutArtwork`, credits.
   - Optional Wikimedia artist images, only with licence and author shown.
5. **Later, optional:**
   - review-assisted MusicBrainz matching for name-only artists;
   - Discogs as a second genre source;
   - local image caching;
   - per-artist genre overrides.

## 10. Owner decisions (2026-10-31)

1. **MusicBrainz licensing: approved for personal, non-commercial use.**
   - Genres and tags (CC BY-NC-SA 3.0) are used with attribution.
   - Metadata lives in its own tables, apart from the owner's listening history: provider, licence,
     provider ID and retrieval date are kept per value.
   - The owner's scrobbles and Runout's source code don't take on the metadata's licence.
   - **If Runout is ever distributed publicly or used commercially, reconsider:**
     - the NC clause on genres and tags (drop them, or get permission);
     - attribution in the distributed UI;
     - whether derived classifications count as adaptations, so ShareAlike applies.
     MusicBrainz core data (type, gender, area, dates) is CC0 and unaffected.
2. **Taxonomy: about 14 broad genres**, within §6's design.
   - Version-controlled seeds; editable mappings; manual rows survive refreshes.
   - Original genre names, tags and vote counts are retained.
   - Unclassified is an explicit category, and nothing is forced.
   - §6 names no genre list (it fixes the arithmetic and the 6 + Other display slots), so the seeded
     list is new and checked against §6's rules.
3. **Artist images: deferred.** Album artwork from the Cover Art Archive only. The frontend keeps
   `imageUrl` on artists, so images can be added later without a redesign.
4. **Artwork: provider-hosted thumbnails.**
   - Official Cover Art Archive endpoints, following redirects; sized thumbnails, lazy loading,
     aspect ratio kept, neutral placeholders.
   - HTTPS from approved hosts only (`coverartarchive.org`, `archive.org`). References and
     provenance are stored, never image files. No caching or proxy yet.
   - Release IDs and release-group IDs are kept apart, and artwork is never matched by album name.
   - **Image rights**, separate from metadata licensing: cover images remain their rights holders'
     copyright. The Cover Art Archive hosts them for display. Runout shows provider-hosted
     thumbnails with credit and keeps no copies. Redistribution, printing or caching copies would
     need its own assessment.
5. **Genres: artist level first.**
   - No release-group genre requests yet; the model has a `level` so release-group or recording
     genres can refine artist genres later.
   - The UI states the level: artist genres approximate the music played, and don't prove what
     every song is.

**Also decided**
- **Enrichment:**
  - Most-played artists first; an off-by-default `METADATA_ENRICHMENT_ENABLED`.
  - Resumable Solid Queue jobs; one global MusicBrainz pacer at no more than one request per second.
  - A meaningful User-Agent; bounded retries with backoff.
  - Explicit unavailable and retired IDs; negative-result caching.
  - Provenance and refresh history; manual overrides protected.
  - Progress reporting (completed, failed, unavailable, remaining).
  - No refetch on startup. No Last.fm tags and no name-only searches.
- **Pilot:** a supervised run on the top 100 identified artists, reported. **The full run (about
  7,300 artists) needs separate approval.**
- **Demographics:** only explicit provider values, with distinct categories, and missing shown as
  missing. Captions describe distributions of plays by listed artist metadata. No sensitive
  attributes are inferred.
- **Integrity:** enrichment never changes scrobbles, strings, IDs, coverage or import decisions.
  Matching and enrichment stay separate. Merges, aliases and reverts neither double-count nor
  orphan classifications, because classification follows the catalogue artist at the end of its
  merge chain.
- **Commits:**
  1. taxonomy and genre calculations (offline);
  2. metadata models and enrichment, then the pilot;
  3. genre analytics and drill-down;
  4. artwork, with a small supervised sample.

# Loved songs

Status: built 2026-11-04, approved by the owner. The Last.fm loved list is imported read-only into
Runout's own `loved_tracks` table and shown on the Loved page, with hearts beside loved tracks in
the Overview, Search and Time Machine. Writing back to Last.fm, recurring refreshes, MusicBrainz
enrichment and artwork downloads are not part of this.

## 1. The data

`loved_tracks`: one row per user, song and source. The song is a **name variant**: the exact artist
and track strings and MusicBrainz IDs the source sent, with no album. The variant goes through the
catalogue matcher like a play's, so a loved song has the same identity as its plays: the catalogue
track at the end of its merge chain, or its normalised names. Hearts and play counts follow that
identity (`Analytics::Identity`), never a looser name match.

| Column | Meaning |
|---|---|
| `source` | `lastfm` (imported) or `runout` (a favourite made here, later) |
| `loved_at` | When the song was loved, as the source says. Never a play date. |
| `source_url` | Last.fm's page for the song |
| `first_imported_at`, `last_listed_at` | Provenance: first import, and the last complete Last.fm list that included it |
| `unloved_at` | No longer loved; the row stays |
| `manual` | A person changed it here; refreshes leave it alone |

A loved song is never a scrobble, and a scrobble is never changed by loving. Future plays from
Spotify or any other source attach to the same identity, so hearts and counts follow them.

## 2. The import

`bin/rails loved:import`, with `LASTFM_LOVED_IMPORT_ENABLED=true` set for that command only
(`ListeningStorage`, provider `lastfm_loved`). `Loved::Import`:

1. Fetches every page of `user.getLovedTracks` through the usual client and pacer (1,000 per page,
   so one request for under a thousand songs).
2. Refuses to continue unless the number received equals the total Last.fm announced. A failed or
   short response can therefore never mark anything unloved.
3. Adds new songs with their loved date; keeps existing ones (earliest loved date wins); re-loves
   songs listed again after being unloved, with the new date.
4. Only then marks `lastfm` rows that are not `manual` and were not in this list as `unloved_at`.
   `runout` rows are never touched.
5. Matches new variants with the catalogue rules: a MusicBrainz ID links the recording, a disputed
   ID (`MbidDispute`) is ignored, a name alone joins the name-only entity and never an identified one
   (a `possible_match` review opens instead), several candidates are held as `ambiguous`.

Repeating the import changes nothing. Existing plays, variants and catalogue rows are not edited.

**Imported into production 2026-11-04 17:14 UTC**, after a rehearsal on a copy of the merged archive:
859 songs, one request, 663 linked by MusicBrainz ID and 196 by name, 3 held for review
(`possible_match`: Sorcha Richardson "Illinois Again", The Beaches "Should've Known Better", Peter Bjorn
and John "Objects Of My Affection"), 0 ambiguous. Every loved date equals Last.fm's; a second run kept
all 859 and changed nothing; every pre-existing row in every table was unchanged and the Last.fm
fingerprint intact (backups `backup/20261104T171424Z` before and `backup/20261104T171914Z` after, both
restore-tested). Last.fm had added IDs for two songs since the rehearsal: The Proclaimers now links to
its scrobbled recording, and The Cure "Just Like Heaven" to a new recording with no plays. 12 loved
songs have no plays by identity: 9 are Last.fm IDs for a different recording than the one scrobbled
(for example Robyn "Dancing on My Own", 76 plays under the other recording), shown as
"0 linked · n under this name"; 3 were never played under that exact title. Merging recordings is a
catalogue decision for a person, not the import.

## 3. The page and the hearts

`/loved` (`GET /api/loved-tracks`, `Analytics::Loved`): figures, five insights and the library.

- **Dates are labelled.** "Loved on" is `loved_at`. "Last listened", "first played" and plays are
  scrobbles. The year chart counts the year a song was loved.
- **Insights:** loved longest (oldest `loved_at`); most played; not heard in 3 years or more; back in
  rotation (played in the last 90 days after 2 years or more without a play, from `previousPlayedAt`,
  the last play before the recent window); loved by year.
- **Library:** search, artist and year filters, five sort orders, 100 rows at a time. Each row links
  to the artist and to the Time Machine day of the last play. A song held for review says so; a song
  no longer loved is shown muted without a heart.
- **"Without linked plays"** separates "plays under another recording of the same name" (`namePlays`,
  counted by normalised names whatever the catalogue link) from "never played".
- **Hearts** (`Heart`, announced "Loved") appear beside loved identities in the Overview's top tracks
  and On repeat, in search results and in the Time Machine play log. The library loads once per
  session (`LovedProvider`); hearts stay off until it has.

## 4. What is not done, on purpose

Loving or unloving inside Runout (`source: runout`, the API and buttons), a scheduled Last.fm refresh,
writes to Last.fm, and recording merges for the 9 songs above. The model is ready for the first two:
`runout` rows and `manual` rows survive any refresh.

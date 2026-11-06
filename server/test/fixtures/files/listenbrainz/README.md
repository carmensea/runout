# ListenBrainz listens fixture (sanitised)
Timestamps: `listened_at` is kept to the second as submitted (`reported_at_raw`). Web Scrobbler and
Pano Scrobbler submit the start of playback (`listen_started_at`); ListenBrainz's own Spotify import
copies Spotify's end-of-play `played_at` (`spotify_played_at`); any other client's time is stored as
`listenbrainz_listened_at`, meaning unknown, with the client in the context. Reconciling these kinds
across providers is PR C's job. Event identity is second + artist + track + release: one track reported
twice in the same second collapses to one play; ListenBrainz itself already keeps one listen per user,
second and `recording_msid` (its id for the submitted names), so such a pair never reaches the public
API and cannot be told apart by any reader of it.

Timestamps: `listened_at` is kept to the second as submitted (`reported_at_raw`). Web Scrobbler and
Pano Scrobbler submit the start of playback (`listen_started_at`); ListenBrainz's own Spotify import
copies Spotify's end-of-play `played_at` (`spotify_played_at`); any other client's time is stored as
`listenbrainz_listened_at`, meaning unknown, with the client in the context. Reconciling these kinds
across providers is PR C's job. Event identity is second + artist + track + release: one track reported
twice in the same second collapses to one play; ListenBrainz itself already keeps one listen per user,
second and `recording_msid` (its id for the submitted names), so such a pair never reaches the public
API and cannot be told apart by any reader of it.
`listens.json` has the exact structure of `GET /1/user/{name}/listens` as observed on 2026-11-06
Timestamps: `listened_at` is kept to the second as submitted (`reported_at_raw`). Web Scrobbler and
Pano Scrobbler submit the start of playback (`listen_started_at`); ListenBrainz's own Spotify import
copies Spotify's end-of-play `played_at` (`spotify_played_at`); any other client's time is stored as
`listenbrainz_listened_at`, meaning unknown, with the client in the context. Reconciling these kinds
across providers is PR C's job. Event identity is second + artist + track + release: one track reported
twice in the same second collapses to one play; ListenBrainz itself already keeps one listen per user,
second and `recording_msid` (its id for the submitted names), so such a pair never reaches the public
API and cannot be told apart by any reader of it.
from the YouTube Music tester (Pano Scrobbler 4.47 on Android, Web Scrobbler 3.23.1 on PC). Names,
Timestamps: `listened_at` is kept to the second as submitted (`reported_at_raw`). Web Scrobbler and
Pano Scrobbler submit the start of playback (`listen_started_at`); ListenBrainz's own Spotify import
copies Spotify's end-of-play `played_at` (`spotify_played_at`); any other client's time is stored as
`listenbrainz_listened_at`, meaning unknown, with the client in the context. Reconciling these kinds
across providers is PR C's job. Event identity is second + artist + track + release: one track reported
twice in the same second collapses to one play; ListenBrainz itself already keeps one listen per user,
second and `recording_msid` (its id for the submitted names), so such a pair never reaches the public
API and cannot be told apart by any reader of it.
MBIDs, MSIDs, CAA ids, origin URLs, the user and the timestamps are replaced; repeat patterns,
Timestamps: `listened_at` is kept to the second as submitted (`reported_at_raw`). Web Scrobbler and
Pano Scrobbler submit the start of playback (`listen_started_at`); ListenBrainz's own Spotify import
copies Spotify's end-of-play `played_at` (`spotify_played_at`); any other client's time is stored as
`listenbrainz_listened_at`, meaning unknown, with the client in the context. Reconciling these kinds
across providers is PR C's job. Event identity is second + artist + track + release: one track reported
twice in the same second collapses to one play; ListenBrainz itself already keeps one listen per user,
second and `recording_msid` (its id for the submitted names), so such a pair never reaches the public
API and cannot be told apart by any reader of it.
field presence and client differences are kept. Nine of the twelve observed events were kept.
Timestamps: `listened_at` is kept to the second as submitted (`reported_at_raw`). Web Scrobbler and
Pano Scrobbler submit the start of playback (`listen_started_at`); ListenBrainz's own Spotify import
copies Spotify's end-of-play `played_at` (`spotify_played_at`); any other client's time is stored as
`listenbrainz_listened_at`, meaning unknown, with the client in the context. Reconciling these kinds
across providers is PR C's job. Event identity is second + artist + track + release: one track reported
twice in the same second collapses to one play; ListenBrainz itself already keeps one listen per user,
second and `recording_msid` (its id for the submitted names), so such a pair never reaches the public
API and cannot be told apart by any reader of it.

Timestamps: `listened_at` is kept to the second as submitted (`reported_at_raw`). Web Scrobbler and
Pano Scrobbler submit the start of playback (`listen_started_at`); ListenBrainz's own Spotify import
copies Spotify's end-of-play `played_at` (`spotify_played_at`); any other client's time is stored as
`listenbrainz_listened_at`, meaning unknown, with the client in the context. Reconciling these kinds
across providers is PR C's job. Event identity is second + artist + track + release: one track reported
twice in the same second collapses to one play; ListenBrainz itself already keeps one listen per user,
second and `recording_msid` (its id for the submitted names), so such a pair never reaches the public
API and cannot be told apart by any reader of it.
| # | client | shows |
Timestamps: `listened_at` is kept to the second as submitted (`reported_at_raw`). Web Scrobbler and
Pano Scrobbler submit the start of playback (`listen_started_at`); ListenBrainz's own Spotify import
copies Spotify's end-of-play `played_at` (`spotify_played_at`); any other client's time is stored as
`listenbrainz_listened_at`, meaning unknown, with the client in the context. Reconciling these kinds
across providers is PR C's job. Event identity is second + artist + track + release: one track reported
twice in the same second collapses to one play; ListenBrainz itself already keeps one listen per user,
second and `recording_msid` (its id for the submitted names), so such a pair never reaches the public
API and cannot be told apart by any reader of it.
|---|---|---|
Timestamps: `listened_at` is kept to the second as submitted (`reported_at_raw`). Web Scrobbler and
Pano Scrobbler submit the start of playback (`listen_started_at`); ListenBrainz's own Spotify import
copies Spotify's end-of-play `played_at` (`spotify_played_at`); any other client's time is stored as
`listenbrainz_listened_at`, meaning unknown, with the client in the context. Reconciling these kinds
across providers is PR C's job. Event identity is second + artist + track + release: one track reported
twice in the same second collapses to one play; ListenBrainz itself already keeps one listen per user,
second and `recording_msid` (its id for the submitted names), so such a pair never reaches the public
API and cannot be told apart by any reader of it.
| 0 | Web Scrobbler | `duration` in seconds, `music_service_name` "YouTube Music", `origin_url` to a watch URL inside a playlist, `mbid_mapping` present |
Timestamps: `listened_at` is kept to the second as submitted (`reported_at_raw`). Web Scrobbler and
Pano Scrobbler submit the start of playback (`listen_started_at`); ListenBrainz's own Spotify import
copies Spotify's end-of-play `played_at` (`spotify_played_at`); any other client's time is stored as
`listenbrainz_listened_at`, meaning unknown, with the client in the context. Reconciling these kinds
across providers is PR C's job. Event identity is second + artist + track + release: one track reported
twice in the same second collapses to one play; ListenBrainz itself already keeps one listen per user,
second and `recording_msid` (its id for the submitted names), so such a pair never reaches the public
API and cannot be told apart by any reader of it.
| 1 | Web Scrobbler | no `release_name`, no `mbid_mapping`, `origin_url` is a playlist URL (not a track) |
Timestamps: `listened_at` is kept to the second as submitted (`reported_at_raw`). Web Scrobbler and
Pano Scrobbler submit the start of playback (`listen_started_at`); ListenBrainz's own Spotify import
copies Spotify's end-of-play `played_at` (`spotify_played_at`); any other client's time is stored as
`listenbrainz_listened_at`, meaning unknown, with the client in the context. Reconciling these kinds
across providers is PR C's job. Event identity is second + artist + track + release: one track reported
twice in the same second collapses to one play; ListenBrainz itself already keeps one listen per user,
second and `recording_msid` (its id for the submitted names), so such a pair never reaches the public
API and cannot be told apart by any reader of it.
| 2 | Web Scrobbler | same `recording_msid` as #0: a genuine repeat, distinct `listened_at` |
Timestamps: `listened_at` is kept to the second as submitted (`reported_at_raw`). Web Scrobbler and
Pano Scrobbler submit the start of playback (`listen_started_at`); ListenBrainz's own Spotify import
copies Spotify's end-of-play `played_at` (`spotify_played_at`); any other client's time is stored as
`listenbrainz_listened_at`, meaning unknown, with the client in the context. Reconciling these kinds
across providers is PR C's job. Event identity is second + artist + track + release: one track reported
twice in the same second collapses to one play; ListenBrainz itself already keeps one listen per user,
second and `recording_msid` (its id for the submitted names), so such a pair never reaches the public
API and cannot be told apart by any reader of it.
| 3 | Web Scrobbler | mapped, a different track by the same artist |
Timestamps: `listened_at` is kept to the second as submitted (`reported_at_raw`). Web Scrobbler and
Pano Scrobbler submit the start of playback (`listen_started_at`); ListenBrainz's own Spotify import
copies Spotify's end-of-play `played_at` (`spotify_played_at`); any other client's time is stored as
`listenbrainz_listened_at`, meaning unknown, with the client in the context. Reconciling these kinds
across providers is PR C's job. Event identity is second + artist + track + release: one track reported
twice in the same second collapses to one play; ListenBrainz itself already keeps one listen per user,
second and `recording_msid` (its id for the submitted names), so such a pair never reaches the public
API and cannot be told apart by any reader of it.
| 4 | Pano | `duration_ms`, no `music_service_name`, no mapping |
Timestamps: `listened_at` is kept to the second as submitted (`reported_at_raw`). Web Scrobbler and
Pano Scrobbler submit the start of playback (`listen_started_at`); ListenBrainz's own Spotify import
copies Spotify's end-of-play `played_at` (`spotify_played_at`); any other client's time is stored as
`listenbrainz_listened_at`, meaning unknown, with the client in the context. Reconciling these kinds
across providers is PR C's job. Event identity is second + artist + track + release: one track reported
twice in the same second collapses to one play; ListenBrainz itself already keeps one listen per user,
second and `recording_msid` (its id for the submitted names), so such a pair never reaches the public
API and cannot be told apart by any reader of it.
| 5 | Pano | same `recording_msid` as #4: repeat |
Timestamps: `listened_at` is kept to the second as submitted (`reported_at_raw`). Web Scrobbler and
Pano Scrobbler submit the start of playback (`listen_started_at`); ListenBrainz's own Spotify import
copies Spotify's end-of-play `played_at` (`spotify_played_at`); any other client's time is stored as
`listenbrainz_listened_at`, meaning unknown, with the client in the context. Reconciling these kinds
across providers is PR C's job. Event identity is second + artist + track + release: one track reported
twice in the same second collapses to one play; ListenBrainz itself already keeps one listen per user,
second and `recording_msid` (its id for the submitted names), so such a pair never reaches the public
API and cannot be told apart by any reader of it.
| 6 | Pano | mapped, `inserted_at` well after `listened_at` (late submission) |
Timestamps: `listened_at` is kept to the second as submitted (`reported_at_raw`). Web Scrobbler and
Pano Scrobbler submit the start of playback (`listen_started_at`); ListenBrainz's own Spotify import
copies Spotify's end-of-play `played_at` (`spotify_played_at`); any other client's time is stored as
`listenbrainz_listened_at`, meaning unknown, with the client in the context. Reconciling these kinds
across providers is PR C's job. Event identity is second + artist + track + release: one track reported
twice in the same second collapses to one play; ListenBrainz itself already keeps one listen per user,
second and `recording_msid` (its id for the submitted names), so such a pair never reaches the public
API and cannot be told apart by any reader of it.
| 7 | Pano | same `recording_msid` as #6: repeat, same late `inserted_at` |
Timestamps: `listened_at` is kept to the second as submitted (`reported_at_raw`). Web Scrobbler and
Pano Scrobbler submit the start of playback (`listen_started_at`); ListenBrainz's own Spotify import
copies Spotify's end-of-play `played_at` (`spotify_played_at`); any other client's time is stored as
`listenbrainz_listened_at`, meaning unknown, with the client in the context. Reconciling these kinds
across providers is PR C's job. Event identity is second + artist + track + release: one track reported
twice in the same second collapses to one play; ListenBrainz itself already keeps one listen per user,
second and `recording_msid` (its id for the submitted names), so such a pair never reaches the public
API and cannot be told apart by any reader of it.
| 8 | Pano | mapped, no `release_name` |
Timestamps: `listened_at` is kept to the second as submitted (`reported_at_raw`). Web Scrobbler and
Pano Scrobbler submit the start of playback (`listen_started_at`); ListenBrainz's own Spotify import
copies Spotify's end-of-play `played_at` (`spotify_played_at`); any other client's time is stored as
`listenbrainz_listened_at`, meaning unknown, with the client in the context. Reconciling these kinds
across providers is PR C's job. Event identity is second + artist + track + release: one track reported
twice in the same second collapses to one play; ListenBrainz itself already keeps one listen per user,
second and `recording_msid` (its id for the submitted names), so such a pair never reaches the public
API and cannot be told apart by any reader of it.

Timestamps: `listened_at` is kept to the second as submitted (`reported_at_raw`). Web Scrobbler and
Pano Scrobbler submit the start of playback (`listen_started_at`); ListenBrainz's own Spotify import
copies Spotify's end-of-play `played_at` (`spotify_played_at`); any other client's time is stored as
`listenbrainz_listened_at`, meaning unknown, with the client in the context. Reconciling these kinds
across providers is PR C's job. Event identity is second + artist + track + release: one track reported
twice in the same second collapses to one play; ListenBrainz itself already keeps one listen per user,
second and `recording_msid` (its id for the submitted names), so such a pair never reaches the public
API and cannot be told apart by any reader of it.
Rules the fixture is for: normalise `duration` (s) vs `duration_ms`; `recording_msid` is not an
Timestamps: `listened_at` is kept to the second as submitted (`reported_at_raw`). Web Scrobbler and
Pano Scrobbler submit the start of playback (`listen_started_at`); ListenBrainz's own Spotify import
copies Spotify's end-of-play `played_at` (`spotify_played_at`); any other client's time is stored as
`listenbrainz_listened_at`, meaning unknown, with the client in the context. Reconciling these kinds
across providers is PR C's job. Event identity is second + artist + track + release: one track reported
twice in the same second collapses to one play; ListenBrainz itself already keeps one listen per user,
second and `recording_msid` (its id for the submitted names), so such a pair never reaches the public
API and cannot be told apart by any reader of it.
event id (dedup on `listened_at` + msid, never msid alone); `mbid_mapping` is ListenBrainz's
Timestamps: `listened_at` is kept to the second as submitted (`reported_at_raw`). Web Scrobbler and
Pano Scrobbler submit the start of playback (`listen_started_at`); ListenBrainz's own Spotify import
copies Spotify's end-of-play `played_at` (`spotify_played_at`); any other client's time is stored as
`listenbrainz_listened_at`, meaning unknown, with the client in the context. Reconciling these kinds
across providers is PR C's job. Event identity is second + artist + track + release: one track reported
twice in the same second collapses to one play; ListenBrainz itself already keeps one listen per user,
second and `recording_msid` (its id for the submitted names), so such a pair never reaches the public
API and cannot be told apart by any reader of it.
opinion, kept in context, never a verified identity; `origin_url` may be a playlist; keep both
Timestamps: `listened_at` is kept to the second as submitted (`reported_at_raw`). Web Scrobbler and
Pano Scrobbler submit the start of playback (`listen_started_at`); ListenBrainz's own Spotify import
copies Spotify's end-of-play `played_at` (`spotify_played_at`); any other client's time is stored as
`listenbrainz_listened_at`, meaning unknown, with the client in the context. Reconciling these kinds
across providers is PR C's job. Event identity is second + artist + track + release: one track reported
twice in the same second collapses to one play; ListenBrainz itself already keeps one listen per user,
second and `recording_msid` (its id for the submitted names), so such a pair never reaches the public
API and cannot be told apart by any reader of it.
`listened_at` and `inserted_at`; provider is unknown unless `music_service_name` says otherwise.
Timestamps: `listened_at` is kept to the second as submitted (`reported_at_raw`). Web Scrobbler and
Pano Scrobbler submit the start of playback (`listen_started_at`); ListenBrainz's own Spotify import
copies Spotify's end-of-play `played_at` (`spotify_played_at`); any other client's time is stored as
`listenbrainz_listened_at`, meaning unknown, with the client in the context. Reconciling these kinds
across providers is PR C's job. Event identity is second + artist + track + release: one track reported
twice in the same second collapses to one play; ListenBrainz itself already keeps one listen per user,
second and `recording_msid` (its id for the submitted names), so such a pair never reaches the public
API and cannot be told apart by any reader of it.

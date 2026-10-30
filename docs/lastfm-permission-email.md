# Draft: email to Last.fm about API usage

Status: **draft for review. Not sent.** Fill in the bracketed parts before sending.
Send to the contact listed on https://www.last.fm/api (API support / partner contact).

---

**Subject:** API terms question: private, non-commercial archive of one user's own scrobble history

Hello,

My name is [your name]. I'm building Runout, a personal, non-commercial tool that shows my own
Last.fm listening history as charts (listening by year and hour, top artists, genres from artist
tags). It signs in with Last.fm web authentication, and is registered under the API account
"[API application name]" (API key ending [last 4 characters]).

Before I import any history, I'd like to confirm that what I have in mind is within the API Terms
of Service, and ask for written consent where it is needed. In short:

- Runout is for my own account. It is not offered to the public, and it is not commercial (§3.1).
- It would store my scrobbles (timestamp, artist, track and album names, MusicBrainz IDs where
  present) plus the top tags for the artists I've played, so the charts can be computed without
  calling the API for every page view.
- My account has about [N] scrobbles since [year]. I estimate the stored history at roughly
  [X] MB, including database indexes.

My questions:

1. **Long-term storage of my own history.** May I keep a complete copy of my own scrobble history,
   kept up to date by periodic sync (about every 30 minutes, plus a weekly consistency check)?
   §4.3.4 describes the licence as "temporary and restricted to a small portion of Last.fm Data",
   and I want to be sure a full personal history is acceptable.

2. **The 100 MB Reasonable Usage Cap (§4.3.4).** Does the cap apply to stored history of the
   authenticated user's own scrobbles? If so, how is it measured: the size of the API responses,
   or the size of the data as stored? If my history would exceed it, what would written consent
   require?

3. **Private versus public access (§2.7).** The deployment is private: one hosted instance,
   reachable only after signing in with my Last.fm account. Does that count as public access
   needing your approval of pages? If I later let a few friends sign in with their own Last.fm
   accounts (each seeing only their own data), would that change the answer?

4. **Caching (§4.3.4).** The terms ask for caching "in accordance with the HTTP headers sent with
   web service responses". How should that apply to stored scrobble history and artist tags that I
   refresh on a schedule rather than per request? Is there a maximum age for cached artist tags or
   artwork?

5. **Attribution (§2.7).** Could you point me to the official "powered by AudioScrobbler" badge
   and any placement requirements? At the moment the app shows a text credit with a link to
   last.fm on every page with listening data.

6. **Rate limits (§4.4).** Is there a published request rate I should stay under for a one-off
   history import and the ongoing sync?

7. **Keeping my own history after I stop using the API (§9.3).** If I later stop using the API,
   or stop using Last.fm, may I keep my own listening history (my scrobbles: times and names) in
   my private archive? If §9.3 requires deleting it, is a personal data export of my account the
   right way to keep a copy of my own history?

If any of this needs a different kind of agreement, I'm happy to adjust the design: for example,
storing less, refreshing more often, or deleting data on a schedule. Nothing has been imported yet;
I'm waiting for your answer before I do.

Thank you,
[your name]
[Last.fm username]
[contact email]

---

## Notes for review (not part of the email)

- Clause numbers and quotes were checked against https://www.last.fm/api/tos on 2026-10-29.
- Fill in the scrobble count from your Last.fm profile. For a size estimate, a few hundred bytes
  per scrobble including indexes is a reasonable working figure; Milestone 2 adds a rake task that
  reports the real stored size.
- Don't include your API secret or session key.
- Question 7 was added on 2026-10-30 for the long-term direction (`docs/long-term-architecture.md`
  §3): keeping the full history after leaving Last.fm depends on the answer. Remove it if you'd
  rather ask separately.

# Operator access to another account

How Runout's operator (the owner) looks at an account that is not theirs, what that session can
and cannot do, and the gap between today's mechanism and the one the owner asked for.

## 1. What exists (PR #19, 2026-11-08)

`bin/rails auth:sign_in_as[user_id,display_name]`, run over `railway ssh --service runout`, prints a
single-use link valid 15 minutes (`SignInLink` kind `operator`). Opening it starts an **operator
session** (`sessions.operator = true`) for that account.

An operator session:

- **reads** everything the person sees: Overview, Time Machine, Loved, Settings, sources, sessions;
- **never reads the diary words:** every memory's text and label come back as placeholder words of
  the same word and line count (`Memories::Placeholder`); the memories search matches only songs and
  artists, so the words cannot be probed; the song and the dates stay;
- **writes nothing:** every non-GET request is `403 operator_session`
  (`Authentication#enforce_operator_session`), so no account change, name or theme, no deletion, no
  passkey or recovery code, no source connect, disconnect, pause or sync, no import, review or
  correction, no memory;
- **reaches no way in:** the Last.fm, Spotify and Google OAuth routes, passkey and recovery sign-in,
  and sign-in links answer 403 even on GET, so it cannot connect a provider, enrol a credential or spend
  the person's recovery link; the person's own sessions are untouched;
- **ends in 60 minutes** from opening (`Session::OPERATOR_LIFETIME`); activity never extends it; the
  one write allowed is ending it early (`DELETE /api/session`);
- **is visible:** the connection payload carries `operator: { expiresAt }`, every page shows the
  "Operator view" banner with an end button, Settings hides or disables every control, and the
  person's Settings → Account → Sessions lists it as "Operator sign-in". Issuing and using the link
  are logged.

`auth:recovery_link` is unchanged: an ordinary session for a locked-out person, not for looking.

## 2. Remaining limitations

- **It is a bearer link.** Whoever holds the link for 15 minutes can open the session. It is printed
  only on the operator's terminal over ssh, used once, and the session is read-only and short, which
  bounds the damage; it is still a secret in transit.
- **Personal data other than the diary is shown as is:** plays, loved songs, sources, sessions, IP
  addresses. The owner asked for the diary alone to be hidden; nothing else is redacted.
- **The frontend hides what the server refuses;** a client that ignores the hints still gets 403.
  The banner's end button is the only working control.
- **Theme changes in the account menu** apply locally in the operator's browser and the save is
  refused; harmless, slightly inconsistent.

## 3. The gap: signing in as someone with the operator's own passkey

The owner's original wording was to authenticate with their own credentials and then look at an
account. Today the operator proves nothing to the application: the console does, by issuing a link.
Closing the gap means an operator identity inside Runout:

1. **An operator role** on the owner's account (`users.operator`, set by a task, never by a request),
   and an API that only an operator's own passkey session may call: `POST /api/operator/sessions
   { userId }`, requiring a fresh WebAuthn user verification (re-authentication within the last
   minute, as a step-up), opening an operator session for the target in the same browser and keeping
   the operator's own session to return to.
2. **An audit table** (who, which account, when, until when, ended how), shown to the person on their
   Sessions tab and kept after the session ends.
3. **A picker** in the owner's Settings (accounts by display name) and a "Back to my account"
   control in the banner.

That is a new authorisation model (roles, step-up, audit) touching sign-in, sessions and Settings:
a separate plan and PR, not an extension of #19. Until then the console link is the mechanism, with
the limits above.

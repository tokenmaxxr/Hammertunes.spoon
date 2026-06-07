# Guided Spotify Web API setup

Date: 2026-06-06
Status: Approved, ready for implementation plan

## Goal

Make the optional Spotify Web API features reachable without editing
`~/.hammerspoon/init.lua` or hand-copying IDs into a file. `init.lua` stays just
`:start()`; a guided dialog flow handles app creation, the Client ID, and the
OAuth approval. This lowers the onboarding friction the current README exposes
(create app -> copy Client ID -> add `authenticate("...")` to config).

## Background and constraints

- The basic pill (now-playing, transport, scrub, copy, local shuffle) already
  works with zero setup via AppleScript + `hs.spotify`. The Web API only adds
  the menu extras: playlists (Add to / Play Playlist), like/unlike, Play Liked
  Songs, the playing-context name, and the read-only Smart Shuffle indicator.
- **A per-user Spotify app is unavoidable.** A shared app in Spotify's free
  development mode is limited to 25 manually-added users, so the spoon cannot
  ship one Client ID for everyone. Each user must create their own free app and
  paste its Client ID. We can guide this, not eliminate it.
- The redirect URI is fixed at `http://127.0.0.1:53127/callback` and must be set
  in the user's Spotify app. The flow surfaces it (and copies it to the
  clipboard) rather than asking the user to remember it.
- Existing `backends/spotify.lua` already implements the full PKCE OAuth in
  `authenticate(clientId)` (local httpserver on 53127, browser approval, token
  to Keychain). The wizard wraps this; it does not reimplement auth.

## Design

### Entry points (both run the same wizard)

1. **Menu item** in the right-click menu: shown as **"Enable Spotify extras…"**
   when Spotify is connected but unauthenticated; replaced by the existing
   **"Re-authenticate"** once authenticated. Apple Music shows neither.
2. **One-time offer:** the first time the Spotify backend starts unauthenticated,
   show the consent dialog once (deferred so the pill renders first). Tracked by
   an `hs.settings` flag so it never appears again, regardless of the choice. The
   menu item remains the way back in.

### Wizard steps (in `backends/spotify.lua`)

1. **Consent dialog** (`hs.dialog.blockAlert`):
   > **Enable Spotify extras?**
   > Adds playlists, like/unlike, Play Liked Songs, and the playing-from name to
   > the menu.
   > It's free. You create a Spotify API key with limited permissions (just
   > playback and your playlists/library) and approve it on Spotify's own site,
   > so the spoon never sees your password. Everything it stores - the login and
   > cached playlists - stays on your Mac.
   >
   > Buttons: **Set it up** / **Not now**.
2. **Client ID capture:** copy `http://127.0.0.1:53127/callback` to the
   clipboard, open <https://developer.spotify.com/dashboard>, then a
   `hs.dialog.textPrompt` whose message walks through: create app -> paste the
   Redirect URI (already on the clipboard) -> copy the Client ID and paste it
   below. Buttons: **Continue** / **Cancel**.
3. **Approve:** on a non-empty Client ID, call the existing
   `authenticate(clientId)`, which opens Spotify's approval page and saves the
   token to the Keychain. Cancel / empty input aborts quietly.

## Component changes

### `backends/spotify.lua`
- `needsSetup()` -> bool: `true` when no usable credentials are cached
  (`loadCreds()` then `not (cachedClientId and cachedRefreshToken)`).
- `setup()`: the wizard above; thin wrapper over `authenticate`.
- `start(onChange)`: after the existing work, if `needsSetup()` and the
  "offer shown" `hs.settings` flag is unset, defer the consent dialog once and
  set the flag. (`authenticate`, OAuth, scopes, Keychain: unchanged.)

### `pill.lua` (`showRightClickMenu`)
- Where the **Re-authenticate** item is built: if `api.needsSetup and
  api.needsSetup()` show **"Enable Spotify extras…"** -> `api.setup` (deferred
  via `hs.timer.doAfter(0, ...)`, like the other menu actions). Otherwise keep
  the existing `supportsReauth` -> Re-authenticate item. Both gated on capability
  presence so Apple Music shows neither.

### `init.lua`
- No change. `:start()` already covers the basic path; the wizard is reached
  from the menu / one-time offer.

### `README.md`
- Spotify section: install -> `:start()` -> "for the extras, pick **Enable
  Spotify extras…** in the right-click menu and follow the prompts." Keep the
  manual dashboard + `authenticate("CLIENT_ID")` steps only as a short
  "prefer to set it up by hand?" fallback.

## Error handling

- Cancelling any dialog, or an empty Client ID, aborts the wizard with no state
  change. The user can re-run it from the menu.
- Auth failures keep the existing `authenticate` alerts (e.g. bad Client ID,
  state mismatch, token exchange failure).
- The one-time offer flag is set when the dialog is shown, not on success, so a
  decline doesn't re-prompt on every launch.

## Testing

- Mostly manual (dialog/browser/Keychain coupled); add to the manual checklist:
  first-run one-time offer appears once; menu item runs the wizard; pasting a
  valid Client ID completes OAuth and the menu flips to Re-authenticate; Cancel
  aborts cleanly; Apple Music shows no setup item.
- `needsSetup()` shells out to the Keychain, so it isn't unit-tested. No new
  pure logic is introduced.

## Out of scope

- Shipping a shared Client ID / removing the per-user app requirement (blocked by
  Spotify's dev-mode 25-user cap).
- Any change to the OAuth scopes or the Apple Music backend.
- Auto-creating the Spotify app via the dashboard (no public API for it).

# Apple Music backend for Hammertunes

Date: 2026-06-01
Status: Approved, ready for implementation plan

## Goal

Let the Hammertunes pill be backed by **Apple Music** as an alternative to Spotify,
selected explicitly by the user. This finishes the refactor the existing
`backends/applemusic.lua` stub describes: lift state-fetch and transport out of
`pill.lua` and behind the backend interface so `pill.lua` is service-agnostic.

## Background and constraints

The pill currently reads now-playing state by running a hardcoded `tell
application "Spotify"` AppleScript (`SPOTIFY_QUERY`) inside `pill.lua`'s
`fetchState()`, and drives transport with `hs.spotify.*` and a local
`tell application "Spotify" to set shuffling` AppleScript. Both are
Spotify-coupled and must move behind the backend before Apple Music can take
over.

Research findings that shape the Apple Music backend (see Sources):

- **macOS Tahoe (26.x) regression.** `tell application "Music"` reads of the
  *current track* (`name`, `artist`, `duration`, `player position`,
  `favorited`) work for tracks **in the user's library** but fail with error
  `-1728` for **streaming Apple Music tracks not added to the library**. For an
  Apple Music subscriber playing catalog songs that is the common case, so a
  naive AppleScript port of `SPOTIFY_QUERY` would show a blank pill most of the
  time.
- **Transport is unaffected.** `hs.itunes.*` (`play/pause/next/previous/
  getPosition/setPosition`) and shuffle are app-level commands, not
  current-track reads, so they work regardless of library status.
- **Workaround for now-playing reads: the private MediaRemote framework** via
  JXA (`hs.osascript.javascript`). It returns title/artist/album/duration/
  position/playback-rate system-wide, including for streaming tracks. Caveats:
  it is a *private* framework (can break across OS updates) and artwork data is
  unreliable/often nil.
- **"Loved" is now `favorited`** in the Music scripting dictionary, and reading
  it hits the same library-only limitation on Tahoe.

### Decisions taken during brainstorming

1. **Backend selection: explicit config** (not auto-detect). One backend per
   session, chosen by the user.
2. **Now-playing source: AppleScript-first, MediaRemote/JXA fallback.** Full
   data (incl. artwork) for library tracks via AppleScript; fall back to
   MediaRemote for title/artist/position when the current-track read fails.
3. **Menu features for v1: favorite (like/unlike), play library playlists, and
   add-to-playlist** - all via AppleScript, library-tracks-only where Tahoe
   forces it.
4. **Decouple "Play Playlist" from the current-track id** so it stays available
   during streaming/local playback (also a small improvement for Spotify local
   files).

## Backend interface

`pill.lua` will depend only on the methods/fields below. Both backends
implement them. Additions relative to today are marked **NEW**.

### Identity / capabilities (NEW)
- `appName` - macOS app name for `hs.application.launchOrFocus` and for the
  "… not running" / "Open …" labels. `"Spotify"` / `"Music"`.
- `supportsSmartShuffle` - bool. Gates the read-only "Smart Shuffle" menu item.
  Spotify `true`, Apple Music `false`.
- `supportsReauth` - bool. Gates the "Re-authenticate" menu item. Spotify
  `true`, Apple Music `false`.

### State (NEW)
- `getState()` → `{ running, playing, track, artist, progress, durMs, artUrl?,
  artPath?, trackId, shuffle }`. Replaces `pill.lua`'s `fetchState()`.
  - `artUrl` - http(s) cover URL (Spotify).
  - `artPath` - local file path to a cover image (Apple Music library tracks).
    Exactly one of `artUrl`/`artPath` is set when art is available; both nil
    otherwise.
  - `trackId` - opaque per-backend track identifier, present only when the
    track supports library actions (Spotify track id; Apple Music `database
    id`). `nil` for local/streaming tracks that can't be liked/added.

### Transport (NEW)
- `next()`, `previous()`, `playpause()`, `play()`
- `getPosition()` → seconds (number) or nil
- `setPosition(sec)`
- `setShuffling(on)` - toggle the player's own shuffle (local, no Web API).

### Context (unchanged)
- `getName()`, `getUri()`, `getLiked()`, `getSmartShuffle()`, `refresh()`,
  `refreshLiked(trackId)`

### Library / playback (unchanged signatures)
- `getPlaylists()` → list of `{ id, name, owned, imageUrl?, uri }`.
  **NEW:** every item carries an opaque `uri` so `pill.lua` no longer
  constructs `spotify:playlist:…` itself - it hands the backend's token back to
  `playContext`.
- `refreshPlaylists(cb)`
- `getRecentlyPlayed()` / `refreshRecentlyPlayed(cb)` - Apple Music returns
  empty / no-ops (no API for it).
- `addToPlaylist(playlistId, trackId, cb)`
- `like(trackId)` / `unlike(trackId)`
- `playContext(uri, mode)` - `mode` is `"play" | "shuffle" | "smart"`.
- `playLikedSongs(mode)` - **optional**; absent on Apple Music, so the menu item
  is hidden (pill already guards `if api.playLikedSongs`).

### Lifecycle (unchanged)
- `start(onChange)`, `stop()`, `authenticate(id)` (no-op for Apple Music).

## Component changes

### `pill.lua` (must stay behavior-preserving for Spotify)
- Remove `SPOTIFY_QUERY` and `fetchState()`; `render()` calls `api.getState()`.
- Replace every `hs.spotify.*` call and the local `setShuffling` AppleScript
  with the `api.*` transport methods:
  - `seekToMouse` → `api.setPosition`
  - hold-to-play → `api.play`
  - `onLeftClick` → `api.getPosition` / `api.setPosition` / `api.previous`
  - `onRightClick` → `api.next`
  - `onMiddleClick` → `api.playpause`
  - `setShuffling(on)` → `api.setShuffling(on)`
- Labels and launch use `api.appName`:
  - "Spotify not running" → `api.appName .. " not running"`
  - fallback tooltip "Spotify" → `api.appName`
  - "Open Spotify" → `"Open " .. api.appName`
  - `hs.application.launchOrFocus("Spotify")` → `launchOrFocus(api.appName)`
- "Smart Shuffle" item shown only when `api.supportsSmartShuffle`.
- "Re-authenticate" item shown only when `api.supportsReauth`.
- "Play Playlist" (and "Play Liked Songs") moved **out** of the `if lastTrackId`
  guard so they appear whenever a backend is connected. "Like"/"Unlike" and
  "Add to Playlist" stay gated on `lastTrackId` (they need a track).
- Play Playlist items use the backend-provided `p.uri` instead of building
  `"spotify:playlist:" .. p.id`.
- Art pipeline generalized from URL-only to **URL or local file path**:
  `ensureArt` accepts the state's art descriptor, fetching `artUrl` over http
  (as today) or loading `artPath` via `hs.image.imageFromPath`, cached by
  whichever key is present.

### `backends/spotify.lua` (relocation, no functional change)
- Add `getState()`: the existing `SPOTIFY_QUERY` AppleScript + the parsing now
  in `pill.lua`'s `fetchState()`.
- Add transport wrappers over `hs.spotify.*` and a `setShuffling(on)` that runs
  the `tell application "Spotify" to set shuffling` AppleScript.
- Add `appName = "Spotify"`, `supportsSmartShuffle = true`,
  `supportsReauth = true`.
- Add `uri = "spotify:playlist:" .. id` to each `getPlaylists()` item.

### `backends/applemusic.lua` (new - replaces the stub `error(...)`)
- **State:** `getState()` tries `tell application "Music"` for the current
  track. On the Tahoe `-1728` failure (or running-but-no-readable-track), fall
  back to **MediaRemote via `hs.osascript.javascript`** for title/artist/album/
  duration/position/playback-rate. Cache which path works for the current track
  so each tick makes one `osascript` call, not two; re-probe on track change.
- **Artwork:** for library tracks, export the current track's artwork to a temp
  PNG once per track-change and return it as `artPath`. Streaming-track artwork
  is best-effort (likely absent) → pill shows `♪`.
- **trackId:** the track's `database id` (number), present only for library
  tracks; `nil` for streaming. This makes favorite / add-to-playlist appear only
  when they can succeed, and vanish for streaming tracks.
- **Transport:** `hs.itunes.*`; `setShuffling` and the shuffle read via
  `tell application "Music"`.
- **Favorite:** `getLiked` / `like` / `unlike` map to the track's `favorited`
  property (library tracks only; no-op / nil otherwise).
- **Playlists:** `getPlaylists` lists library playlists as `{ id, name,
  owned=true, uri }` (no thumbnails). `playContext(uri, mode)` plays the
  playlist with shuffle off for `"play"`, on for `"shuffle"`/`"smart"` (Apple
  Music has no smart shuffle). `addToPlaylist` adds the current library track to
  the named playlist.
- **Absent:** `playLikedSongs`, recently-played (empty / no-ops),
  `supportsSmartShuffle = false`, `supportsReauth = false`, `authenticate` is a
  no-op.

### `init.lua` - explicit backend selection
- Add `obj:setBackend(name)` (`"spotify"` default, `"applemusic"`), returning
  self. Also honor `:start({ backend = "applemusic" })` as sugar.
- `backend(self)` loads `backends/<name>.lua` based on the stored name instead
  of hardcoding `spotify.lua`.
- `:authenticate()` remains a no-op for Apple Music.

## Data flow

`pill.lua` 1 Hz `render()`:
1. `s = api.getState()` (synchronous; AppleScript and/or JXA `osascript`).
2. On track change, `api.refresh()` (context name) and `api.refreshLiked(s.trackId)`.
3. Render badge from `s` (art via `artUrl`/`artPath`), build tooltip.

Right-click menu builds synchronously from cached backend state
(`getLiked/getPlaylists/getRecentlyPlayed`), with thumbnails pre-warmed from
`render()`.

## Error handling

- AppleScript current-track read fails → Apple Music backend falls back to
  MediaRemote rather than reporting "not running".
- MediaRemote framework load fails (future OS change) → Apple Music now-playing
  degrades to library-tracks-only; transport still works. Log once, don't spam.
- `getState()` returns `{ running = false }` only when the app is genuinely not
  running, matching current pill behavior.
- Library-only actions (favorite, add-to-playlist) are unreachable for streaming
  tracks because `trackId` is nil, so they fail closed rather than erroring.

## Testing

- Spotify regression: pill behaves identically after the refactor (now-playing,
  click zones, scrub, copy, shuffle, like, playlists) - this is the primary
  guard since Spotify code only moves, it doesn't change.
- Apple Music, library track: now-playing + artwork, transport, scrub, favorite
  toggle, play playlist, add-to-playlist.
- Apple Music, streaming track on Tahoe: now-playing via MediaRemote fallback
  (title/artist/progress present, art may be absent), transport works, favorite
  / add-to-playlist hidden, Play Playlist still available.
- Backend selection: `:setBackend("applemusic")` and
  `:start({backend="applemusic"})` both load the Apple Music backend; default
  stays Spotify.

## Out of scope (v1)

- MusicKit / OAuth for Apple Music (no developer token; AppleScript + MediaRemote
  only).
- Apple Music playlist cover thumbnails in the menu.
- Recently-played pinning for Apple Music.
- "Play Liked Songs" for Apple Music.
- Auto-detecting which player is running.

## Sources

- Music AppleScript current-track regression on Tahoe:
  <https://developer.apple.com/forums/thread/798267>,
  <https://discussions.apple.com/thread/256158179>
- `hs.itunes` methods: <https://www.hammerspoon.org/docs/hs.itunes.html>
- MediaRemote now-playing via JXA on macOS 26:
  <https://gist.github.com/SKaplanOfficial/f9f5bdd6455436203d0d318c078358de>
- Music scripting properties (`favorited`, player position, shuffle, playlists):
  <https://dougscripts.com/itunes/itinfo/info02.php>

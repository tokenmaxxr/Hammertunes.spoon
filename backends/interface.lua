-- Backend interface contract for Hammertunes.
--
-- This file is the single source of truth for the duck-typed convention that
-- backends/spotify.lua and backends/applemusic.lua both follow. It contains:
--   1. A LuaCATS class annotation documenting every required and optional field.
--   2. A runtime verifier (module.verify) that checks every required member on
--      a freshly loaded backend and errors loudly if anything is missing or
--      has the wrong type.

local module = {}

-- ---------------------------------------------------------------------------
-- LuaCATS contract
-- ---------------------------------------------------------------------------

---@class HammertunesBackend
---
--- REQUIRED — both backends implement these; callers invoke them unguarded.
---
---@field appName string macOS app name used by launchOrFocus ("Spotify", "Music")
---
--- State / polling
---@field getState fun(): table Now-playing snapshot: {running, playing, track, artist, progress, durMs, artUrl, artPath, trackId, shuffle}
---@field start fun(changeCallback: fun()) Begin polling; call changeCallback whenever state changes
---@field stop fun() Tear down all timers and watchers
---@field refresh fun() Re-poll async caches (context name, liked state) immediately
---
--- Liked-state management
---@field refreshLiked fun(trackId: string, force?: boolean) Re-fetch liked state for a track; bypass cache when force=true
---@field getLiked fun(): boolean|nil Cached liked state for the current track (nil = unknown/fetching)
---@field like fun(trackId: string) Mark a track as liked
---@field unlike fun(trackId: string) Remove liked from a track
---
--- Playlists
---@field getPlaylists fun(): table|nil Cached playlist array, each: {id, name, uri, owned, imageUrl}
---@field refreshPlaylists fun(callback?: fun()) Rebuild the playlist cache; fires optional callback when done
---
--- Recently played
---@field getRecentlyPlayed fun(): table|nil Cached recently-played array, each: {id, name, uri, imageUrl}
---@field refreshRecentlyPlayed fun(callback?: fun()) Refresh the recently-played cache; fires optional callback when done
---
--- Playlist mutation
---@field addToPlaylist fun(playlistId: string, trackId: string, callback?: fun(ok: boolean)) Add a track to a playlist
---
--- Context playback
---@field playContext fun(uri: string, mode?: "play"|"shuffle"|"smart") Start playing a context URI
---@field getName fun(): string|nil Name of the currently playing context (playlist / album / radio), or nil
---@field getUri fun(): string|nil URI of the currently playing context, or nil
---
--- Shuffle
---@field getSmartShuffle fun(): boolean|nil Spotify Smart Shuffle state; nil if unsupported
---@field setShuffling fun(on: boolean) Toggle shuffle on the active player
---
--- Transport
---@field getPosition fun(): number Current playback position in seconds
---@field setPosition fun(seconds: number) Seek to a position
---@field previous fun() Skip to previous track
---@field next fun() Skip to next track
---@field playpause fun() Toggle play/pause
---@field play fun() Resume playback
---
--- Authentication
---@field authenticate fun(clientId?: string) One-time OAuth setup; may be a no-op (Apple Music)
---
--- OPTIONAL — nil means the backend doesn't support it; menu/controller gates
--- on truthiness before calling these.
---
---@field playLikedSongs fun(mode?: "play"|"shuffle"|"smart")|nil Start playing the Liked Songs collection (Spotify only)
---@field needsSetup fun(): boolean|nil True when the backend has not been authenticated yet
---@field setup fun()|nil Run the guided setup wizard
---@field setupLabel string|nil Menu label for the setup item
---@field supportsSmartShuffle boolean|nil Backend exposes a read-only Smart Shuffle state
---@field supportsReauth boolean|nil "Switch account" re-auth is available for this backend
---@field likedPollSeconds number|nil Re-poll liked state every N seconds during playback
---@field likedColor table|nil Accent colour for the heart icon: {red, green, blue}

-- ---------------------------------------------------------------------------
-- Runtime verifier
-- ---------------------------------------------------------------------------

-- Every member that every backend MUST provide, with its expected Lua type.
-- Keep in sync with the ---@field block above; tests assert each key here has
-- a matching @field annotation. Exported so tests derive stubs from it.
local REQUIRED = {
  appName              = "string",
  getState             = "function",
  start                = "function",
  stop                 = "function",
  refresh              = "function",
  refreshLiked         = "function",
  getLiked             = "function",
  like                 = "function",
  unlike               = "function",
  getPlaylists         = "function",
  refreshPlaylists     = "function",
  getRecentlyPlayed    = "function",
  refreshRecentlyPlayed = "function",
  addToPlaylist        = "function",
  playContext          = "function",
  getName              = "function",
  getUri               = "function",
  getSmartShuffle      = "function",
  setShuffling         = "function",
  getPosition          = "function",
  setPosition          = "function",
  previous             = "function",
  next                 = "function",
  playpause            = "function",
  play                 = "function",
  authenticate         = "function",
}

-- verify(backend, name) checks every required member. On success returns the
-- backend (chainable). On failure, errors with all problems in one message.
function module.verify(backend, name)
  local problems = {}
  for member, expectedType in pairs(REQUIRED) do
    local actual = type(backend[member])
    if actual == "nil" then
      problems[#problems + 1] = "missing " .. expectedType .. " " .. member
    elseif actual ~= expectedType then
      problems[#problems + 1] = member .. " must be a " .. expectedType
    end
  end
  if #problems > 0 then
    table.sort(problems)
    error(name .. " does not satisfy the backend interface: " ..
      table.concat(problems, ", "), 2)
  end
  return backend
end

module.REQUIRED = REQUIRED

return module

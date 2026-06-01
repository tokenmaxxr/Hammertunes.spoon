--- === Hammertunes ===
---
--- A menubar "pill" that shows what's playing and lets you control it without
--- leaving the keyboard's reach. Album / playlist artwork, a live progress bar,
--- press-and-hold scrubbing, click-zone transport (prev / play-pause / next),
--- double-click to copy "Song by Artist", and a right-click menu for shuffle
--- modes, like/unlike, and playlist management with cover thumbnails.
---
--- Currently backed by Spotify (AppleScript + Web API). The backend lives behind
--- a small interface (`backends/`) so Apple Music can slot in later.
---
--- Usage:
---   hs.loadSpoon("Hammertunes")
---   spoon.Hammertunes:authenticate("YOUR_SPOTIFY_CLIENT_ID")  -- one time
---   spoon.Hammertunes:start()
---
--- Download: https://github.com/tokenmaxxr/Hammertunes.spoon

local obj = {}
obj.__index = obj

obj.name = "Hammertunes"
obj.version = "0.1.0"
obj.author = "tokenmaxxr"
obj.homepage = "https://github.com/tokenmaxxr/Hammertunes.spoon"
obj.license = "MIT - https://opensource.org/licenses/MIT"

-- Absolute path to this Spoon's directory (trailing slash). Derived from this
-- file's own location so sibling files load no matter how the Spoon was loaded.
obj.spoonPath = debug.getinfo(1, "S").source:sub(2):gsub("init%.lua$", "")

-- Optional power-user hook. If set to a function before :start(), the pill
-- collapses to a neutral "♪" whenever hideContext(contextUri) returns truthy
-- (e.g. to keep a particular playlist off the menubar). Off by default.
obj.hideContext = nil

obj._pill = nil
obj._badge = nil
obj._backend = nil

local function load(self, rel)
  return dofile(self.spoonPath .. rel)
end

-- The Spotify backend is a stateful singleton; load it once and reuse so
-- :authenticate() and :start() share the same token/cache state.
local function backend(self)
  if not self._backend then self._backend = load(self, "backends/spotify.lua") end
  return self._backend
end

--- Hammertunes:authenticate(clientId)
--- Method
--- One-time Spotify Web API setup. Opens a browser to approve access; the
--- refresh token is stored in the macOS Keychain and reused on every launch.
---
--- Parameters:
---  * clientId - your Spotify app's Client ID from developer.spotify.com.
---    Optional after the first successful auth (it's cached in the Keychain).
---
--- Returns:
---  * The Hammertunes object
function obj:authenticate(clientId)
  backend(self).authenticate(clientId)
  return self
end

--- Hammertunes:start()
--- Method
--- Creates the menubar pill and starts polling. Call after :authenticate().
---
--- Parameters:
---  * None
---
--- Returns:
---  * The Hammertunes object
function obj:start()
  if self._pill then return self end
  self._badge = load(self, "badge.lua")
  self._pill = load(self, "pill.lua")
  self._pill.start({
    badge = self._badge,
    api = backend(self),
    hideContext = self.hideContext,
  })
  return self
end

--- Hammertunes:stop()
--- Method
--- Removes the pill and stops all timers/watchers.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The Hammertunes object
function obj:stop()
  if self._pill then self._pill.stop() end
  self._pill = nil
  return self
end

return obj

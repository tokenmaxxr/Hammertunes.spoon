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
obj._backendName = "spotify"

-- hs.settings key for the user's persisted backend choice (written and read in
-- separate methods, so it lives in one place).
local BACKEND_SETTING_KEY = "Hammertunes.backend"

-- User-facing display names per backend. Kept here (not on the backend modules)
-- because the menu's "Switch to …" label names the OTHER, unloaded backend, and
-- because backend.appName is the macOS app name ("Music"), not "Apple Music".
local DISPLAY_NAMES = { spotify = "Spotify", applemusic = "Apple Music" }

-- The other backend, for the menu toggle (assumes the two-backend v1 set).
local function otherBackend(name)
  return name == "applemusic" and "spotify" or "applemusic"
end

local function load(self, rel)
  return dofile(self.spoonPath .. rel)
end

-- The backend is a stateful singleton; load it once and reuse so
-- :authenticate() and :start() share the same token/cache state. The
-- concrete backend (Spotify / Apple Music) is chosen via :setBackend().
local function backend(self)
  if not self._backend then
    self._backend = load(self, "backends/" .. self._backendName .. ".lua")
  end
  return self._backend
end

--- Hammertunes:setBackend(name)
--- Method
--- Selects which music service backs the pill. Call before :start().
--- Note: a choice the user made via the menu's "Switch to …" item is persisted
--- and OVERRIDES this at :start() (see :switchBackend and :start).
---
--- Parameters:
---  * name - "spotify" (default) or "applemusic"
---
--- Returns:
---  * The Hammertunes object
function obj:setBackend(name)
  name = name or "spotify"
  if name ~= self._backendName then
    self._backendName = name
    self._backend = nil
  end
  return self
end

--- Hammertunes:switchBackend(name)
--- Method
--- Switches the live backend and persists the choice across reloads. Backs the
--- right-click menu's "Switch to …" item. Tears the pill down and restarts it
--- on the new backend; the persisted choice is reapplied on every later :start().
---
--- Parameters:
---  * name - "spotify" or "applemusic"
---
--- Returns:
---  * The Hammertunes object
function obj:switchBackend(name)
  hs.settings.set(BACKEND_SETTING_KEY, name)
  self:stop()
  self:setBackend(name)
  self:start()
  return self
end

--- Hammertunes:authenticate(clientId)
--- Method
--- One-time Spotify Web API setup. Opens a browser to approve access; the
--- refresh token is stored in the macOS Keychain and reused on every launch.
--- No-op for the Apple Music backend.
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

--- Hammertunes:start([opts])
--- Method
--- Creates the menubar pill and starts polling. Call after :authenticate().
--- Precedence: a backend the user picked from the menu's "Switch to …" item is
--- persisted and OVERRIDES both opts.backend and any prior :setBackend().
---
--- Parameters:
---  * opts - optional table; opts.backend selects "spotify" (default) or "applemusic"
---
--- Returns:
---  * The Hammertunes object
function obj:start(opts)
  if self._pill then return self end
  -- A persisted choice from :switchBackend wins over config-time selection.
  local choice = hs.settings.get(BACKEND_SETTING_KEY) or (opts and opts.backend)
  if choice then self:setBackend(choice) end
  self._badge = load(self, "badge.lua")
  self._pill = load(self, "pill.lua")
  -- Hand pill a ready display label and an opaque toggle. The toggle defers
  -- itself because it tears down the very pill/menu that invokes it, so pill
  -- doesn't need to know that.
  local other = otherBackend(self._backendName)
  self._pill.start({
    badge = self._badge,
    api = backend(self),
    hideContext = self.hideContext,
    switchLabel = DISPLAY_NAMES[other],
    switchBackend = function()
      hs.timer.doAfter(0, function() self:switchBackend(other) end)
    end,
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

-- Pure helpers exposed for unit tests (see tests/).
obj._test = { otherBackend = otherBackend, DISPLAY_NAMES = DISPLAY_NAMES }

return obj

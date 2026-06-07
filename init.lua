--- === Hammertunes ===
---
--- A menubar "pill" that shows what's playing and lets you control it without
--- leaving the keyboard's reach. Album / playlist artwork, a live progress bar,
--- press-and-hold scrubbing, click-zone transport (prev / play-pause / next),
--- double-click to copy "Song by Artist", and a right-click menu for shuffle
--- modes, like/unlike, and playlist management with cover thumbnails.
---
--- Backed by Spotify (AppleScript + Web API) or Apple Music (alpha); both live
--- behind a small shared interface (`backends/`). Switch from the right-click
--- menu or via :setBackend().
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

-- Update check, on by default. :start() compares the checked-out Spoon against
-- its git remote (async, never blocks the menubar); if behind, an "Update
-- available" item appears in the right-click menu that pulls and reloads when
-- clicked. It never pulls without that click. Set false before :start() to
-- disable the check entirely. See also `make update`.
obj.checkForUpdates = true

obj._menubar = nil
obj._pill = nil
obj._backend = nil
obj._backendName = "spotify"
obj._updateAvailable = false

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

-- Run a shell command asynchronously, calling back with (exitCode, stdout).
-- hs.task starts from a minimal environment, so the usual Homebrew/system git
-- locations are prepended to PATH.
local function sh(cmd, cb)
  local full = "export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:$PATH; " .. cmd
  hs.task.new("/bin/sh", function(code, out) cb(code, out or "") end, { "-c", full }):start()
end

-- The backend is a stateful singleton; load it once and reuse so
-- :authenticate() and :start() share the same token/cache state. The
-- concrete backend (Spotify / Apple Music) is chosen via :setBackend().
-- Every fresh load is checked against the backend interface so contract
-- violations surface immediately at startup, not on a menu click later.
-- The interface module is stateless, so it's loaded once and reused across
-- backend switches.
local interface = nil
local function backend(self)
  if not self._backend then
    interface = interface or load(self, "backends/interface.lua")
    local rel = "backends/" .. self._backendName .. ".lua"
    self._backend = interface.verify(load(self, rel), rel)
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

--- Hammertunes:checkUpdates([callback])
--- Method
--- Fetches the remote and checks whether the checked-out Spoon is behind it.
--- Sets an internal flag that surfaces an "Update available" item in the
--- right-click menu. Runs automatically on :start() when `checkForUpdates` is
--- true; safe to call manually too. Network and git access are async, so this
--- never blocks the menubar.
---
--- Parameters:
---  * callback - optional function(updateAvailable, commitsBehind)
---
--- Returns:
---  * The Hammertunes object
function obj:checkUpdates(callback)
  local p = self.spoonPath
  local cmd = ("git -C '%s' fetch -q && git -C '%s' rev-list --count HEAD..@{u} 2>/dev/null")
    :format(p, p)
  sh(cmd, function(code, out)
    local behind = tonumber((out:gsub("%s+", ""))) or 0
    self._updateAvailable = (code == 0 and behind > 0)
    if callback then callback(self._updateAvailable, behind) end
  end)
  return self
end

--- Hammertunes:update()
--- Method
--- Pulls the latest Spoon commit (fast-forward only) and reloads Hammerspoon on
--- success. Backs the menu's "Update available" item.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The Hammertunes object
function obj:update()
  sh(("git -C '%s' pull --ff-only -q"):format(self.spoonPath), function(code)
    if code == 0 then
      hs.alert.show("Hammertunes updated - reloading…")
      hs.timer.doAfter(0.5, hs.reload)
    else
      hs.alert.show("Hammertunes update failed - pull manually")
    end
  end)
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
  if self._menubar then return self end
  -- A persisted choice from :switchBackend wins over config-time selection.
  local choice = hs.settings.get(BACKEND_SETTING_KEY) or (opts and opts.backend)
  if choice then self:setBackend(choice) end
  self._pill = load(self, "pill.lua")
  self._menubar = load(self, "menubar.lua")
  -- Hand menubar a ready display label and an opaque toggle. The toggle defers
  -- itself because it tears down the very menubar item/menu that invokes it, so
  -- menubar doesn't need to know that.
  local other = otherBackend(self._backendName)
  self._menubar.start({
    pill = self._pill,
    images = load(self, "images.lua"),
    rightclick = load(self, "rightclick.lua"),
    api = backend(self),
    hideContext = self.hideContext,
    switchLabel = DISPLAY_NAMES[other],
    switchBackend = function()
      hs.timer.doAfter(0, function() self:switchBackend(other) end)
    end,
    -- A getter (read fresh each menu open) plus a deferred action: :update()
    -- reloads, tearing down the menu that invoked it, so defer past popupMenu.
    updateAvailable = function() return self._updateAvailable end,
    update = function() hs.timer.doAfter(0, function() self:update() end) end,
  })
  -- Opt-in update check, deferred so it never delays the pill appearing.
  if self.checkForUpdates then
    hs.timer.doAfter(2, function() self:checkUpdates() end)
  end
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
  if self._menubar then self._menubar.stop() end
  self._menubar = nil
  return self
end

-- Pure helpers exposed for unit tests (see tests/).
obj._test = { otherBackend = otherBackend, DISPLAY_NAMES = DISPLAY_NAMES }

return obj

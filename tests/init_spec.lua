local t = require("helper")
local obj = t.loadModule("init.lua")
local T = obj._test

t.test("init: otherBackend flips spotify <-> applemusic", function()
  t.eq(T.otherBackend("spotify"), "applemusic")
  t.eq(T.otherBackend("applemusic"), "spotify")
end)

t.test("init: anything not applemusic flips to applemusic (spotify is the default side)", function()
  t.eq(T.otherBackend("anything-else"), "applemusic")
end)

t.test("init: display names are the user-facing strings, not app names", function()
  t.eq(T.DISPLAY_NAMES.spotify, "Spotify")
  t.eq(T.DISPLAY_NAMES.applemusic, "Apple Music")  -- NOT "Music" (the macOS app name)
end)

-- Fake only the Spoon's collaborators; keep timers and tasks pending so tests
-- can deliver old work after stop/restart and in a different completion order.
local function withLifecycle(fn)
  local savedHs, savedDofile = hs, dofile
  local timers, tasks, menus = {}, {}, {}
  local stopped, reloaded = 0, 0
  local fakeBackend = { stop = function() stopped = stopped + 1 end }
  local settings = {}
  _G.hs = {
    settings = {
      get = function(k) return settings[k] end,
      set = function(k, v) settings[k] = v end,
    },
    timer = { doAfter = function(_, cb)
      local timer = { callback = cb, stopped = false }
      function timer:stop() self.stopped = true end
      timers[#timers + 1] = timer
      return timer
    end },
    task = { new = function(_, cb, args)
      local task = { callback = cb, args = args, start = function(self) return self end }
      tasks[#tasks + 1] = task
      return task
    end },
    alert = { show = function() end },
    reload = function() reloaded = reloaded + 1 end,
  }
  _G.dofile = function(path)
    local rel = path:sub(#t.ROOT + 1)
    if rel == "menubar.lua" then
      return {
        start = function(deps) menus[#menus + 1] = deps end,
        stop = fakeBackend.stop,
      }
    elseif rel == "backends/interface.lua" then
      return { verify = function(b) return b end }
    elseif rel == "backends/spotify.lua" or rel == "backends/applemusic.lua" then
      return fakeBackend
    elseif rel == "pill.lua" or rel == "images.lua" or rel == "rightclick.lua" then
      return {}
    end
    return savedDofile(path)
  end
  local ok, err = pcall(fn, t.loadModule("init.lua"), {
    timers = timers, tasks = tasks, menus = menus, settings = settings,
    stopped = function() return stopped end,
    reloaded = function() return reloaded end,
  })
  _G.hs, _G.dofile = savedHs, savedDofile
  if not ok then error(err, 0) end
end

t.test("init: stop cancels startup checks and deferred menu actions", function()
  withLifecycle(function(spoon, h)
    spoon:start()
    local menu = h.menus[1]
    menu.switchBackend()
    menu.update()
    spoon:stop()
    for _, timer in ipairs(h.timers) do
      t.ok(timer.stopped)
      timer.callback() -- even an already queued callback must be harmless
    end
    menu.switchBackend() -- a menu retained by an old callback cannot restart us
    menu.update()
    t.eq(#h.tasks, 0)
    t.eq(#h.menus, 1)
    t.eq(h.settings["Hammertunes.backend"], nil)
    t.eq(spoon._menubar, nil)
    t.eq(h.stopped(), 1)
  end)
end)

t.test("init: late update checks cannot affect a restarted session", function()
  withLifecycle(function(spoon, h)
    local delivered = 0
    spoon:start()
    spoon:checkUpdates(function() delivered = delivered + 1 end)
    spoon:stop():start()
    h.tasks[1].callback(0, "9\n")
    t.eq(spoon._updateAvailable, false)
    t.eq(delivered, 0)
    spoon:checkUpdates()
    spoon:checkUpdates()
    h.tasks[3].callback(0, "2\n")
    h.tasks[2].callback(0, "0\n")
    t.eq(spoon._updateAvailable, true)
  end)
end)

t.test("init: stop suppresses an update completion and scheduled reload", function()
  withLifecycle(function(spoon, h)
    spoon:update()
    spoon:stop()
    h.tasks[1].callback(0, "")
    t.eq(#h.timers, 0)
    spoon:update()
    h.tasks[2].callback(0, "")
    spoon:stop()
    h.timers[1].callback()
    t.eq(h.reloaded(), 0)
  end)
end)

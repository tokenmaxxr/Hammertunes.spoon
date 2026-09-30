local t = require("helper")
local menubar = t.loadModule("menubar.lua")
local T = menubar._test

t.test("menubar: truncate leaves short strings unchanged", function()
  t.eq(T.truncate("hello", 10), "hello")
  t.eq(T.truncate("hello", 5), "hello")
end)

t.test("menubar: truncate keeps (max-1) chars plus an ellipsis", function()
  t.eq(T.truncate("hello world", 5), "hell…")
end)

t.test("menubar: truncate counts characters, not bytes (utf8)", function()
  t.eq(T.truncate("café", 10), "café")       -- 4 chars, under the limit
end)

t.test("menubar: truncate handles nil as empty string", function()
  t.eq(T.truncate(nil, 5), "")
end)

-- Exercise the eventtap registered by start(), including its subscription and
-- event-consumption contract, without depending on native status-item tracking.
local function withGestures(fn)
  local savedHs = hs
  local timers, calls = {}, {}
  local now, mouse, watcher = 0, { x = 150, y = 10 }, nil
  local types = {
    leftMouseDown = 1, leftMouseUp = 2, leftMouseDragged = 3, rightMouseDown = 4,
  }
  local function record(name, value) calls[#calls + 1] = { name, value } end
  local function newTimer(delay, callback, repeating)
    local timer = { due = now + delay, callback = callback, repeating = repeating }
    function timer:stop() self.stopped = true end
    function timer:start() return self end
    timers[#timers + 1] = timer
    return timer
  end
  local menu = {}
  function menu:_frame() return { x = 100, y = 980, w = 100, h = 20 } end
  function menu:setTitle() end
  function menu:setTooltip() end
  function menu:setClickCallback(callback) self.click = callback end
  function menu:delete() end
  hs = {
    logger = savedHs.logger,
    menubar = { new = function() return menu end },
    screen = { primaryScreen = function()
      return { fullFrame = function() return { h = 1000 } end }
    end },
    geometry = function(value)
      return setmetatable(value, { __index = { inside = function(point, frame)
        return point.x >= frame.x and point.x < frame.x + frame.w
          and point.y >= frame.y and point.y < frame.y + frame.h
      end } })
    end,
    mouse = { absolutePosition = function() return mouse end },
    timer = {
      doAfter = function(delay, callback) return newTimer(delay, callback) end,
      doEvery = function(delay, callback) return newTimer(delay, callback, delay) end,
      secondsSinceEpoch = function() return now end,
    },
    eventtap = {
      event = { types = types },
      new = function(subscriptions, callback)
        watcher = { callback = callback, subscriptions = {} }
        for _, kind in ipairs(subscriptions) do watcher.subscriptions[kind] = true end
        function watcher:start() return self end
        function watcher:stop() self.stopped = true end
        return watcher
      end,
    },
    pasteboard = { setContents = function(value) record("copy", value) end },
    alert = { show = function() end },
  }
  local subject
  local ok, err = pcall(function()
    subject = t.loadModule("menubar.lua")
    local noop = function() end
    subject.start({
      pill = { new = function() return { update = noop } end },
      images = { newCache = function()
        return { getPath = noop, getUrl = noop, reset = noop }
      end },
      rightclick = { build = function() return {} end },
      api = {
        appName = "Test player",
        getState = function()
          return { running = true, playing = true, track = "Song", artist = "Artist",
            trackId = "song", durMs = 200000, progress = 0.1 }
        end,
        getPlaylists = noop, getRecentlyPlayed = noop, getUri = noop,
        getName = noop, getLiked = noop, refresh = noop, refreshLiked = noop,
        start = noop, stop = noop,
        getPosition = function() return 10 end,
        setPosition = function(value) record("seek", value) end,
        play = function() record("play") end,
        playpause = function() record("playpause") end,
        previous = function() record("previous") end,
        next = function() record("next") end,
      },
    })
    local harness = { calls = calls, stop = subject.stop }
    function harness.advance(seconds)
      local target = now + seconds
      while true do
        local nextTimer
        for _, timer in ipairs(timers) do
          if not timer.stopped and timer.due <= target
            and (not nextTimer or timer.due < nextTimer.due) then nextTimer = timer end
        end
        if not nextTimer then break end
        now = nextTimer.due
        if nextTimer.repeating then
          nextTimer.due = now + nextTimer.repeating
        else
          nextTimer.stopped = true
        end
        nextTimer.callback()
      end
      now = target
    end
    function harness.event(kind, x, flags)
      mouse = { x = x or mouse.x, y = 10 }
      local eventType = types[kind]
      if watcher.stopped or not watcher.subscriptions[eventType] then return false end
      return watcher.callback({
        getType = function() return eventType end,
        getFlags = function() return flags or {} end,
        location = function() return mouse end,
      })
    end
    fn(harness)
  end)
  if subject then pcall(subject.stop) end
  hs = savedHs
  if not ok then error(err, 0) end
end

t.test("menubar: owned hold seeks to relative position and suppresses release click", function()
  withGestures(function(h)
    t.eq(h.event("leftMouseDown", 175), true)
    h.advance(0.99)
    t.eq(h.calls, {})
    h.advance(0.01)
    t.eq(h.calls, { { "seek", 150 }, { "play" } })
    t.eq(h.event("leftMouseUp"), true)
    h.advance(0.3)
    t.eq(h.calls, { { "seek", 150 }, { "play" } })
  end)
end)

t.test("menubar: drag seeks are throttled and clamped until release", function()
  withGestures(function(h)
    t.eq(h.event("leftMouseDown", 150), true)
    h.advance(1)
    t.eq(h.event("leftMouseDragged", 170), true)
    t.eq(#h.calls, 2)
    h.advance(0.11)
    t.eq(h.event("leftMouseDragged", 250), true)
    t.eq(h.calls[3], { "seek", 200 })
    h.advance(0.11)
    t.eq(h.event("leftMouseDragged", 50), true)
    t.eq(h.calls[4], { "seek", 0 })
    t.eq(h.event("leftMouseUp", 50), true)
    h.advance(0.2)
    t.eq(h.event("leftMouseDragged", 150), false)
    t.eq(#h.calls, 4)
  end)
end)

t.test("menubar: short release outside cancels hold and transport", function()
  withGestures(function(h)
    t.eq(h.event("leftMouseDown", 150), true)
    h.advance(0.1)
    t.eq(h.event("leftMouseUp", 250), true)
    h.advance(2)
    t.eq(h.calls, {})
  end)
end)

t.test("menubar: short releases preserve transport zones and double-click copy", function()
  withGestures(function(h)
    local function click(x)
      t.eq(h.event("leftMouseDown", x), true)
      t.eq(h.event("leftMouseUp", x), true)
      h.advance(0)
    end
    click(110)
    click(190)
    click(150)
    h.advance(0.26)
    t.eq(h.calls, { { "seek", 0 }, { "next" }, { "playpause" } })
    click(150)
    h.advance(0.1)
    click(150)
    h.advance(1.1)
    t.eq(h.calls, {
      { "seek", 0 }, { "next" }, { "playpause" }, { "copy", "Song by Artist" },
    })
  end)
end)

t.test("menubar: Command bypasses new presses but still cleans up an owned release", function()
  withGestures(function(h)
    t.eq(h.event("leftMouseDown", 150, { cmd = true }), false)
    h.advance(1.1)
    t.eq(h.calls, {})
    t.eq(h.event("leftMouseDown", 150), true)
    h.advance(0.1)
    t.eq(h.event("leftMouseUp", 250, { cmd = true }), true)
    h.advance(1.1)
    t.eq(h.calls, {})
  end)
end)

t.test("menubar: stop cancels an outstanding hold", function()
  withGestures(function(h)
    t.eq(h.event("leftMouseDown", 150), true)
    h.advance(0.5)
    h.stop()
    h.advance(2)
    t.eq(h.calls, {})
  end)
end)

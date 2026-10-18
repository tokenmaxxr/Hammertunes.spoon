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
  local timers, calls, tooltips = {}, {}, {}
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
  function menu:setMenu(items) self.items = items end
  function menu:popupMenu() end
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
    mouse = { absolutePosition = function() return mouse end,
      getCurrentScreen = function() return { fullFrame = function()
        return { x = 0, y = 0, w = 1000, h = 1000 }
      end } end },
    drawing = { getTextDrawingSize = function(text, style)
      -- hs.drawing uses a flat style, unlike hs.styledtext's nested font table.
      assert(type(style.font) == "string", "drawing font must be a name")
      assert(style.size == 13, "measure at the tooltip's rendered text size")
      return { w = #text * 7, h = 16 }
    end },
    canvas = { new = function(frame)
      local canvas = { frame = frame }
      function canvas:level() end
      function canvas:behaviorAsLabels() end
      function canvas:appendElements(_, element) self.text = element.text end
      function canvas:show() self.visible = true end
      function canvas:delete() self.visible = false end
      tooltips[#tooltips + 1] = canvas
      return canvas
    end },
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
  local state = { running = true, playing = true, track = "Song", artist = "Artist",
    trackId = "song", durMs = 200000, progress = 0.1 }
  local renderCount = 0
  local lastPill
  local menuContext
  local ok, err = pcall(function()
    subject = t.loadModule("menubar.lua")
    local noop = function() end
    subject.start({
      pill = { new = function() return { update = function(text, opts)
        renderCount = renderCount + 1
        lastPill = { text = text, opts = opts }
      end } end },
      images = { newCache = function()
        return { getPath = noop, getUrl = noop, reset = noop }
      end },
      rightclick = { build = function(ctx) menuContext = ctx; return {} end,
        selectEntries = function() return { owned = {}, play = {} } end },
      api = {
        appName = "Test player",
        getState = function()
          local snapshot = {}
          for k, v in pairs(state) do snapshot[k] = v end
          return snapshot
        end,
        getPlaylists = noop, getRecentlyPlayed = noop, getUri = noop,
        getName = noop, getLiked = noop, refresh = noop, refreshLiked = noop,
        refreshPlaylists = noop, refreshRecentlyPlayed = noop,
        start = noop, stop = noop,
        getPosition = function() return 10 end,
        setPosition = function(value) record("seek", value) end,
        play = function() record("play") end,
        playpause = function() record("playpause") end,
        previous = function() record("previous") end,
        next = function() record("next") end,
      },
    })
    local harness = { calls = calls, stop = subject.stop, state = state,
      renders = function() return renderCount end, timers = timers,
      pill = function() return lastPill end,
      menuContext = function() return menuContext end, tooltips = tooltips,
      move = function(x) mouse = { x = x, y = 10 } end }
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
    function harness.event(kind, x, flags, globalX)
      local location = { x = x or mouse.x, y = 10 }
      mouse = { x = globalX or location.x, y = 10 }
      local eventType = types[kind]
      if watcher.stopped or not watcher.subscriptions[eventType] then return false end
      return watcher.callback({
        getType = function() return eventType end,
        getFlags = function() return flags or {} end,
        location = function() return location end,
      })
    end
    fn(harness)
  end)
  if subject then pcall(subject.stop) end
  hs = savedHs
  if not ok then error(err, 0) end
end

t.test("menubar: hover shows full metadata and survives progress redraws", function()
  withGestures(function(h)
    h.advance(0.5)
    t.eq(#h.tooltips, 0)
    h.advance(0.4)
    t.eq(#h.tooltips, 1)
    local popup = h.tooltips[1]
    t.ok(popup.visible)
    t.ok(popup.text:find("Song", 1, true))
    t.ok(popup.text:find("Artist", 1, true))
    h.state.progress = 0.8
    h.advance(2)
    t.eq(#h.tooltips, 1)
    t.ok(popup.visible)
    h.move(250)
    h.advance(0.2)
    t.eq(popup.visible, false)
    h.move(150)
    h.advance(0.9)
    t.eq(#h.tooltips, 2)
  end)
end)

t.test("menubar: hover refreshes metadata and click suppresses it until exit", function()
  withGestures(function(h)
    h.advance(0.9)
    h.state.track = "A new full title"
    h.advance(1)
    t.eq(h.tooltips[1].visible, false)
    t.ok(h.tooltips[#h.tooltips].text:find("A new full title", 1, true))
    h.event("leftMouseDown", 150)
    t.eq(h.tooltips[#h.tooltips].visible, false)
    h.event("leftMouseUp", 150)
    local count = #h.tooltips
    h.advance(2)
    t.eq(#h.tooltips, count)
    h.move(250)
    h.advance(0.2)
    h.move(150)
    h.advance(0.9)
    t.ok(h.tooltips[#h.tooltips].visible)
    h.stop()
    t.eq(h.tooltips[#h.tooltips].visible, false)
    h.advance(2)
    t.eq(#h.tooltips, count + 1)
  end)
end)

t.test("menubar: reserve pending cover space and hold width only during running track gaps", function()
  withGestures(function(h)
    h.state.artUrl = "https://example.test/cover.jpg"
    h.advance(1)
    t.eq(h.pill().opts.reserveLeadingImage, true)
    t.eq(h.pill().opts.leadingImage, nil)
    h.state.track = nil
    h.advance(1)
    t.eq(h.pill().text, "♪")
    t.eq(h.pill().opts.holdWidth, true)
    h.state.track = "Next"
    h.advance(1)
    t.eq(h.pill().opts.holdWidth, nil)
    h.state.running = false
    h.advance(1)
    t.eq(h.pill().text, "♪")
    t.eq(h.pill().opts.holdWidth, nil)
    t.eq(h.pill().opts.reserveLeadingImage, false)
  end)
end)

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

t.test("menubar: scrub refreshes before release without changing the regular timer", function()
  withGestures(function(h)
    local repeating = {}
    for _, timer in ipairs(h.timers) do
      if timer.repeating then repeating[timer] = timer.repeating end
    end
    h.event("leftMouseDown", 150)
    h.advance(1)
    local before = h.renders()
    h.advance(0.21)
    t.eq(h.renders(), before + 1)
    h.event("leftMouseDragged", 175)
    h.advance(0.21)
    t.eq(h.renders(), before + 2)
    for _, timer in ipairs(h.timers) do
      if timer.repeating then t.eq(timer.repeating, repeating[timer]) end
    end
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

t.test("menubar: repeated scrubs use event positions and flush the final throttled move", function()
  withGestures(function(h)
    for _, startX in ipairs({ 125, 150 }) do
      local first = #h.calls + 1
      h.event("leftMouseDown", startX)
      h.event("leftMouseDragged", 160, nil, startX)
      h.advance(1)
      t.eq(h.calls[first], { "seek", 120 })
      h.advance(0.11)
      h.event("leftMouseDragged", 175, nil, startX)
      t.eq(h.calls[first + 2], { "seek", 150 })
      h.event("leftMouseDragged", 180, nil, startX)
      t.eq(#h.calls, first + 2)
      h.event("leftMouseUp", 185, nil, startX)
      t.eq(h.calls[first + 3], { "seek", 170 })
      h.advance(0.3)
      t.eq(#h.calls, first + 3)
    end
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

t.test("menubar: queued release and stale timer callbacks cannot act after stop", function()
  withGestures(function(h)
    h.event("leftMouseDown", 190)
    h.event("leftMouseUp", 190)
    local count = h.renders()
    h.stop()
    -- Simulate already-dispatched callbacks, even though stop cancelled timers.
    for _, timer in ipairs(h.timers) do timer.callback() end
    t.eq(h.calls, {})
    t.eq(h.renders(), count)
  end)
end)

t.test("menubar: changed track cancels pending play-pause and hold seek", function()
  withGestures(function(h)
    h.event("leftMouseDown", 150)
    h.event("leftMouseUp", 150)
    h.advance(0)
    h.state.trackId = "next"
    h.advance(0.3)
    t.eq(h.calls, {})
    h.advance(0.7)
    h.event("leftMouseDown", 175)
    h.state.trackId = "another"
    h.advance(1)
    t.eq(h.calls, {})
  end)
end)

t.test("menubar: read-only source suppresses transport but permits double-click copy", function()
  withGestures(function(h)
    h.state.canControl, h.state.canSeek = false, false
    h.advance(1)
    h.event("leftMouseDown", 175)
    h.advance(1)
    h.event("leftMouseUp", 175)
    for _ = 1, 2 do
      h.event("leftMouseDown", 150)
      h.event("leftMouseUp", 150)
      h.advance(0.05)
    end
    h.advance(0.5)
    t.eq(h.calls, { { "copy", "Song by Artist" } })
  end)
end)

t.test("menubar: menu seek rejects new media while copy retains displayed metadata", function()
  withGestures(function(h)
    h.event("rightMouseDown", 175)
    h.advance(0)
    local ctx = h.menuContext()
    t.ok(ctx)
    ctx.seek(0.75)
    t.eq(h.calls, { { "seek", 150 } })
    h.state.trackId, h.state.track, h.state.artist = "new", "New song", "New artist"
    h.state.durMs = 100000
    h.advance(1)
    ctx.seek(0.75)
    ctx.copyCurrent()
    t.eq(h.calls, { { "seek", 150 }, { "copy", "Song by Artist" } })
  end)
end)

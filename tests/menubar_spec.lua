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
  local menu = { dismissals = 0 }
  function menu:_frame() return { x = 100, y = 980, w = 100, h = 20 } end
  function menu:setTitle() end
  function menu:setTooltip() end
  function menu:setClickCallback(callback) self.click = callback end
  function menu:setMenu(items) self.items = items end
  function menu:popupMenu()
    if self.onPopup then self.onPopup() end
  end
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
      keyStroke = function(_, key)
        t.eq(key, "escape")
        menu.dismissals = menu.dismissals + 1
      end,
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
  local stateReads = 0
  local lastPill
  local menuContext
  local notify
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
        getState = function(force)
          stateReads = stateReads + 1
          state.forced = force
          local snapshot = {}
          for k, v in pairs(state) do snapshot[k] = v end
          return snapshot
        end,
        getPlaylists = noop, getRecentlyPlayed = noop, getUri = noop,
        getName = function() return state.contextName end,
        getLiked = noop, refresh = noop, refreshLiked = noop,
        refreshPlaylists = noop, refreshRecentlyPlayed = noop,
        start = function(callback) notify = callback end, stop = noop,
        getPosition = function() return 10 end,
        setPosition = function(value) record("seek", value) end,
        play = function() record("play") end,
        playpause = function() record("playpause") end,
        previous = function() record("previous") end,
        next = function() record("next") end,
      },
    })
    local harness = { calls = calls, stop = subject.stop, state = state,
      menu = menu,
      renders = function() return renderCount end, timers = timers,
      reads = function() return stateReads end,
      notify = function(force) notify(force) end,
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

t.test("menubar: pill click dismisses the open menu and performs its transport action", function()
  for _, action in ipairs({ { x = 110, expected = { "seek", 0 } },
    { x = 150, expected = { "playpause" } }, { x = 190, expected = { "next" } } }) do
    withGestures(function(h)
      local opens = 0
      h.menu.onPopup = function()
        opens = opens + 1
        t.eq(h.event("leftMouseDown", action.x), true)
        t.eq(h.menu.dismissals, 1, "consumed pill click must dismiss the native popup")
      end
      h.event("rightMouseDown", 150)
      h.advance(0)
      t.eq(h.menu.items, nil, "popup cleanup detaches the menu")
      h.event("leftMouseUp", action.x)
      h.advance(0.26)
      t.eq(h.calls, { action.expected })
      t.eq(opens, 1, "left click must not reopen the popup")
    end)
  end
end)

t.test("menubar: dismissing a menu preserves hold-to-seek", function()
  withGestures(function(h)
    h.menu.onPopup = function() h.event("leftMouseDown", 175) end
    h.event("rightMouseDown", 150)
    h.advance(0)
    t.eq(h.menu.dismissals, 1)
    h.advance(1)
    t.eq(h.calls, { { "seek", 150 }, { "play" } })
    h.event("leftMouseUp", 175)
    h.advance(0)
    t.eq(#h.calls, 2)
  end)
end)

t.test("menubar: tooltip omits player names but retains playlists and other sources", function()
  for _, player in ipairs({ "Music", "Spotify" }) do
    withGestures(function(h)
      h.state.sourceName, h.state.contextName = player, player
      h.notify()
      h.advance(0.8)
      local text = h.tooltips[#h.tooltips].text
      t.eq(text, "🎵\u{2002}Song\n\n👤\u{2002}Artist")
      h.state.contextName = "Favorites"
      h.notify()
      h.advance(0.1)
      text = h.tooltips[#h.tooltips].text
      t.ok(text:find("📋\u{2002}Favorites", 1, true))
      t.eq(text:find(player, 1, true), nil)
      h.state.sourceName, h.state.contextName = "Safari", nil
      h.notify()
      h.advance(0.1)
      t.ok(h.tooltips[#h.tooltips].text:find("Safari", 1, true))
    end)
  end
end)

t.test("menubar: tooltip retains albums named after players and avoids repeating album context", function()
  withGestures(function(h)
    h.state.album, h.state.sourceName, h.state.contextName = "Music", "Music", "Music"
    h.notify()
    h.advance(0.8)
    local text = h.tooltips[#h.tooltips].text
    t.eq(text, "🎵\u{2002}Song\n\n👤\u{2002}Artist\n\n💿\u{2002}Music")
    h.state.contextName = "Favorites"
    h.notify()
    h.advance(0.1)
    text = h.tooltips[#h.tooltips].text
    t.ok(text:find("💿\u{2002}Music", 1, true))
    t.ok(text:find("📋\u{2002}Favorites", 1, true))
    h.state.album, h.state.contextName = "Spotify", "Spotify"
    h.notify()
    h.advance(0.1)
    text = h.tooltips[#h.tooltips].text
    t.ok(text:find("💿\u{2002}Spotify", 1, true))
    t.eq(text:find("📋", 1, true), nil)
  end)
end)

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

t.test("menubar: actions refresh immediately and recheck settling player state", function()
  withGestures(function(h)
    h.event("rightMouseDown", 175)
    h.advance(0)
    local reads = h.reads()
    h.menuContext().scheduleRender()
    t.eq(h.reads(), reads + 1)
    t.eq(h.state.forced, true)
    h.state.track = "Settled song"
    h.advance(0.19)
    t.eq(h.reads(), reads + 1)
    h.advance(0.02)
    t.eq(h.reads(), reads + 2)
    t.eq(h.state.forced, true)
    t.ok(h.pill().text:find("Settled song", 1, true))
  end)
end)

t.test("menubar: forced completion notifications coalesce the settling read", function()
  withGestures(function(h)
    local reads = h.reads()
    h.notify(true)
    t.eq(h.reads(), reads + 1)
    local firstCheck = h.timers[#h.timers]
    h.advance(0.1)
    h.notify(true)
    t.eq(h.reads(), reads + 2)
    -- A cancelled callback may already have been dispatched by the run loop.
    firstCheck.callback()
    t.eq(h.reads(), reads + 2)
    h.advance(0.11)
    t.eq(h.reads(), reads + 2)
    h.advance(0.1)
    t.eq(h.reads(), reads + 3)
    h.advance(0.3)
    t.eq(h.reads(), reads + 3)
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
    t.eq(h.pill().opts.force, true)
    t.eq(h.state.forced, true)
    h.advance(0.21)
    t.eq(h.renders(), before)
    h.event("leftMouseDragged", 175)
    t.eq(h.renders(), before + 1)
    t.eq(h.pill().opts.force, true)
    t.eq(h.state.forced, true)
    h.advance(0.21)
    t.eq(h.renders(), before + 1)
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

t.test("menubar: scrub draws once per action without reading state on each drag", function()
  withGestures(function(h)
    h.advance(0.5)
    h.event("leftMouseDown", 150)
    h.advance(0.99)
    local reads, renders = h.reads(), h.renders()
    h.advance(0.01)
    t.eq(h.reads(), reads + 1)
    t.eq(h.renders(), renders + 1)
    t.eq(h.pill().opts.progress, 0.5)
    reads, renders = h.reads(), h.renders()
    h.advance(0.11)
    h.event("leftMouseDragged", 175)
    t.eq(h.reads(), reads)
    t.eq(h.renders(), renders + 1)
    t.eq(h.pill().opts.progress, 0.75)
    h.event("leftMouseUp", 180)
    t.eq(h.reads(), reads)
    h.advance(0)
    t.eq(h.reads(), reads + 2)
    t.eq(h.renders(), renders + 2)
    t.eq(h.calls[#h.calls], { "seek", 160 })
  end)
end)

t.test("menubar: release verifies identity before seeking a newly changed track", function()
  withGestures(function(h)
    h.event("leftMouseDown", 150)
    h.advance(1)
    h.state.trackId, h.state.track = "new", "New song"
    local calls, reads, renders = #h.calls, h.reads(), h.renders()
    h.event("leftMouseUp", 180)
    t.eq(h.reads(), reads)
    h.advance(0)
    t.eq(#h.calls, calls)
    t.eq(h.reads(), reads + 1)
    t.eq(h.renders(), renders + 1)
    t.ok(h.pill().text:find("New song", 1, true))
  end)
end)

t.test("menubar: final release seek confirms delayed player progress", function()
  withGestures(function(h)
    h.event("leftMouseDown", 150)
    h.advance(1)
    local reads = h.reads()
    h.event("leftMouseUp", 180)
    h.advance(0)
    t.eq(h.reads(), reads + 2)
    t.eq(h.calls[#h.calls], { "seek", 160 })
    t.eq(h.pill().opts.progress, 0.1)
    h.state.progress = 0.8
    h.advance(0.21)
    t.eq(h.reads(), reads + 3)
    t.eq(h.state.forced, true)
    t.eq(h.pill().opts.progress, 0.8)
  end)
end)

t.test("menubar: a newer press cancels deferred release verification", function()
  withGestures(function(h)
    h.event("leftMouseDown", 150)
    h.advance(1)
    local calls, reads = #h.calls, h.reads()
    h.event("leftMouseUp", 180)
    h.event("leftMouseDown", 160)
    h.advance(0)
    t.eq(h.reads(), reads)
    t.eq(#h.calls, calls)
  end)
end)

t.test("menubar: stopping cancels deferred release verification", function()
  withGestures(function(h)
    h.event("leftMouseDown", 150)
    h.advance(1)
    local calls, reads = #h.calls, h.reads()
    h.event("leftMouseUp", 180)
    h.stop()
    -- Already-dispatched callbacks must also respect the stopped generation.
    for _, timer in ipairs(h.timers) do timer.callback() end
    t.eq(h.reads(), reads)
    t.eq(#h.calls, calls)
  end)
end)

t.test("menubar: periodic scrub verification cancels seeks after a track change", function()
  withGestures(function(h)
    h.event("leftMouseDown", 150)
    h.advance(1)
    local reads = h.reads()
    h.state.trackId, h.state.track = "new", "New song"
    h.advance(1)
    t.eq(h.reads(), reads + 1)
    local calls = #h.calls
    h.event("leftMouseDragged", 175)
    h.event("leftMouseUp", 180)
    t.eq(#h.calls, calls)
    t.eq(h.pill().text:find("New song", 1, true) ~= nil, true)
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
      h.advance(0)
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

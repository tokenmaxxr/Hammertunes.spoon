local t = require("helper")
local rightclick = t.loadModule("rightclick.lua")
local T = rightclick._test

t.test("rightclick: playMode maps click modifiers to playback modes", function()
  t.eq(T.playMode({ cmd = true, alt = true }), "smart")
  t.eq(T.playMode({ cmd = true }), "shuffle")
  t.eq(T.playMode({}), "play")
  t.eq(T.playMode(nil), "play")
end)

-- Title sequence of a built menu, for asserting grouping/gating.
local function titles(items)
  local out = {}
  for _, it in ipairs(items) do out[#out + 1] = it.title end
  return out
end

t.test("rightclick: no api, not running -> open + switch, no dangling separators", function()
  local items = rightclick.build({ switchLabel = "Spotify", switchBackend = function() end })
  t.eq(titles(items), { "Open Player", "-", "Switch to Spotify" })
end)

t.test("rightclick: no api but running -> playback group is just Shuffle", function()
  local items = rightclick.build({ running = true })
  t.eq(titles(items), { "Open Player", "-", "Shuffle: Off" })
end)

-- Minimal fake backend: liked current track, no playlists yet, supports
-- Play Liked Songs.
local function fakeApi()
  return {
    appName = "Spotify",
    getPlaylists = function() return {} end,
    getLiked = function() return true end,
    getRecentlyPlayed = function() return {} end,
    getSmartShuffle = function() return false end,
    playLikedSongs = function() end,
    -- getPollInterval/setPollInterval are REQUIRED interface members; a real
    -- backend always has them, so the fake does too (backs the Refresh interval item).
    getPollInterval = function() return 3 end,
    setPollInterval = function() end,
  }
end

t.test("rightclick: full state -> app / track / playback groups in order", function()
  local items = rightclick.build({
    api = fakeApi(),
    track = "Song",
    artist = "Artist",
    trackId = "id1",
    running = true,
    shuffle = false,
    menuIcon = function() return nil end,
    copyCurrent = function() end,
    openOnYouTube = function() end,
    scheduleRender = function() end,
  })
  t.eq(titles(items), {
    "Open Spotify",
    "-", T.PREV_LABEL, T.playPauseLabel(false), T.NEXT_LABEL,
    "-", "Unlike", "Copy \u{201C}Song by Artist\u{201D}", "Open on YouTube",
    "-", "Shuffle: Off", "Play Liked Songs",
    "-", "Refresh interval",
  })
end)

t.test("rightclick: not running -> only Open / Switch, no playback or account items", function()
  -- Backend still has playlists + Play Liked Songs cached and supports re-auth,
  -- but the player is closed: the menu must collapse to just Open / Switch.
  local api = fakeApi()
  api.getPlaylists = function() return { { id = "p1", name = "Chill", uri = "u1" } } end
  api.supportsReauth = true
  api.authenticate = function() end
  local items = rightclick.build({
    api = api,
    running = false,
    menuIcon = function() return nil end,
    scheduleRender = function() end,
    switchLabel = "Apple Music",
    switchBackend = function() end,
  })
  t.eq(titles(items), { "Open Spotify", "-", "Switch to Apple Music" })
end)

t.test("rightclick: supportsSourceToggle -> checkable 'Show Other Sources' after Shuffle", function()
  local api = fakeApi()
  api.supportsSourceToggle = true
  local shown = false
  api.getShowOtherSources = function() return shown end
  api.setShowOtherSources = function(v) shown = v end
  local items = rightclick.build({
    api = api, running = true, menuIcon = function() return nil end, scheduleRender = function() end,
  })
  -- Find the toggle and confirm it sits in the playback group, reflects state,
  -- and flips on click.
  local toggle
  for _, it in ipairs(items) do if it.title == "Show Other Sources" then toggle = it end end
  t.ok(toggle, "Show Other Sources item present when supportsSourceToggle")
  t.eq(toggle.checked, false)
  toggle.fn()
  t.eq(shown, true)
end)

t.test("rightclick: no source toggle when backend lacks the capability", function()
  local items = rightclick.build({
    api = fakeApi(), running = true, menuIcon = function() return nil end, scheduleRender = function() end,
  })
  for _, it in ipairs(items) do t.ok(it.title ~= "Show Other Sources") end
end)

t.test("rightclick: running + supportsReauth -> Re-authenticate above Switch", function()
  local api = fakeApi()
  api.supportsReauth = true
  api.authenticate = function() end
  local items = rightclick.build({
    api = api,
    running = true,
    menuIcon = function() return nil end,
    scheduleRender = function() end,
    switchLabel = "Apple Music",
    switchBackend = function() end,
  })
  t.eq(titles(items), {
    "Open Spotify",
    "-", T.PREV_LABEL, T.playPauseLabel(false), T.NEXT_LABEL,
    "-", "Shuffle: Off", "Play Liked Songs",
    "-", "Re-authenticate", "Refresh interval", "Switch to Apple Music",
  })
end)

t.test("rightclick: no track -> track group (and its separator) is absent", function()
  local items = rightclick.build({
    api = fakeApi(),
    running = true,
    shuffle = true,
    menuIcon = function() return nil end,
    scheduleRender = function() end,
  })
  t.eq(titles(items), {
    "Open Spotify",
    "-", T.PREV_LABEL, T.playPauseLabel(false), T.NEXT_LABEL,
    "-", "Shuffle: On", "Play Liked Songs",
    "-", "Refresh interval",
  })
end)

t.test("rightclick: transport items carry pill click-zone hints (left/center/right)", function()
  t.ok(T.PREV_LABEL:find("left", 1, true), "Previous hints the pill's left")
  t.ok(T.playPauseLabel(true):find("center", 1, true), "Play/Pause hints the pill's center")
  t.ok(T.NEXT_LABEL:find("right", 1, true), "Next hints the pill's right")
end)

t.test("rightclick: transport group - Pause label while playing, items drive the api", function()
  local calls = {}
  local api = fakeApi()
  api.previous = function() calls[#calls + 1] = "previous" end
  api.playpause = function() calls[#calls + 1] = "playpause" end
  api.next = function() calls[#calls + 1] = "next" end
  local items = rightclick.build({
    api = api, running = true, playing = true,
    menuIcon = function() return nil end, scheduleRender = function() end,
  })
  local byTitle = {}
  for _, it in ipairs(items) do byTitle[it.title] = it end
  t.ok(byTitle[T.PREV_LABEL] and byTitle[T.NEXT_LABEL], "Previous/Next present")
  t.ok(byTitle[T.playPauseLabel(true)] and not byTitle[T.playPauseLabel(false)],
    "shows Pause while playing")
  byTitle[T.PREV_LABEL].fn(); byTitle[T.playPauseLabel(true)].fn(); byTitle[T.NEXT_LABEL].fn()
  t.eq(calls, { "previous", "playpause", "next" })
end)

t.test("rightclick: fmtTime renders M:SS, rounding and clamping", function()
  t.eq(T.fmtTime(0), "0:00")
  t.eq(T.fmtTime(83), "1:23")
  t.eq(T.fmtTime(83.4), "1:23")
  t.eq(T.fmtTime(-5), "0:00")
  t.eq(T.fmtTime(600), "10:00")
end)

t.test("rightclick: right-click position adds a Seek-to-time item that jumps there", function()
  local seeked
  local api = fakeApi()
  local items = rightclick.build({
    api = api, running = true, playing = true,
    -- right-clicked halfway along a 200s track -> 100s == 1:40
    seekRatio = 0.5, durMs = 200000,
    seek = function(ratio) seeked = ratio end,
    menuIcon = function() return nil end, scheduleRender = function() end,
  })
  local seek
  for _, it in ipairs(items) do if it.title:find("Seek to", 1, true) then seek = it end end
  t.ok(seek, "Seek-to item present for a right-click position on a timed track")
  t.ok(seek.title:find("1:40", 1, true), "shows the target time")
  t.ok(seek.title:find("long%-press"), "hints the long-press scrub gesture")
  seek.fn()
  t.eq(seeked, 0.5, "selecting it seeks to the clicked ratio")
end)

t.test("rightclick: no Seek-to item without a right-click position or known duration", function()
  -- No seekRatio (menu opened some other way): no seek item.
  local a = rightclick.build({
    api = fakeApi(), running = true, durMs = 200000, seek = function() end,
    menuIcon = function() return nil end, scheduleRender = function() end,
  })
  for _, it in ipairs(a) do t.ok(not it.title:find("Seek to", 1, true)) end
  -- seekRatio present but duration unknown (durMs 0): still no seek item.
  local b = rightclick.build({
    api = fakeApi(), running = true, seekRatio = 0.5, durMs = 0, seek = function() end,
    menuIcon = function() return nil end, scheduleRender = function() end,
  })
  for _, it in ipairs(b) do t.ok(not it.title:find("Seek to", 1, true)) end
end)

t.test("rightclick: transport group hidden when not running", function()
  local items = rightclick.build({
    api = fakeApi(), running = false, menuIcon = function() return nil end, scheduleRender = function() end,
  })
  for _, it in ipairs(items) do
    t.ok(it.title ~= T.PREV_LABEL and it.title ~= T.NEXT_LABEL, "no transport items on a closed player")
  end
end)

t.test("rightclick: Refresh interval submenu checks current, flags short, persists choice", function()
  local interval = 3
  local api = fakeApi()
  api.getPollInterval = function() return interval end
  api.setPollInterval = function(s) interval = s end
  local items = rightclick.build({
    api = api, running = true, menuIcon = function() return nil end, scheduleRender = function() end,
  })
  local picker
  for _, it in ipairs(items) do if it.title == "Refresh interval" then picker = it end end
  t.ok(picker and picker.menu, "Refresh interval submenu present for both backends")
  -- The 3s option is the default, currently checked; 1s/2s carry a battery warning.
  local checked, warned = nil, {}
  for _, opt in ipairs(picker.menu) do
    if opt.checked then checked = opt.title end
    if opt.title:find("more battery", 1, true) then warned[#warned + 1] = opt.title end
  end
  t.ok(checked and checked:find("3s", 1, true), "current interval (3s) is checked")
  t.eq(#warned, 2, "the two sub-default options (1s, 2s) are flagged")
  -- Selecting 5s persists via setPollInterval.
  for _, opt in ipairs(picker.menu) do
    if opt.title:find("5s", 1, true) then opt.fn() end
  end
  t.eq(interval, 5)
end)

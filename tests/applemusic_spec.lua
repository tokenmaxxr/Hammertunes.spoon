local t = require("helper")
local am = t.loadModule("backends/applemusic.lua")
local T = am._test

local MAC_EPOCH = 978307200  -- Mac absolute time -> Unix epoch offset

t.test("applemusic: calcProgress is 0 for non-positive duration", function()
  t.eq(T.calcProgress(50, 0), 0)
  t.eq(T.calcProgress(50, -1), 0)
end)

t.test("applemusic: calcProgress divides position by duration (ms)", function()
  t.eq(T.calcProgress(30, 60000), 0.5)
end)

t.test("applemusic: calcProgress clamps to [0,1]", function()
  t.eq(T.calcProgress(-5, 10000), 0)
  t.eq(T.calcProgress(9999, 10000), 1)
end)

t.test("applemusic: mrProgress with no timestamp uses raw elapsed", function()
  hs.timer._now = 0
  local durMs, progress = T.mrProgress({ duration = 100, elapsed = 25, rate = 1 })
  t.eq(durMs, 100000)
  t.eq(progress, 0.25)
end)

t.test("applemusic: mrProgress compensates for small drift since snapshot", function()
  hs.timer._now = MAC_EPOCH + 5         -- 5s after the snapshot
  local _, progress = T.mrProgress({ duration = 200, elapsed = 10, rate = 1, timestamp = 0 })
  t.eq(progress, 0.075)                 -- (10 + 5*1) / 200
end)

t.test("applemusic: mrProgress ignores implausibly large drift (>= 60s)", function()
  hs.timer._now = MAC_EPOCH + 120
  local _, progress = T.mrProgress({ duration = 200, elapsed = 10, rate = 1, timestamp = 0 })
  t.eq(progress, 0.05)                  -- raw 10/200, no compensation
end)

t.test("applemusic: mrProgress does not compensate when paused (rate 0)", function()
  hs.timer._now = MAC_EPOCH + 5
  local _, progress = T.mrProgress({ duration = 200, elapsed = 10, rate = 0, timestamp = 0 })
  t.eq(progress, 0.05)
end)

t.test("applemusic: mrState builds a streaming state (no trackId/art)", function()
  hs.timer._now = 0
  local s = T.mrState({ title = "T", artist = "A", duration = 100, elapsed = 50, rate = 1 }, true)
  t.eq(s, {
    running = true, playing = true, track = "T", artist = "A",
    progress = 0.5, durMs = 100000, artUrl = nil, artPath = nil,
    trackId = nil, shuffle = true,
  })
end)

t.test("applemusic: mrState maps empty title/artist to nil and rate 0 to paused", function()
  local s = T.mrState({ title = "", artist = "", duration = 0, elapsed = 0, rate = 0 }, false)
  t.eq(s.track, nil)
  t.eq(s.artist, nil)
  t.eq(s.playing, false)
  t.eq(s.shuffle, false)
end)

t.test("applemusic: runningState is a blank running shape carrying playing/shuffle", function()
  t.eq(T.runningState(true, true), {
    running = true, playing = true, track = nil, artist = nil,
    progress = 0, durMs = 0, artUrl = nil, artPath = nil,
    trackId = nil, shuffle = true,
  })
end)

t.test("applemusic: asQuote escapes double quotes for AppleScript literals", function()
  t.eq(T.asQuote('She said "hi"'), 'She said \\"hi\\"')
end)

t.test("applemusic: asQuote escapes backslashes before quotes", function()
  t.eq(T.asQuote("AC\\DC"), "AC\\\\DC")
end)

t.test("applemusic: asQuote leaves plain names untouched", function()
  t.eq(T.asQuote("Chill Mix"), "Chill Mix")
end)

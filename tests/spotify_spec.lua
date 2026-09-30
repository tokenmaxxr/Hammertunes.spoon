local t = require("helper")
local spotify = t.loadModule("backends/spotify.lua")
local parse = spotify._test.parseSpotifyState
local parseRetryAfter = spotify._test.parseRetryAfter
local singleFlight = spotify._test.singleFlight

-- Build a SPOTIFY_QUERY result line from its 8 tab-separated fields.
local function line(state, track, artist, pos, dur, art, uri, shuffle)
  return table.concat({ state, track, artist, pos, dur, art, uri, shuffle }, "\t")
end

t.test("spotify: full playing track parses every field", function()
  local s = parse(line("playing", "Song", "Artist", "30", "60000",
    "http://art.png", "spotify:track:abc123", "true"))
  t.eq(s, {
    running = true, playing = true, track = "Song", artist = "Artist",
    progress = 0.5, durMs = 60000, artUrl = "http://art.png",
    artPath = nil, trackId = "abc123", shuffle = true,
  })
end)

t.test("spotify: paused error-line (blank track) yields nils, not empty strings", function()
  local s = parse(line("paused", "", "", "0", "0", "", "", "false"))
  t.eq(s.running, true)
  t.eq(s.playing, false)
  t.eq(s.track, nil)
  t.eq(s.artist, nil)
  t.eq(s.artUrl, nil)
  t.eq(s.trackId, nil)
  t.eq(s.progress, 0)
  t.eq(s.durMs, 0)
  t.eq(s.shuffle, false)
end)

t.test("spotify: local files have no real track id (not likeable)", function()
  local s = parse(line("playing", "Local", "Me", "5", "100000",
    "", "spotify:local:Me:Album:Local:100", "false"))
  t.eq(s.trackId, nil)
end)

t.test("spotify: real track uri reduces to the bare id", function()
  local s = parse(line("playing", "T", "A", "0", "1000", "", "spotify:track:XYZ", "false"))
  t.eq(s.trackId, "XYZ")
end)

t.test("spotify: progress clamps to 1 when position exceeds duration", function()
  local s = parse(line("playing", "T", "A", "999", "10000", "", "spotify:track:x", "true"))
  t.eq(s.progress, 1)
end)

t.test("spotify: names containing tabs-safe pipes survive", function()
  local s = parse(line("playing", "A|B", "C|D", "0", "1000", "", "spotify:track:z", "false"))
  t.eq(s.track, "A|B")
  t.eq(s.artist, "C|D")
end)

t.test("spotify: retry-after parses lowercase header", function()
  t.eq(parseRetryAfter({ ["retry-after"] = "120" }), 120)
end)

t.test("spotify: retry-after parses canonical-case header", function()
  t.eq(parseRetryAfter({ ["Retry-After"] = "60" }), 60)
end)

t.test("spotify: retry-after defaults to an hour when missing or garbage", function()
  t.eq(parseRetryAfter(nil), 3600)
  t.eq(parseRetryAfter({}), 3600)
  t.eq(parseRetryAfter({ ["Retry-After"] = "soon" }), 3600)
end)

t.test("spotify: singleFlight - only the first caller starts the work", function()
  local sf = singleFlight()
  t.eq(sf.join(function() end), true)
  t.eq(sf.join(function() end), false)
  t.eq(sf.join(function() end), false)
end)

t.test("spotify: singleFlight - flush delivers the result to every waiter in order", function()
  local sf = singleFlight()
  local got = {}
  sf.join(function(tok, err) got[#got + 1] = { 1, tok, err } end)
  sf.join(function(tok, err) got[#got + 1] = { 2, tok, err } end)
  sf.flush("TOKEN", nil)
  t.eq(got, { { 1, "TOKEN" }, { 2, "TOKEN" } })
end)

t.test("spotify: singleFlight - a new flight can start after flush", function()
  local sf = singleFlight()
  sf.join(function() end)
  sf.flush(nil, "auth failed")
  t.eq(sf.join(function() end), true, "flight should reset after flush")
end)

t.test("spotify: singleFlight - waiter re-joining during flush starts a fresh flight", function()
  local sf = singleFlight()
  local rejoined
  sf.join(function() rejoined = sf.join(function() end) end)
  sf.flush("TOKEN")
  t.eq(rejoined, true)
end)

-- ---------------------------------------------------------------------------
-- getState boundary tests: drive module.getState() through the osascript stub.
-- Each test installs its own _applescript function and restores the default
-- (fail-closed) stub afterwards so state does not leak between tests.
-- ---------------------------------------------------------------------------

-- Sentinel restores the default fail-closed stub after each test. Marks Spotify
-- as running so getState() passes its applicationsForBundleID gate, and advances
-- the clock past POLL_INTERVAL_SEC so getState() does a real read instead of
-- serving a throttled snapshot left over from a prior test.
local function withApplescript(fn, body)
  local prev = hs.osascript._applescript
  hs.osascript._applescript = fn
  hs.application._running["Spotify"] = true
  hs.timer._now = hs.timer._now + 1000
  local ok, err = pcall(body)
  hs.application._running["Spotify"] = nil
  hs.osascript._applescript = prev
  if not ok then error(err, 2) end
end

t.test("spotify: interpolate advances a playing snapshot, leaving the original", function()
  local snap = { running = true, playing = true, durMs = 100000, progress = 0.1, track = "x" }
  local out = spotify._test.interpolate(snap, 5) -- +5s of a 100s track -> 15/100
  t.ok(math.abs(out.progress - 0.15) < 1e-9, "progress advanced by 5s")
  t.eq(snap.progress, 0.1) -- cached snapshot untouched
end)

t.test("spotify: interpolate leaves paused / zero-duration snapshots unchanged", function()
  local paused = { playing = false, durMs = 100000, progress = 0.2 }
  t.eq(spotify._test.interpolate(paused, 10), paused)
  local nodur = { playing = true, durMs = 0, progress = 0 }
  t.eq(spotify._test.interpolate(nodur, 10), nodur)
end)

t.test("spotify: interpolate clamps at the end of the track", function()
  local snap = { playing = true, durMs = 10000, progress = 0.95 } -- 9.5s of 10s
  t.eq(spotify._test.interpolate(snap, 5).progress, 1) -- 14.5/10 -> clamped
end)

t.test("spotify: getState throttles the osascript read and interpolates between", function()
  hs.application._running["Spotify"] = true
  local prev = hs.osascript._applescript
  local calls = 0
  hs.osascript._applescript = function(_)
    calls = calls + 1
    -- playing, pos=10s, dur=100000ms (100s) -> progress 0.1
    return true, table.concat(
      { "playing", "T", "A", "10", "100000", "", "spotify:track:X", "false" }, "\t")
  end
  hs.timer._now = 1000
  local s1 = spotify.getState()          -- real read at t=1000
  t.eq(calls, 1)
  t.ok(math.abs(s1.progress - 0.1) < 1e-9, "fresh read is not interpolated")
  hs.timer._now = 1002                    -- +2s, within POLL_INTERVAL_SEC (3)
  local s2 = spotify.getState()          -- served from snapshot, no new read
  t.eq(calls, 1)
  t.ok(math.abs(s2.progress - 0.12) < 1e-9, "progress interpolated +2s")
  hs.timer._now = 1004                    -- +4s from the read, past the interval
  spotify.getState()                      -- real read again
  t.eq(calls, 2)
  hs.osascript._applescript = prev
  hs.application._running["Spotify"] = nil
end)

t.test("spotify: getState - Spotify not running skips osascript, returns not-running", function()
  hs.application._running["Spotify"] = nil
  local called = false
  local prev = hs.osascript._applescript
  hs.osascript._applescript = function(_) called = true; return true, "" end
  local s = spotify.getState()
  hs.osascript._applescript = prev
  t.eq(s, { running = false })
  t.ok(not called, "osascript must not run when Spotify is closed")
end)

t.test("spotify: getState - osascript fails outright returns not-running", function()
  -- Simulates the case where hs.osascript.applescript itself returns failure
  -- (e.g. osascript not found, permission denied, or JXA crash).
  withApplescript(
    function(_) return false, nil end,
    function()
      local s = spotify.getState()
      t.eq(s, { running = false })
    end
  )
end)

t.test("spotify: getState - osascript ok but empty result returns not-running", function()
  -- The AppleScript returns "" when Spotify is not running (the else branch of
  -- SPOTIFY_QUERY). getState must treat ok+empty the same as outright failure.
  withApplescript(
    function(_) return true, "" end,
    function()
      local s = spotify.getState()
      t.eq(s, { running = false })
    end
  )
end)

t.test("spotify: getState - valid now-playing row returns fully populated state", function()
  -- Build the row matching SPOTIFY_QUERY's 8-field tab-separated output:
  --   state, track, artist, player_position(sec), duration(ms),
  --   artwork_url, track_id_uri, shuffle
  -- pos=30s, dur=60000ms -> progress = 30/(60000/1000) = 0.5
  local row = table.concat({
    "playing",
    "Test Track",
    "Test Artist",
    "30",
    "60000",
    "https://i.scdn.co/image/abc",
    "spotify:track:TESTID",
    "true",
  }, "\t")
  withApplescript(
    function(_) return true, row end,
    function()
      local s = spotify.getState()
      t.eq(s, {
        running   = true,
        playing   = true,
        track     = "Test Track",
        artist    = "Test Artist",
        progress  = 0.5,
        durMs     = 60000,
        artUrl    = "https://i.scdn.co/image/abc",
        artPath   = nil,
        trackId   = "TESTID",
        shuffle   = true,
      })
    end
  )
end)

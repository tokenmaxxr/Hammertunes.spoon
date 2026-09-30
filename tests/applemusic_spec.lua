local t = require("helper")
local am = t.loadModule("backends/applemusic.lua")
local T = am._test

local MAC_EPOCH = 978307200  -- Mac absolute time -> Unix epoch offset

-- ---------------------------------------------------------------------------
-- calcProgress
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- mrProgress
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- mrState - 3-arg signature: mrState(mrData, shuffle, artUrl)
-- artPath is always nil for streaming tracks (no local file export)
-- ---------------------------------------------------------------------------

t.test("applemusic: mrState builds a streaming state (no trackId/artPath)", function()
  hs.timer._now = 0
  local s = T.mrState({ title = "T", artist = "A", duration = 100, elapsed = 50, rate = 1 }, true, nil)
  t.eq(s, {
    running = true, playing = true, track = "T", artist = "A",
    progress = 0.5, durMs = 100000, artUrl = nil, artPath = nil,
    trackId = nil, shuffle = true,
    canControl = false, canSeek = false, canLike = false, canAddToPlaylist = false,
  })
end)

t.test("applemusic: mrState threads artUrl through; artPath is always nil", function()
  hs.timer._now = 0
  local base = { title = "T", artist = "A", duration = 100, elapsed = 50, rate = 1 }
  local s = T.mrState(base, false, "https://art/x.jpg")
  t.eq(s.artUrl, "https://art/x.jpg")
  t.eq(s.artPath, nil)
  t.eq(s.trackId, nil)
end)

t.test("applemusic: mrState with nil artUrl sets artUrl=nil, artPath=nil", function()
  hs.timer._now = 0
  local base = { title = "T", artist = "A", duration = 100, elapsed = 50, rate = 1 }
  local s = T.mrState(base, false, nil)
  t.eq(s.artUrl, nil)
  t.eq(s.artPath, nil)
end)

t.test("applemusic: mrState maps empty title/artist to nil and rate 0 to paused", function()
  local s = T.mrState({ title = "", artist = "", duration = 0, elapsed = 0, rate = 0 }, false, nil)
  t.eq(s.track, nil)
  t.eq(s.artist, nil)
  t.eq(s.playing, false)
  t.eq(s.shuffle, false)
end)

t.test("applemusic: mrState preserves artist and exposes foreign source separately", function()
  hs.timer._now = 0
  local base = { title = "T", artist = "A", duration = 100, elapsed = 0, rate = 1 }
  t.eq(T.mrState(base, false, nil, "Safari").artist, "A")
  t.eq(T.mrState(base, false, nil, "Safari").sourceName, "Safari")
  -- No artist: the label stands alone so the source is still clear.
  local noArtist = { title = "T", artist = "", duration = 100, elapsed = 0, rate = 1 }
  t.eq(T.mrState(noArtist, false, nil, "Safari").artist, nil)
end)

-- ---------------------------------------------------------------------------
-- mrSourceLabel - which Now Playing sources may drive the Apple Music pill
-- ---------------------------------------------------------------------------

t.test("applemusic: mrSourceLabel always accepts Apple Music with no label", function()
  T.resetArtState()  -- showOtherSources = false
  local ok, label = T.mrSourceLabel({ bundleId = "com.apple.Music", appName = "Music" })
  t.eq(ok, true)
  t.eq(label, nil)
end)

t.test("applemusic: mrSourceLabel always rejects Spotify (own backend)", function()
  T.resetArtState()
  am.setShowOtherSources(true)  -- even with the toggle on
  local ok = T.mrSourceLabel({ bundleId = "com.spotify.client", appName = "Spotify" })
  t.eq(ok, false)
  am.setShowOtherSources(false)
end)

t.test("applemusic: mrSourceLabel hides other apps by default, shows+labels when opted in", function()
  T.resetArtState()
  local ok = T.mrSourceLabel({ bundleId = "com.apple.Safari", appName = "Safari" })
  t.eq(ok, false)  -- default off
  am.setShowOtherSources(true)
  local ok2, label = T.mrSourceLabel({ bundleId = "com.apple.Safari", appName = "Safari" })
  t.eq(ok2, true)
  t.eq(label, "Safari")
  am.setShowOtherSources(false)
end)

t.test("applemusic: mrSourceLabel fails open for an unknown (missing) source", function()
  T.resetArtState()
  local ok, label = T.mrSourceLabel({ title = "T" })  -- no bundleId
  t.eq(ok, true)
  t.eq(label, nil)
end)

-- ---------------------------------------------------------------------------
-- runningState
-- ---------------------------------------------------------------------------

t.test("applemusic: runningState is a blank running shape carrying playing/shuffle", function()
  t.eq(T.runningState(true, true), {
    running = true, playing = true, track = nil, artist = nil,
    progress = 0, durMs = 0, artUrl = nil, artPath = nil,
    trackId = nil, shuffle = true,
    sourceBundleId = "com.apple.Music", sourceName = "Music",
    canControl = true, canSeek = false, canLike = false, canAddToPlaylist = false,
  })
end)

-- ---------------------------------------------------------------------------
-- asQuote
-- ---------------------------------------------------------------------------

t.test("applemusic: asQuote escapes double quotes for AppleScript literals", function()
  t.eq(T.asQuote('She said "hi"'), 'She said \\"hi\\"')
end)

t.test("applemusic: asQuote escapes backslashes before quotes", function()
  t.eq(T.asQuote("AC\\DC"), "AC\\\\DC")
end)

t.test("applemusic: asQuote leaves plain names untouched", function()
  t.eq(T.asQuote("Chill Mix"), "Chill Mix")
end)

-- ---------------------------------------------------------------------------
-- mrArtUrl - streaming cover URL via MediaRemote artworkId
-- ---------------------------------------------------------------------------

t.test("applemusic: mrArtUrl returns artworkId when it is an https URL", function()
  local url = "https://is1-ssl.mzstatic.com/image/thumb/x/800x800bb.jpg"
  t.eq(T.mrArtUrl({ artworkId = url }), url)
end)

t.test("applemusic: mrArtUrl accepts http as well as https", function()
  t.eq(T.mrArtUrl({ artworkId = "http://example.com/a.jpg" }), "http://example.com/a.jpg")
end)

t.test("applemusic: mrArtUrl returns nil for an opaque (non-URL) identifier", function()
  t.eq(T.mrArtUrl({ artworkId = "ABC123" }), nil)
end)

t.test("applemusic: mrArtUrl returns nil when artworkId is absent", function()
  t.eq(T.mrArtUrl({ title = "T" }), nil)
  t.eq(T.mrArtUrl(nil), nil)
end)

-- ---------------------------------------------------------------------------
-- parseMrOutput - pure JSON->table parser for MediaRemote JXA stdout
-- ---------------------------------------------------------------------------

t.test("applemusic: parseMrOutput returns a table for valid JSON", function()
  local out = T.parseMrOutput(
    '{"title":"Song","artist":"Band","duration":180,"elapsed":30,"rate":1,"artworkId":"https://example.com/art.jpg"}'
  )
  t.ok(out ~= nil, "expected non-nil table")
  t.eq(out.title, "Song")
  t.eq(out.artist, "Band")
  t.eq(out.duration, 180)
  t.eq(out.rate, 1)
  t.eq(out.artworkId, "https://example.com/art.jpg")
end)

t.test("applemusic: parseMrOutput returns nil for empty string", function()
  t.eq(T.parseMrOutput(""), nil)
end)

t.test("applemusic: parseMrOutput returns nil for non-string input", function()
  t.eq(T.parseMrOutput(nil), nil)
  t.eq(T.parseMrOutput(42), nil)
end)

t.test("applemusic: parseMrOutput returns nil for {\"error\":\"no nowPlayingInfo\"}", function()
  t.eq(T.parseMrOutput('{"error":"no nowPlayingInfo"}'), nil)
end)

t.test("applemusic: parseMrOutput returns nil for other error payloads", function()
  t.eq(T.parseMrOutput('{"error":"bundle load failed"}'), nil)
  t.eq(T.parseMrOutput('{"error":"MRNowPlayingRequest unavailable"}'), nil)
end)

t.test("applemusic: parseMrOutput passes through a fieldless object (no .error)", function()
  -- "{}" decodes to an empty table with no .error key, so parseMrOutput returns
  -- it as-is. Downstream (mrArtUrl / mrState) tolerates the missing fields.
  local out = T.parseMrOutput("{}")
  t.eq(out, {})
end)

-- ---------------------------------------------------------------------------
-- getState integration helpers
-- ---------------------------------------------------------------------------

-- Plant a fake image at the per-track art path for a numeric trackId, run
-- fn(path), then tear down the stub. exportArt uses artPathFor(trackId) which
-- expands to HOME/.hammerspoon/.hammertunes-applemusic-art-<trackId>.png.
local HOME = os.getenv("HOME")
local function withFakeArt(trackId, fn)
  local path = HOME .. "/.hammerspoon/.hammertunes-applemusic-art-" .. tostring(trackId) .. ".png"
  hs.image._files[path] = { _fake = true }
  fn(path)
  hs.image._files[path] = nil
end

-- Reset all integration stubs to safe defaults.
local function resetStubs()
  hs.application._running["Music"] = nil
  hs.osascript._applescript = function(_) return false, nil end
  hs._exec = function(_) return "" end
end

-- Unlike the default synchronous task fake, this fixture lets completions land
-- after stop, restart, transport actions, and a newer request.
local function withDelayedTasks(fn)
  local oldTask, oldAfter, oldItunes = hs.task.new, hs.timer.doAfter, hs.itunes
  local tasks, timers, actions = {}, {}, {}
  hs.task.new = function(_, callback)
    local task = { callback = callback }
    function task:start() return self end
    function task:terminate() self.terminated = true end
    tasks[#tasks + 1] = task
    return task
  end
  hs.timer.doAfter = function(_, callback)
    local timer = { callback = callback }
    function timer:stop() self.stopped = true end
    timers[#timers + 1] = timer
    return timer
  end
  hs.itunes = setmetatable({}, { __index = function(_, action)
    return function() actions[#actions + 1] = action end
  end })
  T.resetArtState()
  am.setPollInterval(3)
  hs.timer._now = 1000
  hs.application._running.Music = true
  hs.osascript._applescript = function(script)
    if script:find("return shuffle enabled", 1, true) then return true, "false" end
    return true, "FALLBACK\tplaying\tfalse\t-1728"
  end
  hs._exec = function()
    return '{"title":"Song","artist":"A","duration":100,"elapsed":10,"rate":1,"bundleId":"com.apple.Music"}'
  end
  local ok, err = pcall(fn, tasks, timers, actions)
  am.stop()
  hs.task.new, hs.timer.doAfter, hs.itunes = oldTask, oldAfter, oldItunes
  resetStubs()
  if not ok then error(err, 0) end
end

t.test("applemusic: delayed MediaRemote reads obey interval and cancel stale transport results", function()
  withDelayedTasks(function(tasks, _, actions)
    am.getState()
    hs.timer._now = 1002
    am.getState()
    t.eq(#tasks, 0)
    hs.timer._now = 1003
    am.getState()
    t.eq(#tasks, 1)
    am.next()
    t.eq(actions, { "next" })
    t.eq(tasks[1].terminated, true)
    am.getState()
    t.eq(#tasks, 2)
    tasks[2].callback(0, '{"title":"New","bundleId":"com.apple.Music"}')
    tasks[1].callback(0, '{"title":"Old","bundleId":"com.apple.Music"}')
    t.eq(T.mrSnapshot().title, "New")
  end)
end)

t.test("applemusic: stop cancels warmup and subprocess; old callbacks cannot replace restart state", function()
  withDelayedTasks(function(tasks, timers)
    am.start(function() end)
    am.getState()
    hs.timer._now = 1003
    am.getState()
    am.stop()
    t.eq(tasks[1].terminated, true)
    t.eq(timers[1].stopped, true)
    am.start(function() end)
    am.getState()
    timers[1].callback()
    t.eq(am.getPlaylists(), nil)
    tasks[1].callback(0, '{"title":"Stale"}')
    t.eq(T.mrSnapshot().title, "Song")
  end)
end)

t.test("applemusic: same-title artist change re-probes library path", function()
  withDelayedTasks(function(tasks)
    am.getState()
    hs.timer._now = 1003
    am.getState()
    tasks[1].callback(0, '{"title":"Song","artist":"B","bundleId":"com.apple.Music"}')
    t.eq(am.getState().artist, "B")
    local probes = 0
    hs.osascript._applescript = function()
      probes = probes + 1
      return true, "FALLBACK\tplaying\tfalse\t-1728"
    end
    am.getState()
    t.eq(probes, 1)
  end)
end)

t.test("applemusic: foreign and unknown sources cannot send Music transport", function()
  withDelayedTasks(function(_, _, actions)
    am.setShowOtherSources(true)
    hs._exec = function()
      return '{"title":"Browser song","artist":"Artist","bundleId":"com.apple.Safari","appName":"Safari"}'
    end
    local state = am.getState()
    t.eq(state.sourceBundleId, "com.apple.Safari")
    t.eq(state.sourceName, "Safari")
    t.eq(state.artist, "Artist")
    t.eq(state.canControl, false)
    t.eq(state.canSeek, false)
    am.next(); am.playpause(); am.setPosition(4)
    t.eq(actions, {})
    T.resetArtState()
    hs._exec = function() return '{"title":"Unknown"}' end
    t.eq(am.getState().canControl, false)
    am.next()
    t.eq(actions, {})
  end)
end)

t.test("applemusic: hidden foreign sources retain displayed Music transport", function()
  withDelayedTasks(function(_, _, actions)
    for _, bundle in ipairs({ "com.apple.Safari", "com.spotify.client" }) do
      T.resetArtState()
      hs._exec = function()
        return '{"title":"Hidden song","bundleId":"' .. bundle .. '"}'
      end
      local state = am.getState()
      t.eq(state.track, nil)
      t.eq(state.sourceBundleId, "com.apple.Music")
      t.eq(state.canControl, true)
      am.playpause()
    end
    t.eq(actions, { "playpause", "playpause" })
  end)
end)

t.test("applemusic: captured library and playlist IDs drive menu actions", function()
  T.resetArtState()
  local scripts = {}
  hs.osascript._applescript = function(script)
    scripts[#scripts + 1] = script
    return true, "OK"
  end
  am.like(123)
  am.unlike(456)
  local added
  am.addToPlaylist("PLAYLIST2", 789, function(ok) added = ok end)
  am.playContext("applemusic:playlist:PLAYLIST2", "shuffle")
  t.ok(scripts[1]:find("database ID is 123", 1, true))
  t.ok(scripts[2]:find("database ID is 456", 1, true))
  t.ok(scripts[3]:find("database ID is 789", 1, true))
  t.ok(scripts[3]:find('persistent ID is "PLAYLIST2"', 1, true))
  t.ok(scripts[4]:find('persistent ID is "PLAYLIST2"', 1, true))
  t.eq(added, true)
  for _, script in ipairs(scripts) do t.eq(script:find("current track", 1, true), nil) end
  resetStubs()
end)

t.test("applemusic: subscription playlist fallback preserves selected object and persistent identity", function()
  local calls, added = 0, nil
  hs.osascript._applescript = function(script)
    calls = calls + 1
    if calls == 1 then
      t.ok(script:find("database ID is 789", 1, true))
      return true, "ERROR: Can only duplicate subscription tracks to library source"
    end
    t.ok(script:find("set selectedTrack to (first track of library playlist 1 whose database ID is 789)", 1, true))
    t.ok(script:find('set selectedPlaylist to (first user playlist whose persistent ID is "PLAYLIST2")', 1, true))
    t.ok(script:find('set importedTrack to duplicate selectedTrack to source "Library"', 1, true))
    t.ok(script:find("persistent ID is selectedPersistentID", 1, true))
    t.ok(script:find("duplicate importedTrack to selectedPlaylist", 1, true))
    t.eq(script:find("current track", 1, true), nil)
    t.eq(script:find("whose name", 1, true), nil)
    return true, "OK"
  end
  am.addToPlaylist("PLAYLIST2", 789, function(ok) added = ok end)
  t.eq(added, true)
  t.eq(calls, 2)
  resetStubs()
end)

t.test("applemusic: unresolved subscription identity reports failure without a name-based retry", function()
  local calls, added = 0, nil
  hs.osascript._applescript = function(script)
    calls = calls + 1
    t.eq(script:find("current track", 1, true), nil)
    t.eq(script:find("whose name", 1, true), nil)
    return true, "ERROR: Can't get track with the captured identity"
  end
  am.addToPlaylist("PLAYLIST2", 789, function(ok) added = ok end)
  t.eq(added, false)
  t.eq(calls, 2)
  resetStubs()
end)

t.test("applemusic: failed subprocess construction and start do not wedge refresh", function()
  local platform = t.loadModule("backends/applemusic/platform.lua")
  local original = hs.task.new
  local ok, err = pcall(function()
    hs.task.new = function() return nil end
    t.eq(platform.readAsync(function() error("unexpected completion") end), false)
    hs.task.new = function() return { start = function() return false end } end
    t.eq(platform.readAsync(function() error("unexpected completion") end), false)
    local calls = 0
    hs.task.new = original
    hs._exec = function() return '{"title":"Recovered"}' end
    t.eq(platform.readAsync(function(snapshot)
      calls = calls + 1
      t.eq(snapshot.title, "Recovered")
    end), true)
    t.eq(calls, 1)
  end)
  hs.task.new = original
  platform.stop()
  resetStubs()
  if not ok then error(err, 0) end
end)

t.test("applemusic: library tracks with the same title refresh context by database ID", function()
  T.resetArtState()
  hs.application._running.Music = true
  hs.timer._now = 1000
  local id, nameReads = 10, 0
  hs.osascript._applescript = function(script)
    if script:find("set s to player state", 1, true) then
      return true, "OK\tplaying\tfalse\tSame title\tArtist\t" .. id .. "\t100\t10\tfalse"
    end
    if script:find("return name of current playlist", 1, true) then
      nameReads = nameReads + 1
      return true, "Playlist " .. id
    end
    return true, "ERROR"
  end
  am.getState()
  t.eq(am.getName(), "Playlist 10")
  id = 11
  hs.timer._now = 1003
  am.getState()
  t.eq(am.getName(), "Playlist 11")
  t.eq(nameReads, 2)
  resetStubs()
end)

-- ---------------------------------------------------------------------------
-- getState: Music not running
-- ---------------------------------------------------------------------------

t.test("applemusic: getState returns {running=false} when Music is not running", function()
  T.resetArtState()
  -- hs.application._running is empty (no "Music" key) so get() returns nil.
  local s = am.getState()
  t.eq(s, { running = false })
  resetStubs()
end)

-- A bare `tell application "Music"` relaunches Music (even mid-quit), so every
-- script that fires on its own must guard on `is running`. refreshPlaylists runs
-- on Spoon start and every menu open — the most common relaunch vector.
t.test("applemusic: refreshPlaylists guards on `is running` (never relaunches Music)", function()
  local captured
  hs.osascript._applescript = function(s) captured = s; return true, "" end
  am.refreshPlaylists()
  t.ok(captured and captured:find('application "Music" is running', 1, true),
    "playlist script must guard on `is running` so a bare tell never relaunches Music")
  resetStubs()
end)

-- ---------------------------------------------------------------------------
-- getState: library track with embedded artwork (exportArt succeeds)
-- ---------------------------------------------------------------------------

t.test("applemusic: getState library track with embedded art sets artPath, not artUrl", function()
  T.resetArtState()
  local trackId = 1234
  withFakeArt(trackId, function(expectedPath)
    hs.application._running["Music"] = true
    hs.osascript._applescript = function(script)
      -- exportArt script contains "raw data of artwork"
      if script:find("raw data of artwork", 1, true) then
        return true, "OK"
      end
      -- MUSIC_QUERY: library track with embedded art
      return true, "OK\tplaying\tfalse\tMy Track\tMy Artist\t" .. trackId .. "\t200\t40\tfalse"
    end

    local s = am.getState()
    t.eq(s.running, true)
    t.eq(s.playing, true)
    t.eq(s.track, "My Track")
    t.eq(s.artist, "My Artist")
    t.eq(s.trackId, trackId)
    t.eq(s.artPath, expectedPath)
    t.eq(s.artUrl, nil)   -- embedded art found, no URL fallback needed
    -- progress: 40s of 200s = 0.2
    t.eq(s.progress, 0.2)
  end)
  resetStubs()
end)

-- ---------------------------------------------------------------------------
-- getState: library track WITHOUT embedded art (exportArt ERROR), cover via
-- MediaRemote URL. This is the real-world regression: catalog-matched library
-- tracks have no embedded artwork but MediaRemote exposes their cover URL.
-- ---------------------------------------------------------------------------

t.test("applemusic: getState falls back to MediaRemote URL when library art is empty", function()
  T.resetArtState()
  local COVER = "https://is1-ssl.mzstatic.com/image/thumb/x/800x800bb.jpg"

  hs.application._running["Music"] = true
  hs.osascript._applescript = function(script)
    if script:find("raw data of artwork", 1, true) then
      return true, "ERROR"  -- catalog match: no embedded artwork to export
    end
    -- MUSIC_QUERY: library track, full metadata, database id 7928.
    return true, "OK\tplaying\tfalse\tFosforinis Baseinas\tArtist\t7928\t180\t10\tfalse"
  end
  -- MediaRemote runs in a subprocess; its stdout is the JSON cover URL.
  hs._exec = function(_)
    return '{"title":"Fosforinis Baseinas","artist":"Artist","duration":180,' ..
      '"elapsed":10,"rate":1,"artworkId":"' .. COVER .. '"}'
  end

  local s = am.getState()
  t.eq(s.running, true)
  t.eq(s.track, "Fosforinis Baseinas")
  t.eq(s.trackId, 7928)
  t.eq(s.artPath, nil)     -- nothing exported
  t.eq(s.artUrl, COVER)    -- pill gets the cover from MediaRemote

  -- Resolved once and cached: a second getState() does not re-spawn osascript.
  local execCalls = 0
  hs._exec = function(_) execCalls = execCalls + 1; return "" end
  local s2 = am.getState()
  t.eq(s2.artUrl, COVER)
  t.eq(execCalls, 0)

  resetStubs()
end)

-- ---------------------------------------------------------------------------
-- Library-path throttle + interpolation (the energy fix): MUSIC_QUERY runs at
-- most once per interval; the progress bar advances locally in between.
-- ---------------------------------------------------------------------------

t.test("applemusic: interpolateAsState advances a playing snapshot, leaving the original", function()
  local snap = { running = true, playing = true, durMs = 100000, progress = 0.1, track = "x" }
  local out = T.interpolateAsState(snap, 5) -- +5s of a 100s track -> 15/100
  t.ok(math.abs(out.progress - 0.15) < 1e-9, "progress advanced by 5s")
  t.eq(snap.progress, 0.1) -- cached snapshot untouched
end)

t.test("applemusic: interpolateAsState leaves paused / zero-duration snapshots unchanged", function()
  local paused = { playing = false, durMs = 100000, progress = 0.2 }
  t.eq(T.interpolateAsState(paused, 10), paused)
  local nodur = { playing = true, durMs = 0, progress = 0 }
  t.eq(T.interpolateAsState(nodur, 10), nodur)
end)

t.test("applemusic: getState throttles MUSIC_QUERY and interpolates between reads", function()
  T.resetArtState()
  hs.application._running["Music"] = true
  local mqCalls = 0
  hs.osascript._applescript = function(script)
    if script:find("set s to player state", 1, true) then
      mqCalls = mqCalls + 1
      -- playing library track: dur=100s, pos=10s -> progress 0.1, trackId 4242.
      return true, "OK\tplaying\tfalse\tSong\tArtist\t4242\t100\t10\tfalse"
    end
    return true, "" -- exportArt / shuffle / others: harmless empty result
  end
  hs._exec = function(_) return "" end

  hs.timer._now = 1000
  local s1 = am.getState()                 -- real read at t=1000
  t.eq(mqCalls, 1)
  t.eq(s1.track, "Song")
  t.ok(math.abs(s1.progress - 0.1) < 1e-9, "fresh read is not interpolated")

  hs.timer._now = 1002                      -- +2s, within AS_POLL_INTERVAL_SEC (3)
  local s2 = am.getState()                  -- served from snapshot, no MUSIC_QUERY
  t.eq(mqCalls, 1)
  t.eq(s2.track, "Song")
  t.ok(math.abs(s2.progress - 0.12) < 1e-9, "progress interpolated +2s")

  hs.timer._now = 1004                       -- +4s from the read, past the interval
  am.getState()                              -- real read again
  t.eq(mqCalls, 2)
  resetStubs()
end)

-- ---------------------------------------------------------------------------
-- getState: FALLBACK streaming track, MediaRemote returns a URL cover
-- ---------------------------------------------------------------------------

t.test("applemusic: getState FALLBACK streaming track sets cachedPath=mr, returns artUrl", function()
  T.resetArtState()
  local COVER = "https://example.com/cover.jpg"

  hs.application._running["Music"] = true
  -- MUSIC_QUERY returns FALLBACK (streaming track, not in library).
  -- SHUFFLE_QUERY is distinguishable by "return shuffle enabled" (vs MUSIC_QUERY's
  -- "set sh to shuffle enabled"); match on the SHUFFLE_QUERY-unique substring.
  local applescriptCalls = 0
  hs.osascript._applescript = function(script)
    if script:find("return shuffle enabled", 1, true) then
      return true, "false"
    end
    applescriptCalls = applescriptCalls + 1
    return true, "FALLBACK\tplaying\tfalse\t-1728"
  end
  -- First (sync) MediaRemote read and the subsequent async task read both hit hs._exec
  hs._exec = function(_)
    return '{"title":"Stream Song","artist":"DJ","duration":240,"elapsed":60,"rate":1,"artworkId":"' .. COVER .. '"}'
  end

  -- First getState: FALLBACK -> sync MediaRemote read -> cachedPath="mr"
  local s = am.getState()
  t.eq(s.running, true)
  t.eq(s.playing, true)
  t.eq(s.track, "Stream Song")
  t.eq(s.trackId, nil)        -- no library trackId for streaming
  t.eq(s.artUrl, COVER)
  t.eq(s.artPath, nil)

  -- Second getState: steady-state "mr" path - async task fires via hs.task stub.
  -- The track is still the same so cachedPath stays "mr".
  local s2 = am.getState()
  t.eq(s2.running, true)
  t.eq(s2.track, "Stream Song")
  t.eq(s2.artUrl, COVER)
  -- MUSIC_QUERY must NOT be called on the second tick (cachedPath == "mr")
  t.eq(applescriptCalls, 1)

  resetStubs()
end)

-- ---------------------------------------------------------------------------
-- getState: FALLBACK but MediaRemote returns empty output (MR dark)
-- cachedPath must NOT stick to "mr"; next tick re-probes MUSIC_QUERY.
-- ---------------------------------------------------------------------------

t.test("applemusic: getState FALLBACK with dark MediaRemote does not pin cachedPath=mr", function()
  T.resetArtState()

  hs.application._running["Music"] = true
  local musicQueryCalls = 0
  hs.osascript._applescript = function(script)
    if script:find("return shuffle enabled", 1, true) then
      return true, "false"
    end
    musicQueryCalls = musicQueryCalls + 1
    return true, "FALLBACK\tplaying\ttrue\t-1728"
  end
  -- MediaRemote is dark (empty stdout)
  hs._exec = function(_) return "" end

  local s = am.getState()
  t.eq(s.running, true)
  t.eq(s.playing, true)    -- from the FALLBACK playerState field
  t.eq(s.shuffle, true)    -- from the FALLBACK shuffleStr field
  t.eq(s.trackId, nil)

  -- cachedPath did not become "mr" - a second call must re-probe MUSIC_QUERY
  local callsBefore = musicQueryCalls
  am.getState()
  t.ok(musicQueryCalls > callsBefore, "MUSIC_QUERY must be re-probed after dark MR")

  resetStubs()
end)

-- ---------------------------------------------------------------------------
-- getState: "mr" path track change resets cachedPath so next tick re-probes
-- ---------------------------------------------------------------------------

t.test("applemusic: getState mr-path track change resets cachedPath and re-probes", function()
  T.resetArtState()

  hs.application._running["Music"] = true
  local musicQueryCalls = 0
  hs.osascript._applescript = function(script)
    if script:find("return shuffle enabled", 1, true) then
      return true, "false"
    end
    musicQueryCalls = musicQueryCalls + 1
    return true, "FALLBACK\tplaying\tfalse\t-1728"
  end

  -- Drive getState to cachedPath="mr" on track "A"
  hs._exec = function(_)
    return '{"title":"Track A","artist":"X","duration":200,"elapsed":10,"rate":1,"artworkId":"https://a.com/art.jpg"}'
  end
  local s1 = am.getState()
  t.eq(s1.track, "Track A")
  local callsAfterFirst = musicQueryCalls

  -- Change hs._exec to return track "B" (simulates track change seen by async refresh)
  hs._exec = function(_)
    return '{"title":"Track B","artist":"X","duration":200,"elapsed":5,"rate":1,"artworkId":"https://b.com/art.jpg"}'
  end

  -- Second getState: "mr" path, async task fires with title "B" -> title changed
  -- -> cachedPath reset to nil. Third getState then re-probes MUSIC_QUERY.
  hs.timer._now = hs.timer._now + am.getPollInterval()
  am.getState()
  local callsBeforeThird = musicQueryCalls
  am.getState()
  t.ok(musicQueryCalls > callsBeforeThird, "MUSIC_QUERY must be called after track-change reset")

  resetStubs()
end)

-- ---------------------------------------------------------------------------
-- getState: libArtUrl failure caches false; no repeated exec calls
-- ---------------------------------------------------------------------------

t.test("applemusic: getState libArtUrl failure caches false and does not retry", function()
  T.resetArtState()

  local trackId = 5555
  hs.application._running["Music"] = true
  hs.osascript._applescript = function(script)
    if script:find("raw data of artwork", 1, true) then
      return true, "ERROR"  -- no embedded art
    end
    return true, "OK\tplaying\tfalse\tSong\tArtist\t" .. trackId .. "\t120\t30\tfalse"
  end
  -- MediaRemote returns empty (no URL available)
  local execCalls = 0
  hs._exec = function(_) execCalls = execCalls + 1; return "" end

  local s = am.getState()
  t.eq(s.artUrl, nil)
  t.eq(s.artPath, nil)
  -- libArtUrlCache should record false (negative cache) for this trackId
  t.eq(T.libArtUrlCache()[trackId], false)

  local callsAfterFirst = execCalls

  -- Second getState: libArtUrlCache[trackId] == false, no re-exec
  am.getState()
  t.eq(execCalls, callsAfterFirst, "exec must not be called again for cached-false trackId")

  resetStubs()
end)

-- ---------------------------------------------------------------------------
-- getState: MUSIC_QUERY ok==false -> graceful runningState (no crash)
-- ---------------------------------------------------------------------------

t.test("applemusic: getState with applescript failure returns running=true playing=false", function()
  T.resetArtState()

  hs.application._running["Music"] = true
  -- Simulate hs.osascript.applescript returning ok=false (transient failure)
  hs.osascript._applescript = function(_) return false, nil end

  local s = am.getState()
  t.eq(s.running, true)
  t.eq(s.playing, false)
  t.eq(s.track, nil)
  t.eq(s.trackId, nil)

  resetStubs()
end)

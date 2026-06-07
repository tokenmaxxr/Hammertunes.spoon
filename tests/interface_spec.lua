local t = require("helper")
local iface = t.loadModule("backends/interface.lua")
local verify = iface.verify

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Build a fully-compliant stub backend so individual tests can nil out one
-- member at a time and confirm the verifier catches exactly that member.
local function fullStub()
  local noop = function() end
  return {
    appName               = "TestApp",
    getState              = noop,
    start                 = noop,
    stop                  = noop,
    refresh               = noop,
    refreshLiked          = noop,
    getLiked              = noop,
    like                  = noop,
    unlike                = noop,
    getPlaylists          = noop,
    refreshPlaylists      = noop,
    getRecentlyPlayed     = noop,
    refreshRecentlyPlayed = noop,
    addToPlaylist         = noop,
    playContext           = noop,
    getName               = noop,
    getUri                = noop,
    getSmartShuffle       = noop,
    setShuffling          = noop,
    getPosition           = noop,
    setPosition           = noop,
    previous              = noop,
    next                  = noop,
    playpause             = noop,
    play                  = noop,
    authenticate          = noop,
  }
end

-- ---------------------------------------------------------------------------
-- Real backends pass verification
-- ---------------------------------------------------------------------------

t.test("interface: verify accepts the real Spotify backend", function()
  local spotify = t.loadModule("backends/spotify.lua")
  local result = verify(spotify, "backends/spotify.lua")
  t.ok(result == spotify, "verify should return the backend itself")
end)

t.test("interface: verify accepts the real Apple Music backend", function()
  local applemusic = t.loadModule("backends/applemusic.lua")
  local result = verify(applemusic, "backends/applemusic.lua")
  t.ok(result == applemusic, "verify should return the backend itself")
end)

-- ---------------------------------------------------------------------------
-- Empty table errors with informative message
-- ---------------------------------------------------------------------------

t.test("interface: verify({}) errors and names the backend and missing members", function()
  local ok, err = pcall(verify, {}, "backends/fake.lua")
  t.ok(not ok, "expected an error")
  -- The error message must name the backend file.
  t.ok(err:find("backends/fake.lua", 1, true), "error should mention the backend name")
  -- A few representative missing members should appear.
  t.ok(err:find("getState", 1, true), "error should mention getState")
  t.ok(err:find("appName", 1, true), "error should mention appName")
end)

-- ---------------------------------------------------------------------------
-- Single missing member is caught precisely
-- ---------------------------------------------------------------------------

t.test("interface: verify errors on exactly the one missing function", function()
  local stub = fullStub()
  stub.playpause = nil
  local ok, err = pcall(verify, stub, "backends/stub.lua")
  t.ok(not ok, "expected an error")
  t.ok(err:find("playpause", 1, true), "error should name the missing member")
  -- No other members should appear in the message.
  t.ok(not err:find("getState", 1, true), "only the culprit should appear")
end)

t.test("interface: verify errors when appName has the wrong type", function()
  local stub = fullStub()
  stub.appName = 42  -- wrong type: number, not string
  local ok, err = pcall(verify, stub, "backends/stub.lua")
  t.ok(not ok, "expected an error")
  t.ok(err:find("appName", 1, true), "error should mention appName")
end)

-- ---------------------------------------------------------------------------
-- Complete stub passes (all required members present)
-- ---------------------------------------------------------------------------

t.test("interface: full stub passes verification", function()
  local stub = fullStub()
  local result = verify(stub, "backends/stub.lua")
  t.ok(result == stub, "verify should return the backend itself")
end)

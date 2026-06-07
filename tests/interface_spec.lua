local t = require("helper")
local iface = t.loadModule("backends/interface.lua")
local verify = iface.verify

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Build a fully-compliant stub backend, derived from the exported REQUIRED
-- spec so it never drifts, letting individual tests nil out one member at a
-- time and confirm the verifier catches exactly that member.
local function fullStub()
  local noop = function() end
  local stub = {}
  for member, expectedType in pairs(iface.REQUIRED) do
    stub[member] = expectedType == "string" and "TestApp" or noop
  end
  return stub
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

-- ---------------------------------------------------------------------------
-- REQUIRED spec and LuaCATS annotations stay in sync
-- ---------------------------------------------------------------------------

t.test("interface: every REQUIRED member has a ---@field annotation", function()
  local f = assert(io.open(t.ROOT .. "backends/interface.lua"))
  local source = f:read("a")
  f:close()
  for member in pairs(iface.REQUIRED) do
    t.ok(source:find("---@field " .. member .. " ", 1, true),
      "missing ---@field annotation for required member " .. member)
  end
end)

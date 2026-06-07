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

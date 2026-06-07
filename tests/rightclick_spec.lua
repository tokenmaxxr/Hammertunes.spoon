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
    "-", "Unlike", "Copy \u{201C}Song by Artist\u{201D}", "Open on YouTube",
    "-", "Shuffle: Off", "Play Liked Songs",
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
  t.eq(titles(items), { "Open Spotify", "-", "Shuffle: On", "Play Liked Songs" })
end)

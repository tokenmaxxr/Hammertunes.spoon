local t = require("helper")
local spotify = t.loadModule("backends/spotify.lua")
local parse = spotify._test.parseSpotifyState

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

-- Apple Music platform adapter. Owns the MediaRemote subprocess and temporary script.
local module = {}
local log = hs.logger.new("hammertunes.applemusic.platform", "info")
local warnedMediaRemote = false
local generation = 0
local task = nil

local MEDIA_REMOTE_JXA = [[
  ObjC.import('Foundation');
  function run() {
    try {
      var fw = $.NSBundle.bundleWithPath(
        '/System/Library/PrivateFrameworks/MediaRemote.framework'
      );
      if (!fw.load) { return JSON.stringify({error: "bundle load failed"}); }
      fw.load;

      var req = $.NSClassFromString('MRNowPlayingRequest');
      if (!req || !req.localNowPlayingItem) {
        return JSON.stringify({error: "MRNowPlayingRequest unavailable"});
      }
      var item = req.localNowPlayingItem;
      if (!item || !item.nowPlayingInfo) {
        return JSON.stringify({error: "no nowPlayingInfo"});
      }
      var info = item.nowPlayingInfo;

      function str(key) {
        try {
          var v = info.valueForKey(key);
          return (v && v.js !== undefined) ? v.js : null;
        } catch(e) { return null; }
      }
      function num(key) {
        try {
          var v = info.valueForKey(key);
          return (v && v.doubleValue !== undefined) ? v.doubleValue : null;
        } catch(e) { return null; }
      }

      var title    = str('kMRMediaRemoteNowPlayingInfoTitle');
      var artist   = str('kMRMediaRemoteNowPlayingInfoArtist');
      var album    = str('kMRMediaRemoteNowPlayingInfoAlbum');
      var duration = num('kMRMediaRemoteNowPlayingInfoDuration');
      var elapsed  = num('kMRMediaRemoteNowPlayingInfoElapsedTime');
      var rate     = num('kMRMediaRemoteNowPlayingInfoPlaybackRate');
      var artworkId = str('kMRMediaRemoteNowPlayingInfoArtworkIdentifier');

      // Timestamp when the elapsed time snapshot was taken (monotonic clock).
      // If present, actual position = elapsed + (now - timestamp) * rate.
      // Fall back to elapsed alone if the timestamp key is absent.
      var ts = null;
      try {
        var tsVal = info.valueForKey('kMRMediaRemoteNowPlayingInfoTimestamp');
        if (tsVal && tsVal.doubleValue !== undefined) {
          ts = tsVal.doubleValue;
        }
      } catch(e) {}

      // Which app owns system Now Playing. localNowPlayingItem is system-wide,
      // so this is how we tell an Apple Music track from a browser/Spotify one
      // (see mrSourceLabel). bundleId is the gate; appName is the display label.
      var bundleId = null, appName = null;
      try {
        var pp = req.localNowPlayingPlayerPath;
        if (pp && pp.client) {
          var b = pp.client.bundleIdentifier;
          bundleId = (b && b.js !== undefined) ? b.js : null;
          var d = pp.client.displayName;
          appName = (d && d.js !== undefined) ? d.js : null;
        }
      } catch(e) {}

      return JSON.stringify({
        title: title, artist: artist, album: album,
        duration: duration, elapsed: elapsed, rate: rate, timestamp: ts,
        artworkId: artworkId, bundleId: bundleId, appName: appName
      });
    } catch(e) {
      return JSON.stringify({error: String(e)});
    }
  }
]]

-- CRITICAL: MediaRemote's now-playing info only populates for a freshly spawned
-- process on macOS Tahoe (26.x). Run in-process via hs.osascript.javascript and
-- `localNowPlayingItem.nowPlayingInfo` comes back empty ("no nowPlayingInfo")
-- inside Hammerspoon's long-lived JSContext - verified by running the identical
-- JXA both ways at the same instant: a separate `osascript` process gets the
-- track, the in-process call does not. So we shell the JXA out through osascript
-- (sync via hs.execute, or async via hs.task). The script is written to a temp
-- file once, lazily (passing it inline would require escaping its own quotes).
local mrJxaPath = nil  -- temp file path, false on write failure, nil until tried
local function jxaPath()
  if mrJxaPath ~= nil then return mrJxaPath or nil end
  local path = os.tmpname()
  local f = io.open(path, "w")
  if not f then mrJxaPath = false; return nil end
  f:write(MEDIA_REMOTE_JXA)
  f:close()
  mrJxaPath = path
  return path
end

-- Log a MediaRemote degradation once. The private framework can break across
-- OS updates; we warn the first time and then stay quiet to avoid log spam.
local function warnMROnce(msg)
  if not warnedMediaRemote then
    log.w(msg)
    warnedMediaRemote = true
  end
end

-- Parse the JXA's stdout (a JSON string) into a now-playing table, or nil on
-- any failure. Shared by the sync and async readers; warns once on framework
-- failure so a degraded MediaRemote doesn't spam the log.
local function parseMrOutput(output)
  if type(output) ~= "string" or output == "" then
    warnMROnce("MediaRemote JXA call failed; streaming track metadata unavailable: " .. tostring(output))
    return nil
  end
  local data = hs.json.decode(output)
  if not data then
    warnMROnce("MediaRemote JXA returned non-JSON: " .. tostring(output))
    return nil
  end
  if data.error then
    -- "no nowPlayingInfo" is normal when nothing is playing; don't escalate.
    if data.error ~= "no nowPlayingInfo" then
      warnMROnce("MediaRemote JXA error: " .. tostring(data.error))
    end
    return nil
  end
  return data
end

-- Synchronous MediaRemote read (blocks ~150 ms). Used only where we need the
-- answer right now and at most once per track: the first tick a streaming track
-- is detected (FALLBACK), and resolving a library track's cover URL once per
-- trackId (libArtUrl). The steady-state hot path uses refreshMrSnapshot instead.
local function readMediaRemote()
  local path = jxaPath()
  if not path then
    warnMROnce("MediaRemote: could not write JXA temp file; streaming metadata unavailable")
    return nil
  end
  return parseMrOutput(hs.execute("/usr/bin/osascript -l JavaScript " .. path))
end

-- A canceled request may still deliver its completion callback. Its generation
-- must match before it can clear the active task or publish a result.
function module.cancel()
  generation = generation + 1
  local old = task
  task = nil
  if old and old.terminate then old:terminate() end
end

function module.readAsync(callback)
  if task then return false end
  local path = jxaPath()
  if not path then return false end
  local requestGeneration = generation
  local completed = false
  local nextTask = hs.task.new("/usr/bin/osascript", function(code, stdout)
    completed = true
    if requestGeneration ~= generation then return end
    task = nil
    callback(code == 0 and parseMrOutput(stdout) or nil)
  end, { "-l", "JavaScript", path })
  if not nextTask then return false end
  task = nextTask
  if not nextTask:start() then
    if task == nextTask then task = nil end
    return false
  end
  if completed and task == nextTask then task = nil end
  return true
end

function module.stop()
  module.cancel()
  if type(mrJxaPath) == "string" then os.remove(mrJxaPath) end
  mrJxaPath = nil
  warnedMediaRemote = false
end

module.read = readMediaRemote
module.parse = parseMrOutput
local MUSIC_QUERY = [[
if application "Music" is running then
  tell application "Music"
    set s to player state as text
    set sh to shuffle enabled as text
    try
      set t to current track
      set n to name of t
      set ar to artist of t
      set di to database id of t as text
      set du to duration of t
      set pp to player position
      set fv to favorited of t as text
      return "OK" & tab & s & tab & sh & tab & n & tab & ar & tab & di & tab & du & tab & pp & tab & fv
    on error errMsg number errNum
      -- -1728: can't get object (streaming track not in library)
      -- Return the player state + shuffle so transport UI stays accurate.
      return "FALLBACK" & tab & s & tab & sh & tab & errNum as text
    end try
  end tell
else
  return "NOTRUNNING"
end if
]]

-- Read shuffle state cheaply when we already know we're on the MediaRemote
-- path. Avoids a full MUSIC_QUERY re-probe just to get shuffle.
local SHUFFLE_QUERY = [[
if application "Music" is running then
  tell application "Music"
    return shuffle enabled as text
  end tell
else
  return "false"
end if
]]

function module.readShuffle()
  local ok, result = hs.osascript.applescript(SHUFFLE_QUERY)
  if ok and type(result) == "string" then
    return result == "true"
  end
  return false
end

function module.readLibrary() return hs.osascript.applescript(MUSIC_QUERY) end

return module

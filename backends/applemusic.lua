-- Hammertunes Apple Music backend.
--
-- Talks to the Music app via AppleScript (library tracks) and falls back to
-- the private MediaRemote framework via JXA (streaming catalog tracks). See
-- the "Tahoe -1728 workaround" comment in getState() for why both paths exist.
--
-- Transport delegates to hs.itunes.*, which targets the Music app without
-- touching track metadata. Shuffle, like/unlike, and playlists go through
-- AppleScript. No OAuth is required.

---@type HammertunesBackend
local module = {}
local log = hs.logger.new("hammertunes.applemusic", "info")

-- ---------------------------------------------------------------------------
-- Identity / capabilities
-- ---------------------------------------------------------------------------

module.appName = "Music"
module.supportsSmartShuffle = false
module.supportsReauth = false
-- Accent for the "liked" heart on the pill: the Apple Music pinkish-red (#FC3C44).
module.likedColor = { red = 0.988, green = 0.235, blue = 0.267 }

-- ---------------------------------------------------------------------------
-- Module-level state
-- ---------------------------------------------------------------------------

local onChange = nil

-- Two-path result cache: once we know which path works for the current track
-- (AppleScript vs MediaRemote fallback), we stay on that path until the track
-- changes. This keeps getState() to ONE osascript call per tick instead of
-- two on every streaming track.
--
-- "as"  = AppleScript succeeded last time (library track)
-- "mr"  = MediaRemote fallback succeeded last time (streaming track)
-- nil   = unknown; probe on next call
local cachedPath = nil     -- "as" | "mr" | nil
local lastKnownTitle = nil -- used to detect track changes and reset cachedPath

-- Artwork: exported once per library track to a PER-TRACK path. The path must
-- be unique per track because pill.lua caches loaded images keyed by path — a
-- single shared path would make every track show the first track's cover.
local artCache = {}         -- [trackId] = path or false (library tracks only)
local ART_PATH_PREFIX = os.getenv("HOME") .. "/.hammerspoon/.hammertunes-applemusic-art-"
local function artPathFor(trackId) return ART_PATH_PREFIX .. trackId .. ".png" end

-- Many Apple Music library tracks are catalog matches with NO embedded artwork
-- (`count of artworks of current track` is 0), so exportArt has nothing to
-- write. MediaRemote still exposes their cover as an https URL, which we feed
-- through the same artUrl -> images.lua HTTP cache the Spotify backend uses.
-- Resolve it once per trackId; false means "checked, no URL available".
local libArtUrlCache = {}   -- [trackId] = url or false

-- Liked state for the current library track.
local currentLiked = nil
local currentLikedTrackId = nil

-- Cached playing-context (playlist) name. getName() is called every render
-- tick by pill.lua; reading it costs an osascript, so we cache it and only
-- re-read when getState() flags a track change via nameDirty. getState() sets
-- nameDirty on first track detection, so it can start false.
local currentName = nil
local nameDirty = false

-- Playlist cache.
local playlistsCache = nil

-- Streaming now-playing snapshot, refreshed off the hot path. The MediaRemote
-- read is a blocking subprocess (~150 ms); running it every 1 Hz tick janks
-- the UI, so the steady-state "mr" path refreshes this asynchronously via
-- hs.task and serves the last good snapshot (progress is interpolated locally
-- from the snapshot's timestamp/elapsed/rate, see mrProgress). mrTaskInFlight
-- single-flights the background read so ticks don't pile up overlapping tasks.
local mrSnapshot = nil
local mrTaskInFlight = false

-- Warn-once flags for degraded paths.
local warnedMediaRemote = false

-- Reset the now-playing caches and report the app as not running. Used wherever
-- getState() determines Music isn't running.
local function notRunning()
  cachedPath = nil
  lastKnownTitle = nil
  mrSnapshot = nil
  currentName, nameDirty = nil, false
  return { running = false }
end

-- A running-but-no-readable-track state. Keeps the state-table shape in one
-- place so a future field addition can't be silently omitted from a call site.
local function runningState(playing, shuffle)
  return {
    running = true, playing = playing,
    track = nil, artist = nil, progress = 0, durMs = 0,
    artUrl = nil, artPath = nil, trackId = nil, shuffle = shuffle,
  }
end

-- ---------------------------------------------------------------------------
-- Artwork export (library tracks only)
-- ---------------------------------------------------------------------------

-- Export the artwork of the current track to a per-track file once per trackId.
-- Returns the path on success, nil on failure. Writes raw image data via the
-- AppleScript "write" command into a file handler, which Music yields as a
-- «data» blob; hs.image.imageFromPath can handle the TIFF/PNG bytes directly.
local function exportArt(trackId)
  if not trackId then return nil end
  local cached = artCache[trackId]
  if cached ~= nil then return cached or nil end  -- false means known failure

  local path = artPathFor(trackId)
  -- AppleScript: write the raw image bytes of artwork 1 to the file.
  -- We open the file with write-only permission and overwrite on each export.
  local script = string.format([[
    tell application "Music"
      try
        set artData to raw data of artwork 1 of current track
      on error
        return "ERROR"
      end try
    end tell
    set tmpPath to "%s"
    set fRef to open for access POSIX file tmpPath with write permission
    try
      set eof fRef to 0
      write artData to fRef
      close access fRef
    on error
      close access fRef
      return "ERROR"
    end try
    return "OK"
  ]], path)

  local ok, result = hs.osascript.applescript(script)
  if ok and result == "OK" then
    local img = hs.image.imageFromPath(path)
    if img then
      artCache[trackId] = path
      return path
    end
  end
  -- Best-effort: if export fails, note it so we don't retry every tick.
  artCache[trackId] = false
  return nil
end

-- ---------------------------------------------------------------------------
-- MediaRemote fallback via JXA (streaming / catalog tracks)
-- ---------------------------------------------------------------------------
-- The private MediaRemote framework provides now-playing info system-wide,
-- bypassing the Music.app AppleScript dictionary. It is the only way to read
-- metadata for Apple Music catalog tracks not added to the library on macOS
-- Tahoe (26.x), where `tell application "Music" to get name of current track`
-- raises error -1728 for streaming tracks.
--
-- Caveat: MediaRemote is a private framework. It can change or be removed
-- in future OS updates. If loading fails we degrade silently (warn once) and
-- fall back to library-tracks-only coverage.

-- JXA source that loads MediaRemote and reads now-playing info synchronously
-- via MRNowPlayingRequest (macOS 12+). Returns a JSON string.
--
-- Key names confirmed against MediaRemote.framework headers and the SKaplan
-- gist (https://gist.github.com/SKaplanOfficial/f9f5bdd6455436203d0d318c078358de)
-- which shows the MRNowPlayingRequest synchronous approach works on macOS 15+.
--
-- artworkId is, for Apple Music content, a direct https cover URL - we use it
-- as artUrl and let images.lua fetch it (see mrArtUrl). We do NOT read the raw
-- artwork bytes: that blob is 100-400 KB and, for the Spotify/Apple Music
-- sources this Spoon targets, artworkId is always a URL, so the bytes are never
-- needed.
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

      return JSON.stringify({
        title: title, artist: artist, album: album,
        duration: duration, elapsed: elapsed, rate: rate, timestamp: ts,
        artworkId: artworkId
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

-- Kick a background MediaRemote read and store the result in mrSnapshot when it
-- lands. Single-flighted: a tick that fires while a read is still running is a
-- no-op, so the 1 Hz hot path never blocks or stacks up osascript processes.
-- A failed/empty read sets mrSnapshot to nil, which the hot path treats as
-- "MediaRemote went dark" and re-probes - self-healing.
local function refreshMrSnapshot()
  if mrTaskInFlight then return end
  local path = jxaPath()
  if not path then return end
  mrTaskInFlight = true
  hs.task.new("/usr/bin/osascript", function(_code, stdOut, _stdErr)
    mrTaskInFlight = false
    mrSnapshot = parseMrOutput(stdOut)
  end, { "-l", "JavaScript", path }):start()
end

-- ---------------------------------------------------------------------------
-- Streaming artwork
-- ---------------------------------------------------------------------------

-- MediaRemote's artworkId is, for Apple Music content, a direct https image URL
-- (e.g. .../800x800bb.jpg) - present in every read, no file export needed.
-- Return it when it looks like a URL, else nil (a source handing back an opaque
-- identifier just gets no cover; we don't read the raw artwork bytes).
local function mrArtUrl(mrData)
  local id = mrData and mrData.artworkId
  if type(id) == "string" and id:match("^https?://") then return id end
  return nil
end

-- Resolve an artwork URL for a library track that has no embedded artwork.
-- The now-playing item IS the current track, so MediaRemote's artworkId is its
-- cover. Read once per trackId and cache the URL (or false) so the library hot
-- path never re-reads MediaRemote for an already-resolved track.
local function libArtUrl(trackId)
  if not trackId then return nil end
  local cached = libArtUrlCache[trackId]
  if cached ~= nil then return cached or nil end
  -- One blocking read per trackId (the result is cached), not a per-tick cost.
  local mrData = readMediaRemote()
  local url = mrData and mrArtUrl(mrData)
  libArtUrlCache[trackId] = url or false
  return url
end

-- ---------------------------------------------------------------------------
-- State helpers (shared by both getState paths)
-- ---------------------------------------------------------------------------

-- Clamp a position/duration pair to a 0..1 progress fraction.
local function calcProgress(posSec, durMs)
  if durMs <= 0 then return 0 end
  return math.max(0, math.min(1, posSec / (durMs / 1000)))
end

-- Mac absolute time (2001-01-01 epoch) → Unix epoch, for MediaRemote snapshots.
local MR_MAC_EPOCH_OFFSET = 978307200

-- Convert a MediaRemote snapshot into (durMs, progress). The elapsed time is a
-- snapshot taken at mrData.timestamp; compensate for the time since by adding
-- (now - timestamp) * rate. Only trust small drifts (< 60s) — a large value
-- means the timestamp epoch interpretation is off, so fall back to raw elapsed.
local function mrProgress(mrData)
  local durMs   = math.max(0, (tonumber(mrData.duration) or 0) * 1000)
  local elapsed = tonumber(mrData.elapsed) or 0
  local rate    = tonumber(mrData.rate) or 0
  if mrData.timestamp and rate > 0 then
    local snapUnix = mrData.timestamp + MR_MAC_EPOCH_OFFSET
    local drift = math.max(0, hs.timer.secondsSinceEpoch() - snapUnix)
    if drift < 60 then elapsed = elapsed + drift * rate end
  end
  return durMs, calcProgress(elapsed, durMs)
end

-- Build the state table for a MediaRemote (streaming) track. Streaming tracks
-- have no library trackId, so no library actions and no local artPath; the
-- cover is always the MediaRemote URL (artUrl) or nothing.
local function mrState(mrData, shuffle, artUrl)
  local durMs, progress = mrProgress(mrData)
  local title = mrData.title
  return {
    running  = true,
    playing  = (tonumber(mrData.rate) or 0) > 0,
    track    = (title ~= "" and title) or nil,
    artist   = (mrData.artist ~= "" and mrData.artist) or nil,
    progress = progress,
    durMs    = durMs,
    artUrl   = artUrl,
    artPath  = nil,
    trackId  = nil,
    shuffle  = shuffle,
  }
end

-- ---------------------------------------------------------------------------
-- AppleScript helpers
-- ---------------------------------------------------------------------------

-- Single multi-field AppleScript for the library-track path. Tab-separated
-- so track/artist names containing "|" don't break parsing (mirrors the
-- Spotify backend's SPOTIFY_QUERY pattern). Reads in one osascript call:
--   playerState, shuffleEnabled, name, artist, databaseId, duration, playerPosition, favorited
--
-- Error -1728 fires when Music is running but the current track is a
-- streaming catalog track not in the library. We catch it and return a
-- sentinel so getState() knows to fall back to MediaRemote.
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

local function readShuffle()
  local ok, result = hs.osascript.applescript(SHUFFLE_QUERY)
  if ok and type(result) == "string" then
    return result == "true"
  end
  return false
end

-- Escape a string for embedding inside an AppleScript double-quoted literal.
-- Backslash first, then the quote, so playlist names with either survive.
local function asQuote(s) return (s:gsub('\\', '\\\\'):gsub('"', '\\"')) end

-- ---------------------------------------------------------------------------
-- getState() — the hot path, called at 1 Hz by pill.lua
-- ---------------------------------------------------------------------------

module.getState = function()
  -- Fast path: is Music running at all?
  if not hs.application.get("Music") then
    return notRunning()
  end

  -- Try the AppleScript library path first (or immediately if it succeeded
  -- last time). cachedPath == "as" means we expect this to work.
  if cachedPath ~= "mr" then
    local ok, result = hs.osascript.applescript(MUSIC_QUERY)
    if ok and type(result) == "string" then
      if result == "NOTRUNNING" then
        return notRunning()
      end

      if result:sub(1, 2) == "OK" then
        -- Library track: full metadata available.
        local _, state, shuffle, name, artist, dbId, durSec, posSec, favorited =
          result:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
        local durMs   = math.max(0, (tonumber(durSec) or 0) * 1000)
        local trackId = tonumber(dbId)
        local progress = calcProgress(tonumber(posSec) or 0, durMs)

        cachedPath = "as"
        -- Track-change detection: refresh the cached context name on change.
        if name ~= lastKnownTitle then
          lastKnownTitle = name
          nameDirty = true
        end

        -- Cache liked state from the atomic read we already did.
        if trackId and favorited ~= nil then
          currentLiked = favorited == "true"
          currentLikedTrackId = trackId
        end

        local artPath = exportArt(trackId)
        -- Catalog-matched library tracks have no embedded artwork to export;
        -- fall back to the MediaRemote cover URL so the pill isn't blank (see
        -- the libArtUrlCache header above for why MediaRemote is the source).
        -- `or nil` coerces the `false` from `not artPath` to nil when art exists.
        local artUrl = (not artPath) and libArtUrl(trackId) or nil

        return {
          running  = true,
          playing  = state == "playing",
          track    = name ~= "" and name or nil,
          artist   = artist ~= "" and artist or nil,
          progress = progress,
          durMs    = durMs,
          artUrl   = artUrl,
          artPath  = artPath,
          trackId  = trackId,
          shuffle  = shuffle == "true",
        }

      elseif result:sub(1, 8) == "FALLBACK" then
        -- -1728 or similar: streaming track. Fall through to MediaRemote below.
        -- Format is fixed: "FALLBACK\t<playerState>\t<shuffle>\t<errNum>".
        local _, playerState, shuffleStr = result:match("^([^\t]*)\t([^\t]*)\t([^\t]*)")
        playerState = playerState or ""
        shuffleStr  = shuffleStr or "false"
        -- First tick this track is seen: read MediaRemote synchronously so we
        -- show it immediately. Steady-state ticks then refresh in the
        -- background (see the "mr" path below), so this blocking read is paid
        -- at most once per track change, not every tick.
        local mrData = readMediaRemote()
        if not mrData then
          -- MediaRemote also failed (it's a private framework; blocked on
          -- newer macOS). Don't pin the "mr" path: with no MR title a track
          -- change can't be detected, so pinning would stick getState() on
          -- this empty state forever. Re-probe AppleScript next tick instead.
          cachedPath = nil
          return runningState(playerState == "playing", shuffleStr == "true")
        end
        -- This track needs MediaRemote from now on. Seed the snapshot the hot
        -- path serves so it has data before the first async refresh lands.
        cachedPath = "mr"
        mrSnapshot = mrData

        if mrData.title ~= lastKnownTitle then
          lastKnownTitle = mrData.title
          nameDirty = true
          -- Streaming track: clear liked since we have no trackId.
          currentLiked = nil
          currentLikedTrackId = nil
        end
        return mrState(mrData, shuffleStr == "true", mrArtUrl(mrData))
      end
    end
    -- AppleScript call itself failed (ok == false). Could be a transient
    -- error; don't cache anything, just return a minimal running state.
    return runningState(false, false)
  end

  -- cachedPath == "mr": we know the current track is streaming. Kick a
  -- background MediaRemote refresh (non-blocking) and serve the last snapshot,
  -- so the 1 Hz tick never blocks on the ~150 ms subprocess. Shuffle is a cheap
  -- in-process read; progress is interpolated locally in mrProgress, so a
  -- one-tick-stale snapshot still shows a smoothly advancing bar.
  refreshMrSnapshot()
  local mrData = mrSnapshot
  local shuffle = readShuffle()

  if not mrData then
    -- MediaRemote went dark mid-track (or the async read failed). Without a
    -- title a track change can't be detected, so drop the path cache and let
    -- the next tick re-probe AppleScript - self-healing.
    cachedPath = nil
    return runningState(false, shuffle)
  end

  -- Detect track change: if title changed, re-probe on the next tick (which
  -- goes through the FALLBACK path and a fresh synchronous read).
  if mrData.title ~= lastKnownTitle then
    lastKnownTitle = mrData.title
    cachedPath = nil
    nameDirty = true
    currentLiked = nil
    currentLikedTrackId = nil
  end

  return mrState(mrData, shuffle, mrArtUrl(mrData))
end

-- ---------------------------------------------------------------------------
-- Transport — delegates to hs.itunes.* (targets the Music app)
-- ---------------------------------------------------------------------------

module.next        = function() hs.itunes.next() end
module.previous    = function() hs.itunes.previous() end
module.playpause   = function() hs.itunes.playpause() end
module.play        = function() hs.itunes.play() end
module.getPosition = function() return hs.itunes.getPosition() end
module.setPosition = function(sec) hs.itunes.setPosition(sec) end

-- Music's shuffle property is `shuffle enabled` (a boolean). Note: Music also
-- has `song repeat` (off/one/all); we don't touch that here.
module.setShuffling = function(on)
  hs.osascript.applescript(
    'tell application "Music" to set shuffle enabled to ' .. tostring(on)
  )
  -- pill.lua schedules its own re-render; no need to call onChange here.
end

-- ---------------------------------------------------------------------------
-- Context
-- ---------------------------------------------------------------------------

-- getName: name of the current playlist, or nil. Best-effort, tooltip-only.
-- Re-reads `name of current playlist` only when getState() flags a track
-- change (nameDirty); otherwise returns the cached value so the 1 Hz render
-- loop doesn't spend an osascript on it every tick.
module.getName = function()
  if not nameDirty then return currentName end
  nameDirty = false
  local ok, result = hs.osascript.applescript([[
    tell application "Music"
      try
        return name of current playlist
      on error
        return ""
      end try
    end tell
  ]])
  currentName = (ok and type(result) == "string" and result ~= "") and result or nil
  return currentName
end

module.getUri          = function() return nil end
module.getSmartShuffle = function() return nil end

-- Liked state (library tracks only; nil for streaming).
module.getLiked = function() return currentLiked end

-- Re-read favorited for the current library track and update the cache.
-- Called by pill.lua on track change (or after like/unlike).
module.refreshLiked = function(trackId)
  if not trackId then
    currentLiked = nil
    currentLikedTrackId = nil
    return
  end
  if trackId == currentLikedTrackId and currentLiked ~= nil then return end
  currentLikedTrackId = trackId
  local ok, result = hs.osascript.applescript([[
    tell application "Music"
      try
        return favorited of current track as text
      on error
        return "nil"
      end try
    end tell
  ]])
  if ok and type(result) == "string" and result ~= "nil" then
    currentLiked = result == "true"
  else
    currentLiked = nil
  end
end

-- refresh: re-read liked state for the current track. (No async context for
-- Apple Music; just poke refreshLiked with the cached id.)
module.refresh = function()
  if currentLikedTrackId then
    module.refreshLiked(currentLikedTrackId)
  end
end

-- ---------------------------------------------------------------------------
-- Like / unlike (library tracks only)
-- ---------------------------------------------------------------------------

module.like = function(trackId)
  if not trackId then return end
  local ok = hs.osascript.applescript(
    'tell application "Music" to set favorited of current track to true'
  )
  if ok then
    currentLiked = true
    if onChange then onChange() end
  end
end

module.unlike = function(trackId)
  if not trackId then return end
  local ok = hs.osascript.applescript(
    'tell application "Music" to set favorited of current track to false'
  )
  if ok then
    currentLiked = false
    if onChange then onChange() end
  end
end

-- ---------------------------------------------------------------------------
-- Playlists
-- ---------------------------------------------------------------------------

-- Build or rebuild the playlist cache from Music's user playlists. Runs
-- synchronously (AppleScript enumeration blocks until complete).
--
-- URI scheme: "applemusic:playlist:<persistentId>". The persistent ID is the
-- stable key; playContext/addToPlaylist resolve it back to the playlist name
-- (which AppleScript plays/duplicates by).
local function buildPlaylistList()
  -- Fetch name and persistent ID together so we have a stable id even when
  -- names are duplicated. Returns tab-separated rows, newline-separated.
  local ok, result = hs.osascript.applescript([[
    tell application "Music"
      try
        set output to ""
        set pls to every user playlist
        repeat with pl in pls
          set n to name of pl
          set pid to persistent ID of pl
          set output to output & n & tab & pid & linefeed
        end repeat
        return output
      on error
        return ""
      end try
    end tell
  ]])
  local list = {}
  if ok and type(result) == "string" and result ~= "" then
    for line in result:gmatch("[^\n]+") do
      local name, pid = line:match("^([^\t]+)\t(.+)$")
      if name and pid then
        list[#list + 1] = {
          id       = pid,
          name     = name,
          owned    = true,
          uri      = "applemusic:playlist:" .. pid,
          imageUrl = nil,  -- no playlist thumbnails in v1 (matches item shape)
        }
      end
    end
  end
  return list
end

module.getPlaylists = function()
  return playlistsCache
end

module.refreshPlaylists = function(cb)
  local list = buildPlaylistList()
  playlistsCache = list
  if cb then cb(list) end
end

-- No recently-played surface for Apple Music. Return nil (matching Spotify's
-- "cold cache" contract); pill.lua guards every call with `or {}`.
module.getRecentlyPlayed    = function() return nil end
module.refreshRecentlyPlayed = function(cb) if cb then cb({}) end end

-- Add the current library track to a playlist by persistent ID.
-- Resolves the playlist name from the cache; fails closed for streaming tracks.
module.addToPlaylist = function(playlistId, trackId, cb)
  cb = cb or function() end
  if not trackId then
    -- Streaming track: no library object to duplicate.
    cb(false)
    return
  end
  -- Find the playlist name from the cache.
  local playlistName = nil
  for _, p in ipairs(playlistsCache or {}) do
    if p.id == playlistId then
      playlistName = p.name
      break
    end
  end
  if not playlistName then
    log.w("addToPlaylist: playlist id not found in cache: " .. tostring(playlistId))
    cb(false)
    return
  end
  local safeName = asQuote(playlistName)
  -- Plain library tracks duplicate straight into the playlist. Subscription /
  -- URL tracks (Apple Music catalog, autoplay, stations) error with "Can only
  -- duplicate subscription tracks to library source", so fall back to the
  -- two-step the Music UI does implicitly: add the track to the library, find
  -- the library copy (a new object; matched by name+artist since `duplicate to
  -- source` returns no reference), and duplicate THAT into the playlist.
  local script = string.format([[
    tell application "Music"
      try
        duplicate current track to user playlist "%s"
        return "OK"
      on error
        try
          set tn to name of current track
          set ta to artist of current track
          try
            duplicate current track to source "Library"
          end try -- harmless if it's already in the library
          set libT to (first track of library playlist 1 whose name is tn and artist is ta)
          duplicate libT to user playlist "%s"
          return "OK"
        on error errMsg
          return "ERROR: " & errMsg
        end try
      end try
    end tell
  ]], safeName, safeName)
  local ok, result = hs.osascript.applescript(script)
  if ok and type(result) == "string" and result == "OK" then
    cb(true)
  else
    log.w("addToPlaylist failed: " .. tostring(result))
    cb(false)
  end
end

-- ---------------------------------------------------------------------------
-- Play context
-- ---------------------------------------------------------------------------

-- Resolve playlist name from a "applemusic:playlist:<persistentId>" URI.
local function nameFromUri(uri)
  local pid = uri and uri:match("^applemusic:playlist:(.+)$")
  if not pid then return nil end
  for _, p in ipairs(playlistsCache or {}) do
    if p.id == pid then return p.name end
  end
  return nil
end

-- mode: "play" | "shuffle" | "smart"
-- Apple Music has no smart shuffle; treat "smart" == "shuffle".
module.playContext = function(uri, mode)
  if not uri then return end
  mode = mode or "play"
  local name = nameFromUri(uri)
  if not name then
    log.w("playContext: could not resolve playlist name for uri: " .. tostring(uri))
    return
  end
  local shuffleOn = mode ~= "play"
  local safeName = asQuote(name)
  local script = string.format([[
    tell application "Music"
      set shuffle enabled to %s
      play playlist named "%s"
    end tell
  ]], tostring(shuffleOn), safeName)
  hs.osascript.applescript(script)
end

-- module.playLikedSongs intentionally absent — pill.lua guards `if api.playLikedSongs`
-- so the menu item is hidden when this field is nil/absent. Apple Music has no
-- reliable AppleScript equivalent to Spotify's Liked Songs collection in v1.

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

module.start = function(changeCallback)
  onChange = changeCallback
  -- Warm the playlist cache in the background (AppleScript is synchronous
  -- but may take ~200ms on a large library; defer so the pill renders first).
  hs.timer.doAfter(0.5, function() module.refreshPlaylists() end)
end

module.stop = function()
  onChange = nil
  cachedPath = nil
  lastKnownTitle = nil
  mrSnapshot = nil
  mrTaskInFlight = false
  currentName = nil
  nameDirty = false
  -- Remove the per-track artwork files we exported this session.
  for _, path in pairs(artCache) do
    if type(path) == "string" then os.remove(path) end
  end
  artCache = {}
  libArtUrlCache = {}
  -- Remove the JXA temp file written by jxaPath() and let it be re-created.
  if type(mrJxaPath) == "string" then os.remove(mrJxaPath) end
  mrJxaPath = nil
  currentLiked = nil
  currentLikedTrackId = nil
  playlistsCache = nil
  warnedMediaRemote = false
end

module.authenticate = function(_id)
  -- No-op: Apple Music needs no OAuth or token.
end

-- Pure helpers exposed for unit tests (see tests/). Not part of the backend
-- interface pill.lua depends on. mrProgress reads hs.timer.secondsSinceEpoch,
-- which the test stub makes deterministic.
module._test = {
  calcProgress  = calcProgress,
  mrProgress    = mrProgress,
  mrState       = mrState,
  runningState  = runningState,
  asQuote       = asQuote,
  mrArtUrl      = mrArtUrl,
  parseMrOutput = parseMrOutput,
  -- Expose internal tables/flags so tests can inspect state.
  artCache       = function() return artCache end,
  libArtUrlCache = function() return libArtUrlCache end,
  mrSnapshot     = function() return mrSnapshot end,
  -- Reset per-test: clear artwork/streaming state without calling module.stop().
  resetArtState = function()
    artCache       = {}
    libArtUrlCache = {}
    mrSnapshot     = nil
    mrTaskInFlight = false
    cachedPath     = nil
    lastKnownTitle = nil
  end,
}

return module

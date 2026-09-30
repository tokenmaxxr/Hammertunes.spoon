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
-- Backend exposes the "Show Other Sources" toggle (MediaRemote is system-wide;
-- see mrSourceLabel). The Spotify backend doesn't, so the menu item is gated on
-- this capability flag.
module.supportsSourceToggle = true
-- Accent for the "liked" heart on the pill: the Apple Music pinkish-red (#FC3C44).
module.likedColor = { red = 0.988, green = 0.235, blue = 0.267 }

-- ---------------------------------------------------------------------------
-- Module-level state
-- ---------------------------------------------------------------------------

local onChange = nil

-- Two-path result cache: once we know which path works for the current track
-- (AppleScript vs MediaRemote fallback), we stay on that path until the track
-- changes. Both paths honor the configured expensive-read interval.
--
-- "as"  = AppleScript succeeded last time (library track)
-- "mr"  = MediaRemote fallback succeeded last time (streaming track)
-- nil   = unknown; probe on next call
local cachedPath = nil     -- "as" | "mr" | nil
local lastKnownIdentity = nil -- used to detect track changes and reset cachedPath

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
-- from the snapshot's timestamp/elapsed/rate, see mrProgress). The platform
-- adapter single-flights reads and cancels callbacks from obsolete requests.
local mrSnapshot = nil
local mrSnapshotAt = -math.huge
local mrShuffle = false
local warmupTimer = nil

-- Library ("as") path snapshot + throttle, mirroring the streaming path and the
-- Spotify backend. MUSIC_QUERY is a ~150 ms call (macOS recompiles the script and
-- runs an XProtect malware scan every time, plus the Apple Event round-trip), so
-- running it on every 1 Hz tick was a large energy cost. Instead we read it at
-- most once per poll.get() seconds and serve a locally-interpolated copy in
-- between; a track or play/pause change is picked up on the next real read.
-- Transport actions invalidate both snapshot timestamps for the next render.
--
-- The interval is user-configurable (right-click "Refresh interval") and shared
-- with the Spotify backend via backends/pollinterval.lua, so the choice applies
-- consistently whichever backend is active. We load that module as a sibling —
-- its path derived from this file's own location, so it resolves the same way
-- under init.lua and the test harness (both dofile backends by path).
local siblingDir = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("[^/\\]+$", "")
local poll = dofile(siblingDir .. "pollinterval.lua")
local prog = dofile(siblingDir .. "progress.lua") -- shared calcProgress / interpolate
module.getPollInterval = poll.get
module.setPollInterval = poll.set

local platform = dofile(siblingDir .. "applemusic/platform.lua")
local readMediaRemote = platform.read
local asSnapshot = nil
local asSnapshotAt = 0
local function invalidateAsSnapshot()
  asSnapshotAt = -math.huge
  mrSnapshotAt = -math.huge
  platform.cancel()
end

-- MediaRemote reports system-wide Now Playing, so in Apple Music mode it also
-- sees browsers, Spotify, etc. By default we show only Apple Music's own media;
-- the user can opt into mirroring other apps via the right-click toggle (see
-- mrSourceLabel). Spotify is always excluded — it has its own backend, so
-- mirroring it under Apple Music would just be a confusing duplicate.
local MUSIC_BUNDLE = "com.apple.Music"
local SPOTIFY_BUNDLE = "com.spotify.client"
local SHOW_OTHER_SOURCES_KEY = "Hammertunes.applemusic.showOtherSources"
local showOtherSources = false

-- Reset the now-playing caches and report the app as not running. Used wherever
-- getState() determines Music isn't running.
local function notRunning()
  platform.cancel()
  cachedPath = nil
  lastKnownIdentity = nil
  mrSnapshot = nil
  asSnapshot = nil
  mrSnapshotAt = -math.huge
  currentLiked, currentLikedTrackId = nil, nil
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
    sourceBundleId = MUSIC_BUNDLE, sourceName = "Music",
    canControl = true, canSeek = false, canLike = false, canAddToPlaylist = false,
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

-- Refresh policy lives here; the platform adapter owns subprocess lifetime.
local function refreshMrSnapshot()
  local now = hs.timer.secondsSinceEpoch()
  if now - mrSnapshotAt < poll.get() then return false end
  mrSnapshotAt = now
  platform.readAsync(function(snapshot) mrSnapshot = snapshot end)
  return true
end

-- Titles are not identities: different artists and albums routinely reuse them.
local function mrIdentity(data)
  return table.concat({data.bundleId or "", data.title or "", data.artist or "",
    data.album or "", tostring(data.duration or "")}, "\0")
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

-- Decide whether a MediaRemote snapshot should drive the Apple Music pill, and
-- what source label (if any) to show alongside it. Returns (accepted, label):
--   * Apple Music            -> accepted, no label (it IS the backend's app)
--   * Spotify                -> rejected always (has its own backend)
--   * any other app          -> accepted only when showOtherSources is on, and
--                               labelled with the app name so it reads clearly
--                               as a foreign source, not an Apple Music track
--   * unknown (no bundleId)  -> accepted, no label (fail open: a read that
--                               couldn't resolve the owner is almost always
--                               Music itself, so don't hide a real track)
local function mrSourceLabel(mrData)
  local bundle = mrData and mrData.bundleId
  if bundle == nil or bundle == MUSIC_BUNDLE then return true, nil end
  if bundle == SPOTIFY_BUNDLE then return false, nil end
  if showOtherSources then return true, (mrData.appName or "another app") end
  return false, nil
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
-- calcProgress and interpolate (the library-path snapshot advance) live in the
-- shared backends/progress.lua (loaded as `prog` above), used by both backends.

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
  return durMs, prog.calcProgress(elapsed, durMs)
end

-- Build the state table for a MediaRemote (streaming) track. Streaming tracks
-- have no library trackId, so no library actions and no local artPath; the
-- cover is always the MediaRemote URL (artUrl) or nothing.
--
-- Source identity and available actions stay separate from track metadata so
-- copying an artist name never includes a presentation-only source label.
local function mrState(mrData, shuffle, artUrl, source)
  local durMs, progress = mrProgress(mrData)
  local title = mrData.title
  local artist = (mrData.artist ~= "" and mrData.artist) or nil
  return {
    running  = true,
    playing  = (tonumber(mrData.rate) or 0) > 0,
    track    = (title ~= "" and title) or nil,
    artist   = artist,
    progress = progress,
    durMs    = durMs,
    artUrl   = artUrl,
    artPath  = nil,
    trackId  = nil,
    shuffle  = shuffle,
    sourceBundleId = mrData.bundleId,
    sourceName = source or mrData.appName or (mrData.bundleId == MUSIC_BUNDLE and "Music" or nil),
    canControl = mrData.bundleId == MUSIC_BUNDLE,
    canSeek = mrData.bundleId == MUSIC_BUNDLE and durMs > 0,
    canLike = false,
    canAddToPlaylist = false,
  }
end

-- ---------------------------------------------------------------------------
-- AppleScript helpers
-- ---------------------------------------------------------------------------

-- Escape a string for embedding inside an AppleScript double-quoted literal.
-- Backslash first, then the quote, so playlist names with either survive.
local function asQuote(s) return (s:gsub('\\', '\\\\'):gsub('"', '\\"')) end

-- A bare `tell application "Music"` LAUNCHES Music — even while it's mid-quit,
-- which is how a 1 Hz poller (or a menu refresh) ends up fighting the user's
-- Cmd-Q and relaunching the app behind their back. So every script that fires
-- on its own (polling, menu refresh, startup warm-up) wraps its tell in a
-- running-guard: the tell runs only when Music is already up, otherwise the
-- script returns notRunningResult without touching the app. The in-script guard
-- (vs. a Lua-side hs.application.get check) is the relaunch-safe one — it holds
-- even during the quit window. MUSIC_QUERY / SHUFFLE_QUERY inline the same shape.
local function tellMusic(body, notRunningResult)
  return string.format(
    'if application "Music" is running then\n'
      .. 'tell application "Music"\n%s\nend tell\n'
      .. 'else\nreturn %s\nend if',
    body, notRunningResult)
end

-- name of current playlist, "" when absent or Music closed (tooltip context).
local NAME_SCRIPT = tellMusic([[
  try
    return name of current playlist
  on error
    return ""
  end try]], '""')

-- Database IDs are numeric Apple Music library identities, never script text.
local function trackReference(trackId)
  local id = tonumber(trackId)
  if not id or id <= 0 or id % 1 ~= 0 then return nil end
  return "(first track of library playlist 1 whose database ID is " .. string.format("%.0f", id) .. ")"
end

local function playlistReference(playlistId)
  if type(playlistId) ~= "string" or playlistId == "" then return nil end
  return '(first user playlist whose persistent ID is "' .. asQuote(playlistId) .. '")'
end

-- Tab/linefeed-separated "<name>\t<persistentId>" rows, "" when Music closed.
local PLAYLISTS_SCRIPT = tellMusic([[
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
  end try]], '""')

-- ---------------------------------------------------------------------------
-- getState() — the hot path, called at 1 Hz by pill.lua
-- ---------------------------------------------------------------------------

module.getState = function()
  -- Fast path: is Music running at all? Use applicationsForBundleID, NOT
  -- hs.application.get("Music"): the by-name lookup costs ~27 ms/call (it scans
  -- every running app), and this runs on every 1 Hz tick — that alone was ~2%
  -- constant CPU while Music was closed. The bundle-ID lookup is ~0.01 ms.
  if #hs.application.applicationsForBundleID(MUSIC_BUNDLE) == 0 then
    return notRunning()
  end

  -- Throttle the library path: serve an interpolated copy of the last "as" read
  -- between polls (see asSnapshot). Only the steady "as" path is throttled here;
  -- the "mr" path below refreshes asynchronously at the same interval.
  local now = hs.timer.secondsSinceEpoch()
  local elapsed = now - asSnapshotAt
  if cachedPath == "as" and asSnapshot and elapsed < poll.get() then
    return prog.interpolate(asSnapshot, elapsed)
  end

  -- Try the AppleScript library path first (or immediately if it succeeded
  -- last time). cachedPath == "as" means we expect this to work.
  if cachedPath ~= "mr" then
    local ok, result = platform.readLibrary()
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
        local progress = prog.calcProgress(tonumber(posSec) or 0, durMs)

        cachedPath = "as"
        -- Track-change detection: refresh the cached context name on change.
        if trackId ~= lastKnownIdentity then
          lastKnownIdentity = trackId
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

        local st = {
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
          sourceBundleId = MUSIC_BUNDLE,
          sourceName = "Music",
          canControl = true,
          canSeek = durMs > 0,
          canLike = trackId ~= nil,
          canAddToPlaylist = trackId ~= nil,
        }
        asSnapshot = st
        asSnapshotAt = now
        return st

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
        -- path serves so it has data before the first async refresh lands. We
        -- pin "mr" even for a rejected foreign source, so the steady path serves
        -- "idle" cheaply instead of re-running this blocking read every tick.
        cachedPath = "mr"
        mrSnapshot = mrData
        mrSnapshotAt = now
        mrShuffle = shuffleStr == "true"

        if mrIdentity(mrData) ~= lastKnownIdentity then
          lastKnownIdentity = mrIdentity(mrData)
          nameDirty = true
          -- Streaming track: clear liked since we have no trackId.
          currentLiked = nil
          currentLikedTrackId = nil
        end
        -- Gate on the now-playing source: Apple Music shows; a browser/other app
        -- shows only when the user opted in (labelled); Spotify never shows.
        local accepted, source = mrSourceLabel(mrData)
        if not accepted then
          return runningState(playerState == "playing", shuffleStr == "true")
        end
        return mrState(mrData, shuffleStr == "true", mrArtUrl(mrData), source)
      end
    end
    -- AppleScript call itself failed (ok == false). Could be a transient
    -- error; don't cache anything, just return a minimal running state.
    return runningState(false, false)
  end

  -- cachedPath == "mr": we know the current track is streaming. Kick a
  -- background MediaRemote refresh (non-blocking) and serve the last snapshot,
  -- so the 1 Hz tick never blocks on the ~150 ms subprocess. Shuffle is read
  -- at the same interval; progress is interpolated locally in mrProgress, so a
  -- cached snapshot still shows a smoothly advancing bar.
  if refreshMrSnapshot() then mrShuffle = platform.readShuffle() end
  local mrData = mrSnapshot

  if not mrData then
    -- MediaRemote went dark mid-track (or the async read failed). Without a
    -- title a track change can't be detected, so drop the path cache and let
    -- the next tick re-probe AppleScript - self-healing.
    cachedPath = nil
    return runningState(false, mrShuffle)
  end

  -- Detect track change by source and metadata, then re-probe on the next tick (which
  -- goes through the FALLBACK path and a fresh synchronous read).
  if mrIdentity(mrData) ~= lastKnownIdentity then
    lastKnownIdentity = mrIdentity(mrData)
    cachedPath = nil
    nameDirty = true
    currentLiked = nil
    currentLikedTrackId = nil
  end

  -- Apply the source preference independently of the cached read schedule.
  local accepted, source = mrSourceLabel(mrData)
  if not accepted then
    return runningState(false, false)
  end
  return mrState(mrData, mrShuffle, mrArtUrl(mrData), source)
end

-- ---------------------------------------------------------------------------
-- Transport — delegates to hs.itunes.* (targets the Music app)
-- ---------------------------------------------------------------------------

-- Transport mutators invalidate the cached snapshot so the change shows on the
-- next render rather than after the poll interval (see invalidateAsSnapshot).
local function controlsMusic()
  if not mrSnapshot or cachedPath == "as" then return true end
  -- A rejected source displays the empty Music state, whose transport still
  -- belongs to Music. Only accepted foreign/unknown media is display-only.
  local accepted = mrSourceLabel(mrSnapshot)
  return not accepted or mrSnapshot.bundleId == MUSIC_BUNDLE
end
local function transport(action, ...)
  if not controlsMusic() then return end
  hs.itunes[action](...)
  invalidateAsSnapshot()
end
module.next        = function() transport("next") end
module.previous    = function() transport("previous") end
module.playpause   = function() transport("playpause") end
module.play        = function() transport("play") end
module.getPosition = function() if controlsMusic() then return hs.itunes.getPosition() end end
module.setPosition = function(sec) transport("setPosition", sec) end

-- Music's shuffle property is `shuffle enabled` (a boolean). Note: Music also
-- has `song repeat` (off/one/all); we don't touch that here.
module.setShuffling = function(on)
  if not controlsMusic() then return end
  hs.osascript.applescript(
    'tell application "Music" to set shuffle enabled to ' .. tostring(on)
  )
  invalidateAsSnapshot()
  -- pill.lua schedules its own re-render; no need to call onChange here.
end

-- "Show Other Sources" toggle: whether MediaRemote media owned by apps other
-- than Apple Music (browsers, etc.; never Spotify) may drive the pill. Persisted
-- across reloads via hs.settings. Backs the right-click menu's checkable item.
module.getShowOtherSources = function() return showOtherSources end

module.setShowOtherSources = function(on)
  showOtherSources = not not on
  if hs.settings then hs.settings.set(SHOW_OTHER_SOURCES_KEY, showOtherSources) end
  -- Re-probe next tick so the change takes effect immediately rather than after
  -- the current track ends (the "mr" path would otherwise serve its decision).
  cachedPath = nil
  lastKnownIdentity = nil
  platform.cancel()
  mrSnapshotAt = -math.huge
end

-- ---------------------------------------------------------------------------
-- Context
-- ---------------------------------------------------------------------------

-- getName: name of the current playlist, or nil. Best-effort, tooltip-only.
-- Re-reads `name of current playlist` only when getState() flags a track
-- change (nameDirty); otherwise returns the cached value so the 1 Hz render
-- loop doesn't spend an osascript on it every tick.
module.getName = function()
  if not controlsMusic() then return nil end
  if not nameDirty then return currentName end
  nameDirty = false
  local ok, result = hs.osascript.applescript(NAME_SCRIPT)
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
  local ref = trackReference(trackId)
  if not ref then currentLiked = nil; return end
  local ok, result = hs.osascript.applescript(tellMusic(
    "try\nreturn favorited of " .. ref .. ' as text\non error\nreturn "nil"\nend try', '"nil"'))
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

local function setLiked(trackId, liked)
  local ref = trackReference(trackId)
  if not ref then return end
  local ok = hs.osascript.applescript(tellMusic(
    "set favorited of " .. ref .. " to " .. tostring(liked), "false"))
  if ok then
    if trackId == currentLikedTrackId then currentLiked = liked end
    asSnapshotAt = -math.huge
    if onChange then onChange() end
  end
end
module.like = function(trackId) setLiked(trackId, true) end
module.unlike = function(trackId) setLiked(trackId, false) end

-- ---------------------------------------------------------------------------
-- Playlists
-- ---------------------------------------------------------------------------

-- Build or rebuild the playlist cache from Music's user playlists. Runs
-- synchronously (AppleScript enumeration blocks until complete).
--
-- URI scheme: "applemusic:playlist:<persistentId>". The persistent ID is the
-- stable key; playContext/addToPlaylist resolve the playlist directly by ID.
local function buildPlaylistList()
  -- Fetch name and persistent ID together so we have a stable id even when
  -- names are duplicated. Returns tab-separated rows, newline-separated.
  local ok, result = hs.osascript.applescript(PLAYLISTS_SCRIPT)
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

-- Captured IDs keep menu actions attached to the selected track and playlist,
-- even if playback changes or two playlists have the same display name.
module.addToPlaylist = function(playlistId, trackId, cb)
  cb = cb or function() end
  local track = trackReference(trackId)
  local playlist = playlistReference(playlistId)
  if not track or not playlist then cb(false); return end
  local script = tellMusic("try\nduplicate " .. track .. " to " .. playlist
    .. '\nreturn "OK"\non error errMsg\nreturn "ERROR: " & errMsg\nend try', '"ERROR"')
  local ok, result = hs.osascript.applescript(script)
  if not ok or result ~= "OK" then
    -- Subscription tracks may only duplicate to the Library source initially.
    -- Keep the returned object, or resolve its captured persistent identity if
    -- Music supplies no reference. Never guess by display name or current track.
    local fallback = string.format([[
      try
        set selectedTrack to %s
        set selectedPlaylist to %s
        set selectedPersistentID to persistent ID of selectedTrack
        set importedTrack to missing value
        try
          set importedTrack to duplicate selectedTrack to source "Library"
        end try
        if importedTrack is missing value then
          set importedTrack to (first track of library playlist 1 whose persistent ID is selectedPersistentID)
        end if
        duplicate importedTrack to selectedPlaylist
        return "OK"
      on error errMsg
        return "ERROR: " & errMsg
      end try
    ]], track, playlist)
    ok, result = hs.osascript.applescript(tellMusic(fallback, '"ERROR"'))
  end
  cb(ok and result == "OK")
end

-- mode: "play" | "shuffle" | "smart"; Music has no smart shuffle.
module.playContext = function(uri, mode)
  local pid = type(uri) == "string" and uri:match("^applemusic:playlist:(.+)$")
  local playlist = playlistReference(pid)
  if not playlist then return end
  local script = 'tell application "Music"\nset shuffle enabled to '
    .. tostring((mode or "play") ~= "play") .. "\nplay " .. playlist .. "\nend tell"
  hs.osascript.applescript(script)
  invalidateAsSnapshot()
  cachedPath = nil
  mrSnapshot = nil
end

-- module.playLikedSongs intentionally absent — pill.lua guards `if api.playLikedSongs`
-- so the menu item is hidden when this field is nil/absent. Apple Music has no
-- reliable AppleScript equivalent to Spotify's Liked Songs collection in v1.

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

module.start = function(changeCallback)
  onChange = changeCallback
  poll.load()
  -- Restore the persisted "Show Other Sources" preference (default off).
  if hs.settings then showOtherSources = hs.settings.get(SHOW_OTHER_SOURCES_KEY) == true end
  -- Warm the playlist cache in the background (AppleScript is synchronous
  -- but may take ~200ms on a large library; defer so the pill renders first).
  if warmupTimer then warmupTimer:stop() end
  local pending = {}
  warmupTimer = pending
  local timer = hs.timer.doAfter(0.5, function()
    if warmupTimer ~= pending then return end
    warmupTimer = nil
    module.refreshPlaylists()
  end)
  if warmupTimer == pending then
    pending.stop = function() timer:stop() end
  end
end

module.stop = function()
  if warmupTimer then warmupTimer:stop(); warmupTimer = nil end
  onChange = nil
  cachedPath = nil
  lastKnownIdentity = nil
  mrSnapshot = nil
  asSnapshot = nil
  asSnapshotAt = 0
  mrSnapshotAt = -math.huge
  currentName = nil
  nameDirty = false
  -- Remove the per-track artwork files we exported this session.
  for _, path in pairs(artCache) do
    if type(path) == "string" then os.remove(path) end
  end
  artCache = {}
  libArtUrlCache = {}
  platform.stop()
  currentLiked = nil
  currentLikedTrackId = nil
  playlistsCache = nil
end

module.authenticate = function(_id)
  -- No-op: Apple Music needs no OAuth or token.
end

-- Pure helpers exposed for unit tests (see tests/). Not part of the backend
-- interface pill.lua depends on. mrProgress reads hs.timer.secondsSinceEpoch,
-- which the test stub makes deterministic.
module._test = {
  calcProgress  = prog.calcProgress,
  mrProgress    = mrProgress,
  interpolateAsState = prog.interpolate,
  mrState       = mrState,
  runningState  = runningState,
  asQuote       = asQuote,
  mrArtUrl      = mrArtUrl,
  mrSourceLabel = mrSourceLabel,
  parseMrOutput = platform.parse,
  -- Expose internal tables/flags so tests can inspect state.
  artCache       = function() return artCache end,
  libArtUrlCache = function() return libArtUrlCache end,
  mrSnapshot     = function() return mrSnapshot end,
  -- Reset per-test: clear artwork/streaming state without calling module.stop().
  resetArtState = function()
    artCache        = {}
    libArtUrlCache  = {}
    mrSnapshot      = nil
    asSnapshot      = nil
    asSnapshotAt    = 0
    platform.cancel()
    mrSnapshotAt = -math.huge
    cachedPath      = nil
    lastKnownIdentity  = nil
    showOtherSources = false
  end,
}

return module

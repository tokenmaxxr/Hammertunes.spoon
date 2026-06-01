local module = {}
local log = hs.logger.new("hammertunes", "info")
-- badge (renderer) and api (backend) are injected by init.lua via
-- module.start{ badge=..., api=... } so this file carries no require() path
-- assumptions. Declared here as upvalues the closures below close over.
local badge = nil

local MAX_TRACK = 15
local MAX_ARTIST = 18
local DOUBLE_CLICK_SEC = 0.25
-- Fraction of the pill width on each side that triggers prev/next.
-- Middle (1 - 2*SIDE_ZONE_FRAC) is play/pause + copy.
local SIDE_ZONE_FRAC = 0.2
-- Left-zone click restarts the song if more than this many seconds have elapsed,
-- otherwise goes to the previous track. Matches typical music player behavior.
local RESTART_THRESHOLD_SEC = 3
-- Quantize progress so the 1Hz render cache hits during playback.
-- Without this, progress advances ~0.5% per tick and invalidates the cache every time.
local PILL_PROGRESS_STEPS = 20
-- Press-and-hold longer than this seeks to the mouse-relative position in the pill.
local HOLD_THRESHOLD_SEC = 0.4
-- Minimum interval between scrub seeks while dragging. AppleScript setPosition calls
-- are synchronous, so keep this loose enough to stay responsive without backing up.
local SEEK_THROTTLE_SEC = 0.1
local PILL_OPTS = {
  radius = 6,
  padX = 8,
  bg = { red = 0, green = 0, blue = 0, alpha = 0.45 },
  progressBg = { red = 0, green = 0, blue = 0, alpha = 0.7 },
}

-- Context URIs that collapse the pill to "♪" (e.g. playlists you'd rather not
-- advertise in the menubar). Populated from config via module.start{ hiddenContexts = {...} }.
local HIDDEN_CONTEXT_URIS = {}

-- Tab-separated so song/artist names containing "|" don't break parsing.
local SPOTIFY_QUERY = [[
if application "Spotify" is running then
  tell application "Spotify"
    set s to player state as text
    set sh to shuffling as text
    try
      return s & tab & (name of current track) & tab & (artist of current track) & tab & (player position) & tab & (duration of current track) & tab & (artwork url of current track) & tab & (id of current track) & tab & sh
    on error
      return s & tab & tab & tab & "0" & tab & "0" & tab & tab & sh
    end try
  end tell
else
  return ""
end if
]]

local menu = nil
local pill = nil
local timer = nil
local pendingClick = nil
local lastTooltip = nil
local lastTrack = nil
local lastArtist = nil
local lastTrackId = nil
local lastDurMs = 0
local holdTimer = nil
local holdFired = false
local lastSeekTime = 0
local mouseDownWatcher = nil
local lastPlaying = false
local lastShuffle = false
local lastRunning = false

-- hs.menubar:frame() converts Cocoa coords using mainScreen (the focused
-- screen), but _frame() coordinates are anchored to the primary display.
-- When another display has focus and its height differs, the Y is wrong.
local function menuFrame()
  local f = menu and menu:_frame()
  if not f or f.w <= 0 then return nil end
  local sf = hs.screen.primaryScreen():fullFrame()
  f.y = sf.h - f.y - f.h
  return hs.geometry(f)
end
local MAX_ART_CACHE = 50
local artCache = {}
local artCacheCount = 0
local artFetching = {}

-- Separate cache for right-click menu thumbnails: same cover URLs, but scaled
-- down to menu-row size and held as ready hs.image objects. The popup menu is
-- built synchronously and popupMenu blocks, so icons must already be cached
-- when the menu opens — these are pre-warmed from render().
local MENU_ICON_SIZE = 18
local MENU_PLAYLIST_LIMIT = 25
local MAX_MENU_ICON_CACHE = 100
local menuIconCache = {}
local menuIconCacheCount = 0
local menuIconFetching = {}

-- Backend (Web API extras: context name, liked-state, playlists). Injected by
-- module.start. Currently always the Spotify backend; Apple Music will slot in
-- here once state/transport are abstracted behind the same interface.
local api = nil

local function truncate(s, max)
  if not s then return "" end
  local len = utf8.len(s) or #s
  if len <= max then return s end
  local cut = utf8.offset(s, max)
  return s:sub(1, cut - 1) .. "…"
end

local function isHiddenContext(uri)
  return uri ~= nil and HIDDEN_CONTEXT_URIS[uri] == true
end

-- Modifier → playback mode for the right-click "Play" items.
-- ⌘⌥ click = smart shuffle, ⌘ click = shuffle, plain = play.
local function playMode(mods)
  if mods and mods.cmd and mods.alt then return "smart" end
  if mods and mods.cmd then return "shuffle" end
  return "play"
end

local function fetchState()
  local ok, result = hs.osascript.applescript(SPOTIFY_QUERY)
  if not ok or type(result) ~= "string" or result == "" then
    return { running = false }
  end
  local state, track, artist, pos, dur, artUrl, trackUri, shuffle =
    result:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
  local posSec = tonumber(pos) or 0
  local durMs = tonumber(dur) or 0
  local progress = 0
  if durMs > 0 then
    progress = math.max(0, math.min(1, posSec / (durMs / 1000)))
  end
  -- Bare ID only — Web API endpoints (/v1/me/tracks*) want the ID, not the URI.
  -- Local files come through as "spotify:local:..." which the API rejects, so
  -- limit to real track IDs.
  local trackId = trackUri and trackUri:match("^spotify:track:(.+)$") or nil
  return {
    running = true,
    playing = state == "playing",
    track = track ~= "" and track or nil,
    artist = artist ~= "" and artist or nil,
    progress = progress,
    durMs = durMs,
    artUrl = artUrl ~= "" and artUrl or nil,
    trackId = trackId,
    shuffle = shuffle == "true",
  }
end

local render
local function ensureArt(url)
  if not url then return nil end
  local cached = artCache[url]
  if cached ~= nil then return cached end
  if artFetching[url] then return nil end
  artFetching[url] = true
  hs.http.asyncGet(url, nil, function(code, body)
    artFetching[url] = nil
    local img = nil
    if code == 200 and body then
      local path = os.tmpname()
      local f = io.open(path, "wb")
      if f then
        f:write(body)
        f:close()
        img = hs.image.imageFromPath(path)
        os.remove(path)
      end
    end
    if artCacheCount >= MAX_ART_CACHE then
      artCache, artCacheCount = {}, 0
    end
    artCache[url] = img or false
    artCacheCount = artCacheCount + 1
    if img and render then render() end
  end)
  return nil
end

-- Resize via canvas, not hs.image:setSize. A setSize'd file-backed image won't
-- draw as a menu-item icon (verified: a system image and the full-size file
-- image both render, but the setSize copy shows nothing). Drawing into a canvas
-- yields a fresh bitmap that renders like the pill's own canvas icon.
local function scaleToMenuIcon(img)
  local c = hs.canvas.new({ x = 0, y = 0, w = MENU_ICON_SIZE, h = MENU_ICON_SIZE })
  c:appendElements({
    type = "image",
    image = img,
    imageScaling = "scaleToFit",
    frame = { x = 0, y = 0, w = MENU_ICON_SIZE, h = MENU_ICON_SIZE },
  })
  local out = c:imageFromCanvas()
  c:delete()
  return out
end

-- Returns a cached, menu-sized hs.image for a cover URL, or nil if not ready.
-- On a miss it kicks off an async fetch and caches the scaled result (or false
-- for a known failure) so a later menu open can use it. No render callback —
-- the menu can't be updated while it's open, so freshly-fetched icons simply
-- show up on the next right-click.
local function ensureMenuIcon(url)
  if not url then return nil end
  local cached = menuIconCache[url]
  if cached ~= nil then return cached or nil end
  if menuIconFetching[url] then return nil end
  menuIconFetching[url] = true
  hs.http.asyncGet(url, nil, function(code, body)
    menuIconFetching[url] = nil
    local img = nil
    if code == 200 and body then
      local path = os.tmpname()
      local f = io.open(path, "wb")
      if f then
        f:write(body)
        f:close()
        img = hs.image.imageFromPath(path)
        os.remove(path)
      end
    end
    if img then img = scaleToMenuIcon(img) end
    if menuIconCacheCount >= MAX_MENU_ICON_CACHE then
      menuIconCache, menuIconCacheCount = {}, 0
    end
    menuIconCache[url] = img or false
    menuIconCacheCount = menuIconCacheCount + 1
  end)
  return nil
end

-- Warm the menu-icon cache for every known playlist so the first right-click
-- already has thumbnails. Cheap once warm: ensureMenuIcon short-circuits on
-- cached/in-flight URLs, so this is just table lookups after the initial fetch.
local function prewarmMenuIcons()
  if not api then return end
  local pls = api.getPlaylists()
  if pls then
    for _, p in ipairs(pls) do ensureMenuIcon(p.imageUrl) end
  end
  local recent = api.getRecentlyPlayed()
  if recent then
    for _, r in ipairs(recent) do ensureMenuIcon(r.imageUrl) end
  end
end

local function setBadge(text, progress, subtitle, artUrl, liked)
  local art = ensureArt(artUrl)
  pill.update(text, {
    progress = progress,
    subtitle = subtitle,
    leadingImage = art or nil,
    leadingImageKey = art and artUrl or nil,
    likedOverlay = liked == true and art ~= nil,
  })
end

local function setTooltip(text)
  if text == lastTooltip then return end
  lastTooltip = text
  menu:setTooltip(text)
end

render = function()
  local s = fetchState()
  if api and s.track and (s.track ~= lastTrack or (s.playing and not lastPlaying)) then
    api.refresh()
  end
  if api and s.trackId ~= lastTrackId then
    api.refreshLiked(s.trackId)
  end
  lastTrack = s.track
  lastArtist = s.artist
  lastTrackId = s.trackId
  lastDurMs = s.durMs or 0
  lastPlaying = s.playing or false
  lastShuffle = s.shuffle or false
  lastRunning = s.running or false
  prewarmMenuIcons()
  local ctxUri = api and api.getUri() or nil
  local ctxName = api and api.getName() or nil
  if not s.running or isHiddenContext(ctxUri) then
    setBadge("♪")
    setTooltip("Spotify not running")
    return
  end
  if s.track then
    local icon = s.playing and "⏸" or "▶"
    local main = icon .. "\u{2002}" .. truncate(s.track, MAX_TRACK)
    local subtitle = s.artist and truncate(s.artist, MAX_ARTIST) or nil
    local liked = api and api.getLiked() == true
    setBadge(main, s.progress, subtitle, s.artUrl, liked)
  else
    setBadge("♪")
  end
  -- Tooltips have no padding control; fake margins with blank lines/leading spaces.
  local PAD = "  "
  local lines = {}
  if s.track then lines[#lines + 1] = PAD .. "🎵\u{2002}" .. s.track end
  if s.artist then lines[#lines + 1] = PAD .. "👤\u{2002}" .. s.artist end
  if ctxName then lines[#lines + 1] = PAD .. "💿\u{2002}" .. ctxName end
  if #lines == 0 then setTooltip("Spotify") return end
  setTooltip("\n" .. table.concat(lines, "\n\n") .. "\n")
end

local function copyCurrent()
  if not (lastTrack and lastArtist) then return end
  local text = lastTrack .. " by " .. lastArtist
  hs.pasteboard.setContents(text)
  hs.alert.show("📋 " .. text, {}, 2)
end

-- Spotify's AppleScript state lags mutating commands; refresh shortly after they fire.
local function scheduleRender()
  hs.timer.doAfter(0.2, render)
end

-- AppleScript toggles shuffle on the local app synchronously and without Web API
-- auth. It can't exit Spotify's real Smart Shuffle (a platform limitation), which
-- the menu reflects by showing Smart Shuffle as read-only.
local function setShuffling(on)
  hs.osascript.applescript('tell application "Spotify" to set shuffling to ' .. tostring(on))
  scheduleRender()
end

local function clearPending()
  if pendingClick then
    pendingClick:stop()
    pendingClick = nil
  end
end

local function cancelHold()
  if holdTimer then
    holdTimer:stop()
    holdTimer = nil
  end
end

local function seekToMouse()
  local frame = menuFrame()
  if not frame or frame.w <= 0 or lastDurMs <= 0 then return end
  local relX = hs.mouse.absolutePosition().x - frame.x
  local ratio = math.max(0, math.min(1, relX / frame.w))
  hs.spotify.setPosition(ratio * (lastDurMs / 1000))
  lastSeekTime = hs.timer.secondsSinceEpoch()
end

local function onLeftClick()
  clearPending()
  local pos = hs.spotify.getPosition() or 0
  if pos > RESTART_THRESHOLD_SEC then
    hs.spotify.setPosition(0)
  else
    hs.spotify.previous()
  end
  scheduleRender()
end

local function onRightClick()
  clearPending()
  hs.spotify.next()
  scheduleRender()
end

local function onMiddleClick()
  if pendingClick then
    pendingClick:stop()
    pendingClick = nil
    copyCurrent()
    return
  end
  pendingClick = hs.timer.doAfter(DOUBLE_CLICK_SEC, function()
    pendingClick = nil
    hs.spotify.playpause()
    scheduleRender()
  end)
end

-- Current shuffle mode for the right-click menu. Regular on/off comes from the
-- 1Hz AppleScript poll (lastShuffle); "smart" is read-only via the Web API.
local function shuffleState()
  if api and api.getSmartShuffle() == true then return "smart" end
  return lastShuffle and "on" or "off"
end

local SHUFFLE_LABELS = { off = "Shuffle: Off", on = "Shuffle: On", smart = "Shuffle: Smart" }

local function shuffleMenuItems()
  local st = shuffleState()
  local items = {
    { title = "Off", checked = st == "off", fn = function() setShuffling(false) end },
    { title = "Shuffle", checked = st == "on", fn = function() setShuffling(true) end },
  }
  -- Spotify owns Smart Shuffle; the API reads it but can't set it, so show it
  -- disabled (checked only when active) whenever the Web API is wired up.
  if api then
    items[#items + 1] = { title = "Smart Shuffle", checked = st == "smart", disabled = true }
  end
  return items
end

-- setMenu and setClickCallback are mutually exclusive on hs.menubar, so we
-- attach the menu just for the popup and detach it right after. popupMenu is
-- blocking, so the setMenu(nil) only fires once the user dismisses the menu.
local function showRightClickMenu()
  if not menu then return end
  -- Refresh smart-shuffle state for the *next* open; popupMenu is blocking, so
  -- this async result can't reach the menu we're about to build.
  if api then api.refresh() end
  local items = {
    { title = "Open Spotify", fn = function() hs.application.launchOrFocus("Spotify") end },
  }
  if lastRunning then
    items[#items + 1] = { title = SHUFFLE_LABELS[shuffleState()], menu = shuffleMenuItems() }
  end
  if api and lastTrackId then
    local liked = api.getLiked()
    local trackId = lastTrackId
    -- nil happens during the auth/first-fetch race; default to Like and kick
    -- off a refresh so the next open shows the right verb.
    if liked == true then
      items[#items + 1] = {
        title = "Unlike",
        fn = function() api.unlike(trackId); scheduleRender() end,
      }
    else
      if liked == nil then api.refreshLiked(trackId) end
      items[#items + 1] = {
        title = "Like",
        fn = function() api.like(trackId); scheduleRender() end,
      }
    end
    local playlists = api.getPlaylists() or {}
    -- Add to Playlist: only playlists you own — you can't add tracks to ones
    -- you merely follow.
    local owned = {}
    for _, p in ipairs(playlists) do
      if p.owned then owned[#owned + 1] = p end
    end
    if #owned > 0 then
      local subItems = {}
      for _, p in ipairs(owned) do
        if #subItems >= MENU_PLAYLIST_LIMIT then break end
        local pid, pname = p.id, p.name
        subItems[#subItems + 1] = {
          title = pname,
          image = ensureMenuIcon(p.imageUrl),
          fn = function()
            api.addToPlaylist(pid, trackId, function(ok)
              hs.alert.show(ok and ("Added to " .. pname) or ("Failed to add to " .. pname))
            end)
          end,
        }
      end
      items[#items + 1] = { title = "Add to Playlist", menu = subItems }
    end
    items[#items + 1] = { title = "-" }
    if api.playLikedSongs then
      items[#items + 1] = {
        title = "Play Liked Songs",
        fn = function(mods) api.playLikedSongs(playMode(mods)) end,
      }
    end
    -- Play Playlist: recently-played pinned on top in recency order (this is
    -- where Discover Weekly / Release Radar surface when you don't follow them),
    -- then the rest of the library, deduped by id.
    local recent = api.getRecentlyPlayed() or {}
    local pinned = {}
    local playItems = {}
    for _, r in ipairs(recent) do
      if #playItems >= MENU_PLAYLIST_LIMIT then break end
      pinned[r.id] = true
      local ruri = r.uri
      playItems[#playItems + 1] = {
        title = r.name or r.uri,
        image = ensureMenuIcon(r.imageUrl),
        fn = function(mods) api.playContext(ruri, playMode(mods)) end,
      }
    end
    for _, p in ipairs(playlists) do
      if #playItems >= MENU_PLAYLIST_LIMIT then break end
      if not pinned[p.id] then
        local puri = "spotify:playlist:" .. p.id
        playItems[#playItems + 1] = {
          title = p.name,
          image = ensureMenuIcon(p.imageUrl),
          fn = function(mods) api.playContext(puri, playMode(mods)) end,
        }
      end
    end
    if #playItems > 0 then
      items[#items + 1] = { title = "Play Playlist", menu = playItems }
    end
    api.refreshPlaylists()
    api.refreshRecentlyPlayed()
  end
  if api then
    items[#items + 1] = { title = "-" }
    items[#items + 1] = { title = "Re-authenticate", fn = function() api.authenticate() end }
  end
  menu:setMenu(items)
  menu:popupMenu(hs.mouse.absolutePosition(), true)
  menu:setMenu(nil)
end

local function onClick()
  cancelHold()
  if holdFired then
    holdFired = false
    scheduleRender()
    return
  end

  local frame = menuFrame()
  if not frame or frame.w <= 0 then
    onMiddleClick()
    return
  end

  local relX = hs.mouse.absolutePosition().x - frame.x
  if relX < frame.w * SIDE_ZONE_FRAC then
    onLeftClick()
  elseif relX >= frame.w * (1 - SIDE_ZONE_FRAC) then
    onRightClick()
  else
    onMiddleClick()
  end
end

module.start = function(deps)
  deps = deps or {}
  badge = deps.badge
  api = deps.api
  for _, uri in ipairs(deps.hiddenContexts or {}) do HIDDEN_CONTEXT_URIS[uri] = true end
  -- autosaveName lets macOS remember this pill's position (⌘-drag) across reloads.
  menu = hs.menubar.new(true, "hammertunes")
  if not menu then
    log.e("hs.menubar.new() returned nil — cannot create menubar item")
    return
  end
  menu:setTitle("")
  menu:setClickCallback(onClick)
  pill = badge.new(menu, PILL_OPTS, { progressSteps = PILL_PROGRESS_STEPS })
  render()
  timer = hs.timer.doEvery(1, render):start()
  mouseDownWatcher = hs.eventtap.new({
    hs.eventtap.event.types.leftMouseDown,
    hs.eventtap.event.types.leftMouseDragged,
    hs.eventtap.event.types.rightMouseDown,
  }, function(event)
    local etype = event:getType()
    -- ⌘-click is macOS's menubar-reposition gesture; let it through so the
    -- pill can be dragged instead of seeking/playing or opening the menu.
    if event:getFlags().cmd then return false end
    if etype == hs.eventtap.event.types.rightMouseDown then
      local frame = menuFrame()
      if not frame or frame.w <= 0 then return false end
      if not hs.geometry(event:location()):inside(frame) then return false end
      -- Defer to next tick so we don't show UI from inside the eventtap callback.
      hs.timer.doAfter(0, showRightClickMenu)
      return true
    end
    if etype == hs.eventtap.event.types.leftMouseDown then
      cancelHold()
      holdFired = false
      local frame = menuFrame()
      if not frame or frame.w <= 0 then return false end
      if not hs.geometry(event:location()):inside(frame) then return false end
      holdTimer = hs.timer.doAfter(HOLD_THRESHOLD_SEC, function()
        holdTimer = nil
        holdFired = true
        clearPending()
        seekToMouse()
        hs.spotify.play()
      end)
    elseif etype == hs.eventtap.event.types.leftMouseDragged and holdFired then
      if hs.timer.secondsSinceEpoch() - lastSeekTime >= SEEK_THROTTLE_SEC then
        seekToMouse()
      end
    end
    return false
  end):start()
  if api then api.start(render) end
  log.i("hammertunes pill started")
end

module.stop = function()
  if timer then timer:stop() end
  if pendingClick then pendingClick:stop() end
  cancelHold()
  if mouseDownWatcher then mouseDownWatcher:stop() end
  if menu then menu:delete() end
  if api then api.stop() end
  timer, pendingClick, mouseDownWatcher, menu, pill = nil, nil, nil, nil, nil
  lastTooltip, lastTrack, lastArtist, lastTrackId = nil, nil, nil, nil
  lastDurMs, holdFired, lastSeekTime, lastPlaying = 0, false, 0, false
  lastShuffle, lastRunning = false, false
  artCache, artFetching, artCacheCount = {}, {}, 0
  menuIconCache, menuIconFetching, menuIconCacheCount = {}, {}, 0
end

return module

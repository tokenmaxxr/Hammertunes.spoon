local module = {}
local log = hs.logger.new("hammertunes", "info")
-- pillRenderer (pill.lua, draws the pill image) and api (backend) are injected
-- by init.lua via module.start{ pill=..., api=... } so this file carries no
-- require() path assumptions. Declared here as upvalues the closures below
-- close over.
local pillRenderer = nil

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
-- Kept long enough that an ordinary click stays a clean play/pause and doesn't
-- accidentally scrub the playhead.
local HOLD_THRESHOLD_SEC = 1
-- Minimum interval between scrub seeks while dragging. setPosition calls are
-- synchronous in most backends, so keep this loose enough to stay responsive
-- without backing up.
local SEEK_THROTTLE_SEC = 0.1
local PILL_OPTS = {
  radius = 6,
  padX = 8,
  bg = { red = 0, green = 0, blue = 0, alpha = 0.45 },
  progressBg = { red = 0, green = 0, blue = 0, alpha = 0.7 },
}

-- Optional power-user hook, set via module.start{ hideContext = fn }. If
-- hideContext(uri) returns truthy, the pill collapses to a neutral "♪" for that
-- context. Nil by default — most setups never need it.
local hideContext = nil

local menu = nil
local pill = nil
local timer = nil
local pendingClick = nil
local lastTooltip = nil
local lastTrack = nil
local lastArtist = nil
local lastTrackId = nil
local lastDurMs = 0
local lastLikedPoll = 0
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

-- Backend (transport, state, Web API extras). Injected by module.start.
-- Implements the shared api interface; both Spotify and Apple Music backends
-- slot in here.
local api = nil

-- Display label of the OTHER backend (e.g. "Apple Music") and an opaque,
-- self-deferring callback that swaps to it. Both injected by module.start; they
-- drive the menu's "Switch to …" item. init owns all backend-identity logic.
local switchLabel = nil
local switchBackend = nil
local updateAvailable = nil
local updateNow = nil

local function truncate(s, max)
  if not s then return "" end
  local len = utf8.len(s) or #s
  if len <= max then return s end
  local cut = utf8.offset(s, max)
  return s:sub(1, cut - 1) .. "…"
end

-- Modifier → playback mode for the right-click "Play" items.
-- ⌘⌥ click = smart shuffle, ⌘ click = shuffle, plain = play.
local function playMode(mods)
  if mods and mods.cmd and mods.alt then return "smart" end
  if mods and mods.cmd then return "shuffle" end
  return "play"
end

local render
-- ensureArt fetches or loads cover art and caches the resulting hs.image.
-- Pass artUrl (http URL) for streaming art or artPath (local file path) for
-- library tracks. Exactly one should be non-nil; both nil is a no-op.
-- URL art is fetched asynchronously and triggers a render() on completion.
-- Path art is loaded synchronously (the file is already local).
-- Write an HTTP image body to a temp file and load it as an hs.image, or nil if
-- the body is missing/unreadable. Shared by the cover-art and menu-icon fetches.
local function bodyToImage(body)
  if not body then return nil end
  local path = os.tmpname()
  local f = io.open(path, "wb")
  if not f then return nil end
  f:write(body)
  f:close()
  local img = hs.image.imageFromPath(path)
  os.remove(path)
  return img
end

local function ensureArt(artUrl, artPath)
  local key = artUrl or artPath
  if not key then return nil end
  local cached = artCache[key]
  if cached ~= nil then return cached end
  if artPath then
    -- Local file: load synchronously, no async fetch needed.
    local img = hs.image.imageFromPath(artPath) or false
    if artCacheCount >= MAX_ART_CACHE then
      artCache, artCacheCount = {}, 0
    end
    artCache[key] = img
    artCacheCount = artCacheCount + 1
    return img or nil
  end
  -- artUrl: async HTTP fetch.
  if artFetching[key] then return nil end
  artFetching[key] = true
  hs.http.asyncGet(artUrl, nil, function(code, body)
    artFetching[key] = nil
    local img = (code == 200 and bodyToImage(body)) or nil
    if artCacheCount >= MAX_ART_CACHE then
      artCache, artCacheCount = {}, 0
    end
    artCache[key] = img or false
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
    local img = (code == 200 and bodyToImage(body)) or nil
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

local function setBadge(text, progress, subtitle, artUrl, artPath, liked)
  local art = ensureArt(artUrl, artPath)
  local artKey = artUrl or artPath
  pill.update(text, {
    progress = progress,
    subtitle = subtitle,
    leadingImage = art or nil,
    leadingImageKey = art and artKey or nil,
    likedOverlay = liked == true and art ~= nil,
    -- Heart accent comes from the active backend (Spotify green / Apple Music red).
    likedColor = api and api.likedColor or nil,
  })
end

local function setTooltip(text)
  if text == lastTooltip then return end
  lastTooltip = text
  menu:setTooltip(text)
end

render = function()
  local s = api and api.getState() or { running = false }
  if api and s.track and (s.track ~= lastTrack or (s.playing and not lastPlaying)) then
    api.refresh()
  end
  if api and s.trackId ~= lastTrackId then
    api.refreshLiked(s.trackId)
    lastLikedPoll = hs.timer.secondsSinceEpoch()
  elseif api and s.trackId and api.likedPollSeconds then
    -- Same track still playing: re-poll liked state every api.likedPollSeconds
    -- so a like made in the player's own app shows up without a track change.
    local now = hs.timer.secondsSinceEpoch()
    if now - lastLikedPoll >= api.likedPollSeconds then
      lastLikedPoll = now
      api.refreshLiked(s.trackId, true)
    end
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
  if not s.running or (hideContext and hideContext(ctxUri)) then
    setBadge("♪")
    setTooltip(api and (api.appName .. " not running") or "Not running")
    return
  end
  if s.track then
    local icon = s.playing and "⏸" or "▶"
    local main = icon .. "\u{2002}" .. truncate(s.track, MAX_TRACK)
    local subtitle = s.artist and truncate(s.artist, MAX_ARTIST) or nil
    local liked = api and api.getLiked() == true
    setBadge(main, s.progress, subtitle, s.artUrl, s.artPath, liked)
  else
    setBadge("♪")
  end
  -- Tooltips have no padding control; fake margins with blank lines/leading spaces.
  local PAD = "  "
  local lines = {}
  if s.track then lines[#lines + 1] = PAD .. "🎵\u{2002}" .. s.track end
  if s.artist then lines[#lines + 1] = PAD .. "👤\u{2002}" .. s.artist end
  if ctxName then lines[#lines + 1] = PAD .. "💿\u{2002}" .. ctxName end
  if #lines == 0 then setTooltip(api and api.appName or "Player") return end
  setTooltip("\n" .. table.concat(lines, "\n\n") .. "\n")
end

local function copyCurrent()
  if not (lastTrack and lastArtist) then return end
  local text = lastTrack .. " by " .. lastArtist
  hs.pasteboard.setContents(text)
  hs.alert.show("📋 " .. text, {}, 2)
end

-- Open a YouTube search for the current track in the default browser. A search
-- (not a direct video) because there's no reliable track→video id mapping.
local function openOnYouTube()
  if not lastTrack then return end
  local query = lastArtist and (lastTrack .. " " .. lastArtist) or lastTrack
  hs.urlevent.openURL("https://www.youtube.com/results?search_query=" .. hs.http.encodeForQuery(query))
end

-- State lags mutating commands; refresh shortly after they fire.
local function scheduleRender()
  hs.timer.doAfter(0.2, render)
end

-- Delegates shuffle toggling to the backend and schedules a re-render.
local function setShuffling(on)
  api.setShuffling(on)
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
  api.setPosition(ratio * (lastDurMs / 1000))
  lastSeekTime = hs.timer.secondsSinceEpoch()
end

local function onLeftClick()
  clearPending()
  local pos = api.getPosition() or 0
  if pos > RESTART_THRESHOLD_SEC then
    api.setPosition(0)
  else
    api.previous()
  end
  scheduleRender()
end

local function onRightClick()
  clearPending()
  api.next()
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
    api.playpause()
    scheduleRender()
  end)
end

-- Current shuffle mode for the right-click menu. Regular on/off comes from the
-- 1Hz poll (lastShuffle); "smart" is read-only via the backend API.
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
  -- Smart Shuffle: the API can read it but not set it, so show it disabled
  -- (checked only when active). Gated on backend capability.
  if api and api.supportsSmartShuffle then
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
  local appName = api and api.appName or "Player"
  local items = {
    { title = "Open " .. appName, fn = function() hs.application.launchOrFocus(appName) end },
  }
  -- One read of the cached playlist list, shared by Add to Playlist and Play
  -- Playlist below.
  local playlists = (api and api.getPlaylists()) or {}
  if api and lastTrackId then
    -- Separator before the now-playing track group (only emitted when at least
    -- one track item will follow).
    items[#items + 1] = { title = "-" }
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
    -- Same "Song by Artist" copy as a double-click on the pill's middle, surfaced
    -- in the menu for discoverability. Gated on artist so it never copies a bare
    -- title.
    if lastTrack and lastArtist then
      items[#items + 1] = { title = "Copy \u{201C}Song by Artist\u{201D}", fn = copyCurrent }
    end
    if lastTrack then
      items[#items + 1] = { title = "Open on YouTube", fn = openOnYouTube }
    end
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
  end
  -- Playback group: Shuffle (transport-level, works without the api), then the
  -- api-backed Play items.
  local playItems = {}
  if api then
    -- Play Playlist: recently-played pinned on top in recency order (this is
    -- where Discover Weekly / Release Radar surface when you don't follow them),
    -- then the rest of the library, deduped by id.
    local recent = api.getRecentlyPlayed() or {}
    local pinned = {}
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
        local puri = p.uri
        playItems[#playItems + 1] = {
          title = p.name,
          image = ensureMenuIcon(p.imageUrl),
          fn = function(mods) api.playContext(puri, playMode(mods)) end,
        }
      end
    end
    api.refreshPlaylists()
    api.refreshRecentlyPlayed()
  end
  -- Only emit the separator when a playback group item actually follows it, so
  -- a stopped player on a backend with no liked-songs surface and no playlists
  -- yet (Apple Music before its library loads) doesn't show a dangling divider.
  if lastRunning or (api and api.playLikedSongs) or #playItems > 0 then
    items[#items + 1] = { title = "-" }
  end
  if lastRunning then
    items[#items + 1] = { title = SHUFFLE_LABELS[shuffleState()], menu = shuffleMenuItems() }
  end
  if api and api.playLikedSongs then
    items[#items + 1] = {
      title = "Play Liked Songs",
      fn = function(mods) api.playLikedSongs(playMode(mods)) end,
    }
  end
  if #playItems > 0 then
    items[#items + 1] = { title = "Play Playlist", menu = playItems }
  end
  -- Update notice (opt-in via spoon.checkForUpdates): only when the checked-out
  -- Spoon is behind its remote. Clicking pulls and reloads.
  if updateAvailable and updateAvailable() then
    items[#items + 1] = { title = "-" }
    items[#items + 1] = { title = "Update available - install now", fn = function() if updateNow then updateNow() end end }
  end
  -- Account / backend group: a single separator, then setup-or-reauth and the
  -- backend switch together (no divider between them).
  local showSetup = api and api.needsSetup and api.needsSetup()
  if showSetup or (api and api.supportsReauth) or switchBackend then
    items[#items + 1] = { title = "-" }
    if showSetup then
      -- Backend needs first-time setup: offer its guided flow with the backend's
      -- own label. Deferred via doAfter(0) because the wizard is modal and
      -- popupMenu is still blocking.
      items[#items + 1] = {
        title = api.setupLabel or "Enable extras…",
        fn = function() hs.timer.doAfter(0, function() api.setup() end) end,
      }
    elseif api and api.supportsReauth then
      items[#items + 1] = { title = "Re-authenticate", fn = function() api.authenticate() end }
    end
    if switchBackend then
      items[#items + 1] = { title = "Switch to " .. switchLabel, fn = switchBackend }
    end
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
  pillRenderer = deps.pill
  api = deps.api
  hideContext = deps.hideContext
  switchLabel = deps.switchLabel
  switchBackend = deps.switchBackend
  updateAvailable = deps.updateAvailable
  updateNow = deps.update
  -- autosaveName lets macOS remember this pill's position (⌘-drag) across reloads.
  menu = hs.menubar.new(true, "hammertunes")
  if not menu then
    log.e("hs.menubar.new() returned nil — cannot create menubar item")
    return
  end
  menu:setTitle("")
  menu:setClickCallback(onClick)
  pill = pillRenderer.new(menu, PILL_OPTS, { progressSteps = PILL_PROGRESS_STEPS })
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
        api.play()
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
  lastDurMs, holdFired, lastSeekTime, lastPlaying, lastLikedPoll = 0, false, 0, false, 0
  lastShuffle, lastRunning = false, false
  artCache, artFetching, artCacheCount = {}, {}, 0
  menuIconCache, menuIconFetching, menuIconCacheCount = {}, {}, 0
end

-- Pure helpers exposed for unit tests (see tests/).
module._test = { truncate = truncate, playMode = playMode }

return module

local module = {}
local log = hs.logger.new("hammertunes", "info")
-- Collaborators are injected by init.lua via module.start{ pill=..., api=...,
-- images=..., rightclick=... } so this file carries no require() path
-- assumptions. Declared here as upvalues the closures below close over.
-- pill.lua draws the pill image; rightclick.lua builds the right-click menu.
local pillRenderer = nil
local rightclick = nil

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
-- Image caches (images.lua instances, created in module.start from the
-- injected images module). artCache holds full-size cover art for the pill;
-- async loads re-render. menuIcons holds the same cover URLs scaled down to
-- menu-row size: the popup menu is built synchronously and popupMenu blocks,
-- so icons must already be cached when the menu opens — these are pre-warmed
-- from render(), and there's no onLoad because an open menu can't be updated;
-- freshly fetched icons simply show up on the next right-click.
local MAX_ART_CACHE = 50
local MENU_ICON_SIZE = 18
local MAX_MENU_ICON_CACHE = 100
local artCache = nil
local menuIcons = nil

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

local render
-- ensureArt fetches or loads cover art and caches the resulting hs.image.
-- Pass artUrl (http URL) for streaming art or artPath (local file path) for
-- library tracks. Exactly one should be non-nil; both nil is a no-op.
-- URL art is fetched asynchronously and triggers a render() on completion.
-- Path art is loaded synchronously (the file is already local).
local function ensureArt(artUrl, artPath)
  if artPath then return artCache.getPath(artPath) end
  if artUrl then return artCache.getUrl(artUrl) end
  return nil
end

-- Warm the menu-icon cache for every known playlist so the first right-click
-- already has thumbnails. Cheap once warm: getUrl short-circuits on
-- cached/in-flight URLs, so this is just table lookups after the initial fetch.
local function prewarmMenuIcons()
  if not api then return end
  local pls = api.getPlaylists()
  if pls then
    for _, p in ipairs(pls) do menuIcons.getUrl(p.imageUrl) end
  end
  local recent = api.getRecentlyPlayed()
  if recent then
    for _, r in ipairs(recent) do menuIcons.getUrl(r.imageUrl) end
  end
end

local function setPill(text, progress, subtitle, artUrl, artPath, liked)
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
    setPill("♪")
    setTooltip(api and (api.appName .. " not running") or "Not running")
    return
  end
  if s.track then
    local icon = s.playing and "⏸" or "▶"
    local main = icon .. "\u{2002}" .. truncate(s.track, MAX_TRACK)
    local subtitle = s.artist and truncate(s.artist, MAX_ARTIST) or nil
    local liked = api and api.getLiked() == true
    setPill(main, s.progress, subtitle, s.artUrl, s.artPath, liked)
  else
    setPill("♪")
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

-- setMenu and setClickCallback are mutually exclusive on hs.menubar, so we
-- attach the menu just for the popup and detach it right after. popupMenu is
-- blocking, so the setMenu(nil) only fires once the user dismisses the menu.
local function showRightClickMenu()
  if not menu then return end
  -- Refresh shuffle/playlist caches for the *next* open; popupMenu is blocking,
  -- so these async results can't reach the menu we're about to build.
  if api then
    api.refresh()
    api.refreshPlaylists()
    api.refreshRecentlyPlayed()
  end
  local items = rightclick.build({
    api = api,
    track = lastTrack,
    artist = lastArtist,
    trackId = lastTrackId,
    running = lastRunning,
    shuffle = lastShuffle,
    menuIcon = menuIcons.getUrl,
    copyCurrent = copyCurrent,
    openOnYouTube = openOnYouTube,
    scheduleRender = scheduleRender,
    switchLabel = switchLabel,
    switchBackend = switchBackend,
    updateAvailable = updateAvailable,
    updateNow = updateNow,
  })
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
  rightclick = deps.rightclick
  api = deps.api
  local images = deps.images
  -- render is assigned at module load time, so it's safe to hand over directly.
  artCache = images.newCache(MAX_ART_CACHE, { onLoad = render })
  menuIcons = images.newCache(MAX_MENU_ICON_CACHE, {
    transform = function(img) return images.scaleTo(img, MENU_ICON_SIZE) end,
  })
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
  lastDurMs, holdFired, lastSeekTime, lastPlaying = 0, false, 0, false
  lastShuffle, lastRunning = false, false
  if artCache then artCache.reset() end
  if menuIcons then menuIcons.reset() end
end

-- Pure helpers exposed for unit tests (see tests/).
module._test = { truncate = truncate }

return module

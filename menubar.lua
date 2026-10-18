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
local hoverTimer, hoverSince, tooltipCanvas, visibleTooltip
local hoverDismissed = false
local lastTrack = nil
local lastArtist = nil
local lastTrackId = nil
local lastDurMs = 0
local holdTimer = nil
local holdFired = false
local leftPressed = false
local gestureSnapshot = nil
local gestureLocation = nil
local gestureSequence = 0
local lastSeekRatio = nil
local lastSeekTime = 0
local mouseDownWatcher = nil
local lastPlaying = false
local lastShuffle = false
local lastRunning = false
-- True while a right-click menu is up (see showRightClickMenu). pendingSeekRatio
-- holds a reopen request from a right-click that landed while the menu was open:
-- a number (0..1) or false (reopen, no seek ratio); nil means no reopen pending.
local menuOpen = false
local pendingSeekRatio = nil
local generation = 0
local deferred = {}
local lastState = {}
local api = nil

local function defer(delay, callback)
  local current = generation
  local task
  task = hs.timer.doAfter(delay, function()
    deferred[task] = nil
    if current == generation and menu then callback() end
  end)
  deferred[task] = true
  return task
end

local function sameTrack(snapshot, current)
  current = current or (api and api.getState())
  return current and current.running and current.canControl ~= false
    and current.sourceBundleId == snapshot.sourceBundleId
    and current.trackId == snapshot.trackId and current.track == snapshot.track
    and current.artist == snapshot.artist
end

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

local function setPill(text, progress, subtitle, artUrl, artPath, liked, holdWidth, force)
  local art = ensureArt(artUrl, artPath)
  local artKey = artUrl or artPath
  pill.update(text, {
    force = force,
    progress = progress,
    subtitle = subtitle,
    leadingImage = art or nil,
    leadingImageKey = art and artKey or nil,
    reserveLeadingImage = artKey ~= nil,
    holdWidth = holdWidth,
    likedOverlay = liked == true and artKey ~= nil,
    -- Heart accent comes from the active backend (Spotify green / Apple Music red).
    likedColor = api and api.likedColor or nil,
  })
end

local function hideTooltip()
  if tooltipCanvas then tooltipCanvas:delete() end
  tooltipCanvas, visibleTooltip, hoverSince = nil, nil, nil
end

-- Native status-item tooltips depend on AppKit tracking while we continually
-- replace the progress icon. Keep hover timing independent of those redraws.
local function updateTooltip()
  local frame = menuFrame()
  local mouse = hs.mouse.absolutePosition()
  if not frame or not hs.geometry(mouse):inside(frame) then
    hideTooltip()
    hoverDismissed = false
    return
  end
  if hoverDismissed or leftPressed or menuOpen or not lastTooltip then
    hideTooltip()
    return
  end
  local now = hs.timer.secondsSinceEpoch()
  hoverSince = hoverSince or now
  if now - hoverSince < 0.6 or visibleTooltip == lastTooltip then return end
  hideTooltip()
  hoverSince = now - 0.6
  local screen = hs.mouse.getCurrentScreen():fullFrame()
  local style = { font = ".AppleSystemUIFont", size = 13 }
  local size = hs.drawing.getTextDrawingSize(lastTooltip, style)
  local width = math.min(math.ceil(size.w) + 24, screen.w - 16)
  local height = 16
  for line in (lastTooltip .. "\n"):gmatch("(.-)\n") do
    local lineSize = hs.drawing.getTextDrawingSize(line ~= "" and line or " ", style)
    height = height + lineSize.h * math.max(1, math.ceil(lineSize.w / (width - 24)))
  end
  height = math.min(math.ceil(height), screen.h - 16)
  tooltipCanvas = hs.canvas.new({
    x = math.max(screen.x + 8, math.min(frame.x, screen.x + screen.w - width - 8)),
    y = math.max(screen.y + 8, math.min(frame.y + frame.h + 6, screen.y + screen.h - height - 8)),
    w = width, h = height,
  })
  if not tooltipCanvas then return end
  tooltipCanvas:level("popUpMenu")
  tooltipCanvas:behaviorAsLabels({ "canJoinAllSpaces", "fullScreenAuxiliary" })
  tooltipCanvas:appendElements(
    { type = "rectangle", action = "fill", fillColor = { white = 0.12, alpha = 0.96 },
      roundedRectRadii = { xRadius = 7, yRadius = 7 } },
    { type = "text", text = lastTooltip, textFont = ".AppleSystemUIFont", textSize = 13,
      textColor = { white = 1 }, textLineBreak = "wordWrap",
      frame = { x = 12, y = 8, w = width - 24, h = height - 16 } })
  tooltipCanvas:show()
  visibleTooltip = lastTooltip
end

local function setTooltip(text)
  lastTooltip = text
end

-- Keep gesture feedback local; the regular timer verifies at most once per
-- second, and release forces a final read of the player's accepted position.
local scrubState, scrubReadAt

render = function(force, snapshot)
  if not menu or not pill then return end
  local s = snapshot or (api and api.getState(force)) or { running = false }
  lastState = s
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
  local ctxUri = api and api.getUri() or nil
  local ctxName = api and api.getName() or nil
  if not s.running or (hideContext and hideContext(ctxUri)) then
    setPill("♪", nil, nil, nil, nil, nil, nil, force)
    setTooltip(api and (api.appName .. " not running") or "Not running")
    return
  end
  if s.track then
    local icon = s.playing and "⏸" or "▶"
    local main = icon .. "\u{2002}" .. truncate(s.track, MAX_TRACK)
    local subtitle = s.artist and truncate(s.artist, MAX_ARTIST) or nil
    local liked = api and api.getLiked() == true
    setPill(main, s.progress, subtitle, s.artUrl, s.artPath, liked, nil, force)
  else
    -- Players can briefly report no track between songs. Keep the occupied
    -- menubar space until the next title supplies its final dimensions.
    setPill("♪", nil, nil, nil, nil, nil, true, force)
  end
  local lines = {}
  if s.track then lines[#lines + 1] = "🎵\u{2002}" .. s.track end
  if s.artist then lines[#lines + 1] = "👤\u{2002}" .. s.artist end
  if s.album then lines[#lines + 1] = "💿\u{2002}" .. s.album end
  local function isPlayerName(name)
    return name == "Music" or name == "Spotify" or (api and name == api.appName)
  end
  if s.sourceName and not isPlayerName(s.sourceName) then
    lines[#lines + 1] = s.sourceName
  end
  if ctxName and ctxName ~= s.album and ctxName ~= s.sourceName and not isPlayerName(ctxName) then
    lines[#lines + 1] = "📋\u{2002}" .. ctxName
  end
  if #lines == 0 then setTooltip(api and api.appName or "Player") return end
  setTooltip(table.concat(lines, "\n\n"))
end

local function copyCurrent(track, artist)
  track, artist = track or lastTrack, artist or lastArtist
  if not (track and artist) then return end
  local text = track .. " by " .. artist
  hs.pasteboard.setContents(text)
  hs.alert.show("📋 " .. text, {}, 2)
end

-- Open a YouTube search for the current track in the default browser. A search
-- (not a direct video) because there's no reliable track→video id mapping.
local function openOnYouTube(track, artist)
  if not track then return end
  local query = artist and (track .. " " .. artist) or track
  hs.urlevent.openURL("https://www.youtube.com/results?search_query=" .. hs.http.encodeForQuery(query))
end

-- Read immediately, then once more after the player has had time to settle.
-- Coalesce action bursts so delayed verification cannot accumulate.
local pendingActionRender
local function queueSettledRender()
  if pendingActionRender then
    pendingActionRender:stop()
    deferred[pendingActionRender] = nil
  end
  local task
  task = defer(0.2, function()
    if pendingActionRender ~= task then return end
    pendingActionRender = nil
    if not scrubState then render(true) end
  end)
  pendingActionRender = task
end

local function scheduleRender()
  render(true)
  queueSettledRender()
end

local function clearPending()
  if pendingClick then
    pendingClick:stop()
    deferred[pendingClick] = nil
    pendingClick = nil
  end
end

local function cancelHold()
  if holdTimer then
    holdTimer:stop()
    deferred[holdTimer] = nil
    holdTimer = nil
  end
end

local function drawScrub()
  local snapshot = {}
  for k, v in pairs(scrubState) do snapshot[k] = v end
  snapshot.progress = lastSeekRatio
  snapshot.playing = true
  render(true, snapshot)
end

local function seekTo(location, current, snapshot)
  if not current or current.canSeek == false or not sameTrack(snapshot, current) then return end
  local frame = menuFrame()
  local duration = current.durMs or 0
  if not frame or frame.w <= 0 or duration <= 0 then return end
  -- Consumed drag events can precede the global cursor update. Use the
  -- position from the owned gesture, including moves before the hold fires.
  if not location then return end
  local relX = location.x - frame.x
  local ratio = math.max(0, math.min(1, relX / frame.w))
  if ratio == lastSeekRatio then return end
  api.setPosition(ratio * (duration / 1000))
  lastSeekRatio = ratio
  lastSeekTime = hs.timer.secondsSinceEpoch()
  return true
end

local function onLeftClick()
  clearPending()
  if lastState.canControl == false then return end
  local pos = api.getPosition() or 0
  if pos > RESTART_THRESHOLD_SEC and lastState.canSeek ~= false then
    api.setPosition(0)
  else
    api.previous()
  end
  scheduleRender()
end

local function onRightClick()
  clearPending()
  if lastState.canControl == false then return end
  api.next()
  scheduleRender()
end

local function onMiddleClick()
  if pendingClick then
    pendingClick:stop()
    deferred[pendingClick] = nil
    pendingClick = nil
    copyCurrent()
    return
  end
  local snapshot = lastState
  pendingClick = defer(DOUBLE_CLICK_SEC, function()
    pendingClick = nil
    if snapshot.canControl == false or not sameTrack(snapshot) then return end
    api.playpause()
    scheduleRender()
  end)
end

-- setMenu and setClickCallback are mutually exclusive on hs.menubar, so we
-- attach the menu just for the popup and detach it right after. popupMenu is
-- blocking, so the setMenu(nil) only fires once the user dismisses the menu.
-- seekRatio (0..1, optional) is where on the pill a right-click landed; the menu
-- offers a "Seek to <time>" item that jumps the playhead there. Nil for menus
-- opened by other paths (e.g. a click on the inactive pill).
local function showRightClickMenu(seekRatio)
  if not menu then return end
  -- popupMenu is modal and pumps its own event loop, so right-clicking again
  -- while a menu is open re-enters here (the eventtap still fires during menu
  -- tracking). We must NOT nest popups on the same menubar item — the nested
  -- setMenu(nil) empties the menu the first popup is showing. Instead, record the
  -- new click position, dismiss the open menu (Esc), and let the loop below
  -- reopen at the new spot, so a second right-click MOVES the menu — and its
  -- "Seek to" target — to where you just clicked. `false` = reopen with no seek
  -- ratio (distinct from nil = no reopen pending).
  if menuOpen then
    pendingSeekRatio = seekRatio == nil and false or seekRatio
    hs.eventtap.keyStroke({}, "escape", 0)
    return
  end
  local reopen
  repeat
    local owner, currentGeneration = menu, generation
    local snapshot = lastState
    local function isCurrent()
      return generation == currentGeneration and sameTrack(snapshot)
    end
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
      playing = lastPlaying,
      shuffle = lastShuffle,
      canControl = snapshot.canControl,
      canSeek = snapshot.canSeek,
      canLike = snapshot.canLike,
      canAddToPlaylist = snapshot.canAddToPlaylist,
      isCurrent = isCurrent,
      isActive = function() return generation == currentGeneration and menu == owner end,
      defer = defer,
      -- Seek-to-position: only when we have a track of known length to seek within.
      seekRatio = (lastRunning and lastDurMs > 0) and seekRatio or nil,
      durMs = lastDurMs,
      seek = function(ratio)
        if isCurrent() and snapshot.canSeek ~= false and snapshot.canControl ~= false
          and (snapshot.durMs or 0) > 0 then
          api.setPosition(ratio * (snapshot.durMs / 1000)); scheduleRender()
        end
      end,
      menuIcon = menuIcons.getUrl,
      copyCurrent = function() copyCurrent(snapshot.track, snapshot.artist) end,
      openOnYouTube = function() openOnYouTube(snapshot.track, snapshot.artist) end,
      scheduleRender = scheduleRender,
      switchLabel = switchLabel,
      switchBackend = switchBackend,
      updateAvailable = updateAvailable,
      updateNow = updateNow,
    })
    local function guardItems(entries)
      for _, item in ipairs(entries) do
        if item.fn then
          local action = item.fn
          item.fn = function(...)
            if generation == currentGeneration and menu == owner then return action(...) end
          end
        end
        if item.menu then guardItems(item.menu) end
      end
    end
    guardItems(items)
    menu:setMenu(items)
    menuOpen = true
    menu:popupMenu(hs.mouse.absolutePosition(), true)
    if generation ~= currentGeneration or menu ~= owner then return end
    menuOpen = false
    menu:setMenu(nil)
    -- A right-click landed while we were open: reopen at that new position.
    reopen = pendingSeekRatio ~= nil
    seekRatio = pendingSeekRatio or nil -- `false` -> nil (reopen without a ratio)
    pendingSeekRatio = nil
  until not reopen
end

local function onClick(location)
  -- Player not running: the pill is just "♪" and transport clicks would hit a
  -- dead app, so a click opens the small menu (Open player / Switch to the
  -- other backend) instead. Deferred past this callback like the right-click
  -- path, since popupMenu blocks. Right-click opens the same menu.
  if not lastRunning then
    defer(0, showRightClickMenu)
    return
  end

  local frame = menuFrame()
  if not frame or frame.w <= 0 then
    onMiddleClick()
    return
  end

  local relX = (location or hs.mouse.absolutePosition()).x - frame.x
  if relX < frame.w * SIDE_ZONE_FRAC then
    onLeftClick()
  elseif relX >= frame.w * (1 - SIDE_ZONE_FRAC) then
    onRightClick()
  else
    onMiddleClick()
  end
end

module.start = function(deps)
  if menu then module.stop() end
  generation = generation + 1
  local currentGeneration = generation
  deps = deps or {}
  pillRenderer = deps.pill
  rightclick = deps.rightclick
  api = deps.api
  local images = deps.images
  -- render is assigned at module load time, so it's safe to hand over directly.
  local function renderCurrent(force)
    if currentGeneration ~= generation then return end
    if scrubState then
      local now = hs.timer.secondsSinceEpoch()
      if now - scrubReadAt < 1 then return end
      scrubState = api.getState(true)
      scrubReadAt = now
      render(true, scrubState)
    elseif force == true then
      scheduleRender()
    else
      render()
    end
  end
  artCache = images.newCache(MAX_ART_CACHE, { onLoad = renderCurrent })
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
  menu:setClickCallback(function() onClick() end)
  pill = pillRenderer.new(menu, PILL_OPTS, { progressSteps = PILL_PROGRESS_STEPS })
  render()
  timer = hs.timer.doEvery(1, renderCurrent):start()
  hoverTimer = hs.timer.doEvery(0.1, function()
    if currentGeneration == generation and menu then updateTooltip() end
  end)
  mouseDownWatcher = hs.eventtap.new({
    hs.eventtap.event.types.leftMouseDown,
    hs.eventtap.event.types.leftMouseUp,
    hs.eventtap.event.types.leftMouseDragged,
    hs.eventtap.event.types.rightMouseDown,
  }, function(event)
    local etype = event:getType()
    if etype == hs.eventtap.event.types.leftMouseDown then
      gestureSequence = gestureSequence + 1
    end
    if etype == hs.eventtap.event.types.leftMouseDown
      or etype == hs.eventtap.event.types.rightMouseDown then
      hideTooltip()
      hoverDismissed = true
    end
    -- Own the entire gesture so native status-item mouse tracking cannot delay
    -- the hold timer until release. Always clean up on mouse-up, even outside
    -- the pill or if Command was pressed after mouse-down.
    if etype == hs.eventtap.event.types.leftMouseUp and leftPressed then
      leftPressed = false
      cancelHold()
      if holdFired then
        local snapshot, location, sequence = gestureSnapshot, event:location(), gestureSequence
        holdFired = false
        scrubState, scrubReadAt = nil, nil
        -- Streaming reads can block. Return from the event tap before checking
        -- identity and the final accepted position; a newer press cancels this.
        defer(0, function()
          if sequence ~= gestureSequence then return end
          local current = api.getState(true)
          local changed = seekTo(location, current, snapshot)
          render(true, changed and api.getState(true) or current)
          if changed then queueSettledRender() end
        end)
      else
        local frame = menuFrame()
        local loc = event:location()
        if frame and hs.geometry(loc):inside(frame) then
          local snapshot = gestureSnapshot
          defer(0, function()
            -- Read-only media still supports the center double-click to copy.
            if snapshot and snapshot.canControl == false then onClick(loc)
            elseif snapshot and sameTrack(snapshot) then onClick(loc) end
          end)
        end
      end
      return true
    end
    if etype == hs.eventtap.event.types.leftMouseDragged and leftPressed then
      gestureLocation = event:location()
      if holdFired and hs.timer.secondsSinceEpoch() - lastSeekTime >= SEEK_THROTTLE_SEC then
        if seekTo(gestureLocation, scrubState, gestureSnapshot) then drawScrub() end
      end
      return true
    end
    -- ⌘-click is macOS's menubar-reposition gesture; let it through so the
    -- pill can be dragged instead of seeking/playing or opening the menu.
    if event:getFlags().cmd then return false end
    if etype == hs.eventtap.event.types.rightMouseDown then
      local frame = menuFrame()
      if not frame or frame.w <= 0 then return false end
      local loc = event:location()
      if not hs.geometry(loc):inside(frame) then return false end
      -- Remember where along the pill the click landed so the menu can offer a
      -- "Seek to <time>" jump to that position (same mapping as seekTo).
      local seekRatio = math.max(0, math.min(1, (loc.x - frame.x) / frame.w))
      -- Defer to next tick so we don't show UI from inside the eventtap callback.
      defer(0, function() showRightClickMenu(seekRatio) end)
      return true
    end
    if etype == hs.eventtap.event.types.leftMouseDown then
      cancelHold()
      holdFired = false
      leftPressed = false
      local frame = menuFrame()
      if not frame or frame.w <= 0 then return false end
      if not hs.geometry(event:location()):inside(frame) then return false end
      -- Inactive pill is menu-only: no hold-to-seek on a dead player.
      if not lastRunning then return false end
      if menuOpen then
        -- We consume this mouse-down, so native menu tracking cannot dismiss
        -- the popup itself. Close it before continuing the pill gesture.
        pendingSeekRatio = nil
        hs.eventtap.keyStroke({}, "escape", 0)
      end
      leftPressed = true
      gestureLocation = event:location()
      lastSeekRatio = nil
      local snapshot = lastState
      gestureSnapshot = snapshot
      holdTimer = defer(HOLD_THRESHOLD_SEC, function()
        holdTimer = nil
        holdFired = true
        clearPending()
        if snapshot.canControl == false or snapshot.canSeek == false then return end
        local current = api.getState(true)
        if not sameTrack(snapshot, current) then return end
        scrubState, scrubReadAt = current, hs.timer.secondsSinceEpoch()
        seekTo(gestureLocation, current, snapshot)
        api.play()
        if lastSeekRatio then drawScrub() end
      end)
      return true
    end
    return false
  end):start()
  if api then api.start(renderCurrent) end
  log.i("hammertunes pill started")
end

module.stop = function()
  generation = generation + 1
  for task in pairs(deferred) do task:stop() end
  deferred = {}
  if timer then timer:stop() end
  if hoverTimer then hoverTimer:stop() end
  hideTooltip()
  hoverTimer, hoverDismissed = nil, false
  if pendingClick then pendingClick:stop() end
  cancelHold()
  if mouseDownWatcher then mouseDownWatcher:stop() end
  if menu then menu:delete() end
  if api then api.stop() end
  timer, pendingClick, mouseDownWatcher, menu, pill = nil, nil, nil, nil, nil
  pendingActionRender = nil
  lastTooltip, lastTrack, lastArtist, lastTrackId = nil, nil, nil, nil
  lastDurMs, holdFired, lastSeekTime, lastPlaying = 0, false, 0, false
  leftPressed = false
  gestureSnapshot = nil
  scrubState, scrubReadAt = nil, nil
  lastState = {}
  lastShuffle, lastRunning, menuOpen, pendingSeekRatio = false, false, false, nil
  if artCache then artCache.reset() end
  if menuIcons then menuIcons.reset() end
end

-- Pure helpers exposed for unit tests (see tests/).
module._test = { truncate = truncate }

return module

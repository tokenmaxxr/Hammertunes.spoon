-- Builds the right-click menu, grouped by what items act on: app / now-playing
-- track / playback / update / account. Pure given a context table — no
-- hs.menubar state and no refresh side effects — so the grouping and gating
-- logic is unit-testable (see tests/rightclick_spec.lua).
--
-- build() only reads the api's caches (getPlaylists, getRecentlyPlayed); the
-- caller is responsible for kicking off refreshes beforehand (see menubar.lua's
-- showRightClickMenu) or the menu shows whatever was cached last.
--
-- ctx fields (all optional unless noted):
--  * api            - backend (transport, state, Web API extras) or nil
--  * track, artist, trackId, running, shuffle - now-playing state snapshot
--  * menuIcon(url)  - returns a cached menu-sized hs.image or nil
--  * copyCurrent(), openOnYouTube(), scheduleRender() - controller actions
--  * switchLabel, switchBackend - "Switch to …" label and action
--  * updateAvailable(), updateNow() - update-notice getter and action
local module = {}

local MENU_PLAYLIST_LIMIT = 25

-- This is also used by the controller to warm exactly the visible icons.
module.selectEntries = function(ctx)
  local api = ctx.api
  local playlists = api and api.getPlaylists() or {}
  local owned, play, seen = {}, {}, {}
  if api and ctx.trackId and ctx.canAddToPlaylist ~= false then
    for _, p in ipairs(playlists) do
      if p.owned and #owned < MENU_PLAYLIST_LIMIT then owned[#owned + 1] = p end
    end
  end
  if ctx.running then
    local function add(entries)
      for _, p in ipairs(entries) do
        local key = p.id or p.uri
        if key and not seen[key] and #play < MENU_PLAYLIST_LIMIT then
          seen[key] = true
          play[#play + 1] = p
        end
      end
    end
    add(api and api.getRecentlyPlayed() or {})
    add(playlists)
  end
  return { owned = owned, play = play }
end

-- Modifier → playback mode for the "Play" items.
-- ⌘⌥ click = smart shuffle, ⌘ click = shuffle, plain = play.
local function playMode(mods)
  if mods and mods.cmd and mods.alt then return "smart" end
  if mods and mods.cmd then return "shuffle" end
  return "play"
end

-- Current shuffle mode. Regular on/off comes from the 1Hz poll (ctx.shuffle);
-- "smart" is read-only via the backend API.
local function shuffleState(ctx)
  if ctx.api and ctx.api.getSmartShuffle() == true then return "smart" end
  return ctx.shuffle and "on" or "off"
end

local SHUFFLE_LABELS = { off = "Shuffle: Off", on = "Shuffle: On", smart = "Shuffle: Smart" }

-- Relative controls must still refer to the media displayed when the menu
-- opened. Explicit playlist commands name their target and need no such guard.
local function currentAction(ctx, callback)
  return function(...)
    if not ctx.isCurrent or ctx.isCurrent() then return callback(...) end
  end
end

local function shuffleMenuItems(ctx, st)
  local items = {
    { title = "Off", checked = st == "off",
      fn = currentAction(ctx, function() ctx.api.setShuffling(false); ctx.scheduleRender() end) },
    { title = "Shuffle", checked = st == "on",
      fn = currentAction(ctx, function() ctx.api.setShuffling(true); ctx.scheduleRender() end) },
  }
  -- Smart Shuffle: the API can read it but not set it, so show it disabled
  -- (checked only when active). Gated on backend capability.
  if ctx.api and ctx.api.supportsSmartShuffle then
    items[#items + 1] = { title = "Smart Shuffle", checked = st == "smart", disabled = true }
  end
  return items
end

-- Each section builder below returns a list of menu items (empty when the
-- section has nothing to show). A non-empty section owns its own leading "-"
-- separator, so build() can concatenate them without tracking dividers. The
-- "inactive" (note-icon) menu is just the natural result of the track/playback
-- sections — and the account group's maintenance items — returning empty when
-- the player isn't running.

-- App group: always present, the menu's first row. No leading separator.
local function appHeader(ctx)
  local appName = (ctx.api and ctx.api.appName) or "Player"
  return { { title = "Open " .. appName, fn = function() hs.application.launchOrFocus(appName) end } }
end

-- Transport group: Previous / Play-Pause / Next, mirroring the pill's click
-- zones for discoverability. Only when the player is running (a closed player
-- has nothing to control). The middle item reflects play state: "Pause" while
-- playing, "Play" when paused — both just toggle via playpause().
--
-- Each item carries a hint for the equivalent pill click (see menubar.lua's
-- onClick: a left-button click on the pill's left/center/right runs prev /
-- play-pause / next). Wording lives in these constants so tests stay in sync.
local PREV_LABEL = "Previous (click pill's left)"
local NEXT_LABEL = "Next (click pill's right)"
local function playPauseLabel(playing)
  return (playing and "Pause" or "Play") .. " (click pill's center)"
end

-- Whole seconds as M:SS.
local function fmtTime(sec)
  sec = math.max(0, math.floor(sec + 0.5))
  return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

-- "Seek to <time>" item shown when the menu was opened by right-clicking the
-- pill (ctx.seekRatio = where along the pill, 0..1) and the track length is
-- known. Jumps the playhead to that position; the hint points at the long-press
-- gesture for continuous scrubbing (menubar.lua's hold-to-seek).
local function seekLabel(ctx)
  return "Seek to " .. fmtTime(ctx.seekRatio * (ctx.durMs / 1000)) ..
    " (or long-press pill to scrub)"
end

local function transportGroup(ctx)
  if not (ctx.running and ctx.api) or ctx.canControl == false then return {} end
  local api = ctx.api
  local items = {
    { title = "-" },
    { title = PREV_LABEL, fn = currentAction(ctx, function() api.previous(); ctx.scheduleRender() end) },
    { title = playPauseLabel(ctx.playing),
      fn = currentAction(ctx, function() api.playpause(); ctx.scheduleRender() end) },
  }
  -- Seek sits between Play/Pause and Next, next to the playback controls it acts on.
  if ctx.canSeek ~= false and ctx.seekRatio and ctx.seek and ctx.durMs and ctx.durMs > 0 then
    local ratio = ctx.seekRatio
    items[#items + 1] = { title = seekLabel(ctx), fn = currentAction(ctx, function() ctx.seek(ratio) end) }
  end
  items[#items + 1] = { title = NEXT_LABEL,
    fn = currentAction(ctx, function() api.next(); ctx.scheduleRender() end) }
  return items
end

-- Refresh-interval picker: how often the backend runs expensive now-playing
-- reads. Shared across backends (see backends/pollinterval.lua).
-- Shorter polls more often — flagged as higher battery, with an alert on select.
local POLL_INTERVAL_CHOICES = { 1, 2, 3, 5, 10 }
local POLL_INTERVAL_DEFAULT = 3 -- also the battery-warning threshold: options below it poll more

local function pollIntervalMenuItems(ctx)
  local api = ctx.api
  local current = api.getPollInterval()
  local items = {}
  for _, sec in ipairs(POLL_INTERVAL_CHOICES) do
    local title = sec .. "s"
    if sec == POLL_INTERVAL_DEFAULT then title = title .. " (default)" end
    if sec < POLL_INTERVAL_DEFAULT then title = title .. "  \u{26A0} more battery" end
    items[#items + 1] = {
      title = title,
      checked = current == sec,
      fn = function()
        api.setPollInterval(sec)
        if sec < POLL_INTERVAL_DEFAULT then
          hs.alert.show("Refreshing every " .. sec .. "s uses more battery", 2)
        end
        ctx.scheduleRender()
      end,
    }
  end
  return items
end

-- Metadata actions need only a title; library actions also require an ID and
-- the corresponding backend capability.
local function trackGroup(ctx, selection)
  local api = ctx.api
  if not (ctx.track or (api and ctx.trackId)) then return {} end
  local items = { { title = "-" } }
  local trackId = ctx.trackId
  if api and trackId and ctx.canLike ~= false then
    local liked = api.getLiked()
    -- nil happens during the auth/first-fetch race; refresh for the next open.
    if liked == true then
      items[#items + 1] = { title = "Unlike", fn = function() api.unlike(trackId); ctx.scheduleRender() end }
    else
      if liked == nil then api.refreshLiked(trackId) end
      items[#items + 1] = { title = "Like", fn = function() api.like(trackId); ctx.scheduleRender() end }
    end
  end
  -- Same "Song by Artist" copy as a double-click on the pill's middle, surfaced
  -- in the menu for discoverability. Gated on artist so it never copies a bare
  -- title.
  if ctx.track and ctx.artist then
    items[#items + 1] = { title = "Copy \u{201C}Song by Artist\u{201D}", fn = ctx.copyCurrent }
  end
  if ctx.track then
    items[#items + 1] = { title = "Open on YouTube", fn = ctx.openOnYouTube }
  end
  -- Add to Playlist: only playlists you own — you can't add tracks to ones you
  -- merely follow.
  local owned = selection.owned
  if #owned > 0 then
    local subItems = {}
    for _, p in ipairs(owned) do
      local pid, pname = p.id, p.name
      subItems[#subItems + 1] = {
        title = pname,
        image = ctx.menuIcon(p.imageUrl),
        fn = function()
          api.addToPlaylist(pid, trackId, function(ok)
            if ctx.isActive and not ctx.isActive() then return end
            hs.alert.show(ok and ("Added to " .. pname) or ("Failed to add to " .. pname))
          end)
        end,
      }
    end
    items[#items + 1] = { title = "Add to Playlist", menu = subItems }
  end
  return #items > 1 and items or {}
end

-- Playback group: Shuffle + Play items. Only when the player is running — on a
-- closed player the pill is just a note icon and the menu offers only Open /
-- Switch; starting playback would need the app launched first, so this stays
-- hidden (even when the backend still has playlists/liked-songs cached from its
-- last run) until it's running again.
local function playbackGroup(ctx, selection)
  if not ctx.running then return {} end
  local api = ctx.api
  -- Play Playlist: recently-played pinned on top in recency order (this is where
  -- Discover Weekly / Release Radar surface when you don't follow them), then
  -- the rest of the library, deduped by id.
  local playItems = {}
  if api then
    for _, r in ipairs(selection.play) do
      local ruri = r.uri
      playItems[#playItems + 1] = {
        title = r.name or r.uri,
        image = ctx.menuIcon(r.imageUrl),
        fn = function(mods) api.playContext(ruri, playMode(mods)) end,
      }
    end
  end
  -- Shuffle changes the current session; library commands explicitly choose
  -- what to play, including when the pill displays another app's metadata.
  local items = { { title = "-" } }
  if ctx.canControl ~= false then
    local st = shuffleState(ctx)
    items[#items + 1] = { title = SHUFFLE_LABELS[st], menu = shuffleMenuItems(ctx, st) }
  end
  if api then
    if api.playLikedSongs then
      items[#items + 1] = { title = "Play Liked Songs", fn = function(mods) api.playLikedSongs(playMode(mods)) end }
    end
    if #playItems > 0 then
      items[#items + 1] = { title = "Play Playlist", menu = playItems }
    end
    -- Apple Music only: mirror other apps' Now Playing (browsers, etc.) under the
    -- pill. A source preference, so it trails the content items. Checkable; off
    -- by default. Gated on backend capability.
    if api.supportsSourceToggle then
      items[#items + 1] = {
        title = "Show Other Sources",
        checked = api.getShowOtherSources(),
        fn = function() api.setShowOtherSources(not api.getShowOtherSources()); ctx.scheduleRender() end,
      }
    end
  end
  return #items > 1 and items or {}
end

-- Update notice (spoon.checkForUpdates, on by default): only when the
-- checked-out Spoon is behind its remote. Clicking pulls and reloads.
-- updateAvailable and updateNow are always injected together (menubar.lua).
local function updateGroup(ctx)
  if not (ctx.updateAvailable and ctx.updateAvailable()) then return {} end
  return {
    { title = "-" },
    { title = "Update available - install now", fn = ctx.updateNow },
  }
end

-- Account / settings group: setup-or-reauth, the refresh-interval picker, and the
-- backend switch, together under one divider. Setup, re-auth, and the interval are
-- only relevant while the player is in use, so they're gated on the backend being
-- active — a closed player's menu stays minimal. Switch is always offered.
local function accountGroup(ctx)
  local api = ctx.api
  local active = ctx.running and api -- the backend is alive
  -- showSetup and showReauth are mutually exclusive via the if/elseif below, so
  -- showReauth needs no explicit "and not showSetup".
  local showSetup = active and api.needsSetup and api.needsSetup()
  local showReauth = active and api.supportsReauth
  -- getPollInterval/setPollInterval are REQUIRED interface members, so any active
  -- backend has them; no capability check needed.
  if not (active or ctx.switchBackend) then return {} end
  local items = { { title = "-" } }
  if showSetup then
    -- Backend needs first-time setup: offer its guided flow with the backend's
    -- own label. Deferred via doAfter(0) because the wizard is modal and
    -- popupMenu is still blocking.
    items[#items + 1] = {
      title = api.setupLabel or "Enable extras…",
      fn = function() (ctx.defer or hs.timer.doAfter)(0, function() api.setup() end) end,
    }
  elseif showReauth then
    items[#items + 1] = { title = "Re-authenticate", fn = function() api.authenticate() end }
  end
  if active then
    items[#items + 1] = { title = "Refresh interval", menu = pollIntervalMenuItems(ctx) }
  end
  if ctx.switchBackend then
    items[#items + 1] = { title = "Switch to " .. ctx.switchLabel, fn = ctx.switchBackend }
  end
  return items
end

module.build = function(ctx)
  -- One read of the cached playlist list, shared by the track group (Add to
  -- Playlist) and the playback group (Play Playlist).
  local selection = module.selectEntries(ctx)
  local items = {}
  local function append(section)
    for _, it in ipairs(section) do items[#items + 1] = it end
  end
  append(appHeader(ctx))
  append(transportGroup(ctx))
  append(trackGroup(ctx, selection))
  append(playbackGroup(ctx, selection))
  append(updateGroup(ctx))
  append(accountGroup(ctx))
  return items
end

-- Pure helpers exposed for unit tests (see tests/).
module._test = {
  playMode = playMode,
  PREV_LABEL = PREV_LABEL,
  NEXT_LABEL = NEXT_LABEL,
  playPauseLabel = playPauseLabel,
  fmtTime = fmtTime,
}

return module

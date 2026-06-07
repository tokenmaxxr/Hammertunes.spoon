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

local function shuffleMenuItems(ctx, st)
  local items = {
    { title = "Off", checked = st == "off",
      fn = function() ctx.api.setShuffling(false); ctx.scheduleRender() end },
    { title = "Shuffle", checked = st == "on",
      fn = function() ctx.api.setShuffling(true); ctx.scheduleRender() end },
  }
  -- Smart Shuffle: the API can read it but not set it, so show it disabled
  -- (checked only when active). Gated on backend capability.
  if ctx.api and ctx.api.supportsSmartShuffle then
    items[#items + 1] = { title = "Smart Shuffle", checked = st == "smart", disabled = true }
  end
  return items
end

module.build = function(ctx)
  local api = ctx.api
  local appName = api and api.appName or "Player"
  local items = {
    { title = "Open " .. appName, fn = function() hs.application.launchOrFocus(appName) end },
  }
  -- One read of the cached playlist list, shared by Add to Playlist and Play
  -- Playlist below.
  local playlists = (api and api.getPlaylists()) or {}
  if api and ctx.trackId then
    -- Separator before the now-playing track group (only emitted when at least
    -- one track item will follow).
    items[#items + 1] = { title = "-" }
    local liked = api.getLiked()
    local trackId = ctx.trackId
    -- nil happens during the auth/first-fetch race; default to Like and kick
    -- off a refresh so the next open shows the right verb.
    if liked == true then
      items[#items + 1] = {
        title = "Unlike",
        fn = function() api.unlike(trackId); ctx.scheduleRender() end,
      }
    else
      if liked == nil then api.refreshLiked(trackId) end
      items[#items + 1] = {
        title = "Like",
        fn = function() api.like(trackId); ctx.scheduleRender() end,
      }
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
          image = ctx.menuIcon(p.imageUrl),
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
        image = ctx.menuIcon(r.imageUrl),
        fn = function(mods) api.playContext(ruri, playMode(mods)) end,
      }
    end
    for _, p in ipairs(playlists) do
      if #playItems >= MENU_PLAYLIST_LIMIT then break end
      if not pinned[p.id] then
        local puri = p.uri
        playItems[#playItems + 1] = {
          title = p.name,
          image = ctx.menuIcon(p.imageUrl),
          fn = function(mods) api.playContext(puri, playMode(mods)) end,
        }
      end
    end
  end
  -- Only emit the separator when a playback group item actually follows it, so
  -- a stopped player on a backend with no liked-songs surface and no playlists
  -- yet (Apple Music before its library loads) doesn't show a dangling divider.
  if ctx.running or (api and api.playLikedSongs) or #playItems > 0 then
    items[#items + 1] = { title = "-" }
  end
  if ctx.running then
    local st = shuffleState(ctx)
    items[#items + 1] = { title = SHUFFLE_LABELS[st], menu = shuffleMenuItems(ctx, st) }
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
  -- Update notice (spoon.checkForUpdates, on by default): only when the
  -- checked-out Spoon is behind its remote. Clicking pulls and reloads.
  if ctx.updateAvailable and ctx.updateAvailable() then
    items[#items + 1] = { title = "-" }
    -- updateAvailable and updateNow are always injected together (menubar.lua),
    -- so the gate above is enough.
    items[#items + 1] = {
      title = "Update available - install now",
      fn = ctx.updateNow,
    }
  end
  -- Account / backend group: a single separator, then setup-or-reauth and the
  -- backend switch together (no divider between them).
  local showSetup = api and api.needsSetup and api.needsSetup()
  if showSetup or (api and api.supportsReauth) or ctx.switchBackend then
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
    if ctx.switchBackend then
      items[#items + 1] = { title = "Switch to " .. ctx.switchLabel, fn = ctx.switchBackend }
    end
  end
  return items
end

-- Pure helpers exposed for unit tests (see tests/).
module._test = { playMode = playMode }

return module

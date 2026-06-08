-- Hammertunes Spotify backend: talks to the Spotify Web API for things
-- AppleScript can't do — the playing context name (playlist / album / radio),
-- the liked-songs state of the current track, and playlist read/play/modify.
-- We go through OAuth (PKCE) once and then call /v1/me/* endpoints. The refresh
-- token lives in the macOS Keychain.
--
-- Setup:
--   1. https://developer.spotify.com/dashboard → Create app
--   2. Set Redirect URI to exactly: http://127.0.0.1:53127/callback
--   3. From the Hammerspoon console:
--        spoon.Hammertunes:authenticate("YOUR_CLIENT_ID")
--      Browser opens, you approve, done. The Client ID is also saved to the
--      Keychain so later re-auths can be called as :authenticate().

---@type HammertunesBackend
local module = {}
local log = hs.logger.new("hammertunes.spotify", "info")

local SERVICE = "Hammertunes"
local REDIRECT_URI = "http://127.0.0.1:53127/callback"
local AUTH_PORT = 53127
local SCOPES = "user-read-playback-state user-modify-playback-state " ..
  "user-library-read user-library-modify " ..
  "playlist-read-private playlist-modify-public playlist-modify-private " ..
  "user-read-recently-played"

local accessToken = nil
local accessExpiry = 0
local currentUri = nil
local currentName = nil
local nameCache = {}
local imageCache = {}
local currentTrackId = nil
local currentLiked = nil
-- Real Spotify "Smart Shuffle" state. Read-only: the Web API exposes it on the
-- player object but offers no endpoint to set it, so the menu only displays it.
local currentSmartShuffle = nil
local currentUserId = nil
local playlistsCache = nil
local playlistsFetching = false
local playlistsFetchedAt = 0
local PLAYLISTS_FRESH_SEC = 3600
local PLAYLISTS_CACHE_PATH = os.getenv("HOME") .. "/.hammerspoon/.hammertunes-playlists.json"
local recentlyPlayedCache = nil
local recentlyPlayedFetchedAt = 0
local RECENTLY_PLAYED_FRESH_SEC = 30
local authServer = nil
local authServerTimer = nil
local onChange = nil

-- Keychain reads shell out (~50ms each). Cache after first load; the module
-- updates the cache when it rotates the refresh token.
local credsLoaded = false
local cachedClientId, cachedRefreshToken

local function shellEsc(s)
  local escaped = (tostring(s):gsub("'", "'\\''"))
  return "'" .. escaped .. "'"
end

local function keychainGet(account)
  -- hs.execute returns (output, success, ...) - out first, ok second. That's
  -- the correct binding here; the reversed order vs. common `ok, out` idiom is
  -- intentional and not a bug.
  local out, ok = hs.execute("/usr/bin/security find-generic-password -s " ..
    shellEsc(SERVICE) .. " -a " .. shellEsc(account) .. " -w 2>/dev/null")
  if not ok or not out or out == "" then return nil end
  return (out:gsub("\r?\n$", ""))
end

-- -U does an atomic upsert. The previous delete+add was racey: if delete
-- failed (or returned 'item not found' but the item was actually still there),
-- add would fail because the duplicate existed, leaving keychain with a stale
-- value. Spotify rotates refresh tokens on every use; one missed save means
-- the next reload reads the OLD (now-revoked) token and auth breaks.
local function keychainSet(account, value)
  -- Same (output, success, ...) binding as keychainGet - hs.execute's signature,
  -- not a bug.
  local out, ok = hs.execute("/usr/bin/security add-generic-password -U -s " ..
    shellEsc(SERVICE) .. " -a " .. shellEsc(account) ..
    " -w " .. shellEsc(value) .. " 2>&1")
  if not ok then
    log.e("keychainSet failed for " .. account .. ": " .. tostring(out))
    hs.alert.show("Spotify keychain save failed (" .. account .. ")", 5)
    return false
  end
  return true
end

local function loadCreds()
  if credsLoaded then return end
  cachedClientId = keychainGet("client_id")
  cachedRefreshToken = keychainGet("refresh_token")
  credsLoaded = true
end

local function saveClientId(v)
  if keychainSet("client_id", v) then
    cachedClientId, credsLoaded = v, true
  end
end

-- If keychain write fails, still update in-memory cache: Spotify just rotated,
-- so the old token is dead. In-memory keeps this session working; next reload
-- will read the stale keychain value and require re-auth (loud log above will
-- explain why).
local function saveRefreshToken(v)
  keychainSet("refresh_token", v)
  cachedRefreshToken, credsLoaded = v, true
end

local function urandom(n)
  local f = assert(io.open("/dev/urandom", "rb"))
  local data = f:read(n)
  f:close()
  return data
end

local function b64url(data)
  local b = hs.base64.encode(data)
  return (b:gsub("+", "-"):gsub("/", "_"):gsub("=", ""))
end

local function pkceChallenge(verifier)
  local hex = hs.hash.SHA256(verifier)
  local bytes = (hex:gsub("..", function(b) return string.char(tonumber(b, 16)) end))
  return b64url(bytes)
end

local function notify()
  if onChange then onChange() end
end

-- Coalesces concurrent callers of one async operation: the first join()
-- returns true (that caller starts the work), later joins queue until flush()
-- delivers the result to everyone. Pure, so it's unit-testable (see tests/).
local function singleFlight()
  local waiting = nil
  local sf = {}
  sf.join = function(cb)
    if waiting then
      table.insert(waiting, cb)
      return false
    end
    waiting = { cb }
    return true
  end
  sf.flush = function(...)
    local list = waiting
    waiting = nil
    for _, cb in ipairs(list or {}) do cb(...) end
  end
  return sf
end

-- Token refreshes MUST be single-flight: Spotify rotates the refresh token on
-- every use, so two concurrent refreshes both send the same token and the
-- loser gets "invalid_grant: Refresh token revoked" (and reuse detection can
-- revoke the whole grant). Seen in practice at startup, where refresh() and
-- fetchRecentlyPlayed() race the first refresh.
local tokenFlight = singleFlight()

local function ensureAccessToken(callback)
  local now = hs.timer.secondsSinceEpoch()
  if accessToken and now < accessExpiry - 30 then
    callback(accessToken)
    return
  end
  loadCreds()
  if not (cachedClientId and cachedRefreshToken) then
    callback(nil)
    return
  end
  if not tokenFlight.join(callback) then return end
  local body = "grant_type=refresh_token" ..
    "&refresh_token=" .. hs.http.encodeForQuery(cachedRefreshToken) ..
    "&client_id=" .. hs.http.encodeForQuery(cachedClientId)
  hs.http.asyncPost(
    "https://accounts.spotify.com/api/token",
    body,
    { ["Content-Type"] = "application/x-www-form-urlencoded" },
    function(status, response)
      if status ~= 200 then
        log.e("token refresh failed: " .. tostring(status) .. " " .. tostring(response))
        tokenFlight.flush(nil, "auth failed")
        return
      end
      -- hs.json.decode returns nil on malformed JSON; the nil guard below handles it.
      local data = hs.json.decode(response)
      if not (data and data.access_token) then
        log.e("token refresh: malformed response")
        tokenFlight.flush(nil, "auth failed")
        return
      end
      accessToken = data.access_token
      accessExpiry = hs.timer.secondsSinceEpoch() + (data.expires_in or 3600)
      if data.refresh_token then saveRefreshToken(data.refresh_token) end
      tokenFlight.flush(accessToken)
    end
  )
end

local HTML_ENTITIES = {
  ["&amp;"] = "&", ["&lt;"] = "<", ["&gt;"] = ">",
  ["&quot;"] = '"', ["&#39;"] = "'", ["&apos;"] = "'",
}
local function decodeEntities(s)
  return (s:gsub("&[#%w]+;", HTML_ENTITIES))
end

-- Spotify deprecated Web API access to editorial/algorithmic playlists in 2024
-- (Daily Mix, *Radio, Discover Weekly, etc — all the spotify:playlist:37i9dQZ...
-- ones), so /v1/playlists/{id} returns 404 for them. Fall back to scraping
-- og:title from the public open.spotify.com page, which still works.
local function fetchViaScrape(kind, id, onName)
  local url = "https://open.spotify.com/" .. kind .. "/" .. id
  hs.http.asyncGet(url, { ["User-Agent"] = "Mozilla/5.0" }, function(status, body)
    if status ~= 200 or not body then
      onName(nil)
      return
    end
    local name = body:match('<meta property="og:title" content="([^"]+)"')
    onName(name and decodeEntities(name) or nil)
  end)
end

local function fetchName(token, uri, onName)
  -- Cache stores `false` for known-misses so we don't re-hit API+scrape on
  -- every poll for an unresolvable URI.
  local cached = nameCache[uri]
  if cached ~= nil then
    onName(cached or nil)
    return
  end
  local kind, id = uri:match("^spotify:(%w+):(.+)$")
  if not kind or not id then
    onName(nil)
    return
  end
  local endpoint
  if kind == "playlist" then endpoint = "playlists/" .. id .. "?fields=name"
  elseif kind == "album" then endpoint = "albums/" .. id
  elseif kind == "artist" then endpoint = "artists/" .. id
  elseif kind == "show" then endpoint = "shows/" .. id
  else
    onName(nil)
    return
  end
  hs.http.asyncGet(
    "https://api.spotify.com/v1/" .. endpoint,
    { Authorization = "Bearer " .. token },
    function(status, body)
      if status == 200 then
        -- hs.json.decode returns nil on malformed JSON; the nil guard below handles it.
        local data = hs.json.decode(body)
        local name = data and data.name or nil
        if name then
          nameCache[uri] = name
          onName(name)
          return
        end
      end
      fetchViaScrape(kind, id, function(name)
        nameCache[uri] = name or false
        onName(name)
      end)
    end
  )
end

local function refresh()
  ensureAccessToken(function(token, err)
    if not token then
      if err and currentName ~= "<auth failed>" then
        currentUri = nil
        currentName = "<auth failed>"
        notify()
      end
      return
    end
    if currentName == "<auth failed>" then
      currentName = nil
      notify()
    end
    hs.http.asyncGet(
      "https://api.spotify.com/v1/me/player",
      { Authorization = "Bearer " .. token },
      function(status, body)
        -- 204 = device idle (paused too long). Keep the last known context
        -- so the tooltip stays useful instead of going blank between sessions.
        if status == 204 then return end
        if status ~= 200 then
          log.w("player poll: status=" .. tostring(status))
          return
        end
        local data = hs.json.decode(body)
        -- smart_shuffle lives on the player object; capture it before the
        -- context early-return so an external shuffle change still updates it.
        if data then
          local smart = data.smart_shuffle == true
          if smart ~= currentSmartShuffle then
            currentSmartShuffle = smart
            notify()
          end
        end
        local ctx = data and data.context or nil
        local uri = ctx and ctx.uri or nil
        if uri == currentUri then return end
        currentUri = uri
        local function setName(name)
          if name == currentName then return end
          currentName = name
          notify()
        end
        if not uri then
          setName(nil)
        elseif ctx.type == "collection" then
          setName("Liked Songs")
        else
          fetchName(token, uri, setName)
        end
      end
    )
  end)
end

-- Dev-mode apps get tight per-endpoint-group quotas (Feb 2026 API changes);
-- the library group (/v1/me/library*) answers 429 with a multi-hour
-- Retry-After once exhausted. Track the lockout so we stop hitting the group
-- until it expires and can tell the user when liking will work again.
local libraryRetryAt = 0

local function parseRetryAfter(headers)
  for k, v in pairs(headers or {}) do
    if k:lower() == "retry-after" then return tonumber(v) or 3600 end
  end
  return 3600
end

-- Seconds left on the library-group lockout, or nil when not locked out.
local function libraryLockedFor()
  local remain = libraryRetryAt - hs.timer.secondsSinceEpoch()
  return remain > 0 and remain or nil
end

local function noteLibraryRateLimit(headers)
  local secs = parseRetryAfter(headers)
  libraryRetryAt = hs.timer.secondsSinceEpoch() + secs
  log.w("library endpoints rate-limited; retry in " .. math.floor(secs) .. "s")
end

-- Liked-state for a single track. Cache is just the current track — Spotify
-- can be liked/unliked from any client, but re-checking on every track switch
-- keeps the badge fresh enough. No periodic re-poll: the library endpoint
-- group's dev-mode quota is small enough that polling earns the multi-hour
-- 429 lockout above, which also breaks like/unlike.
local function refreshLiked(trackId)
  if not trackId then
    if currentTrackId ~= nil or currentLiked ~= nil then
      currentTrackId, currentLiked = nil, nil
      notify()
    end
    return
  end
  if trackId == currentTrackId and currentLiked ~= nil then return end
  currentTrackId = trackId
  if libraryLockedFor() then
    if currentLiked ~= nil then
      currentLiked = nil
      notify()
    end
    return
  end
  ensureAccessToken(function(token)
    if not token then
      if currentLiked ~= nil then
        currentLiked = nil
        notify()
      end
      return
    end
    -- Spotify migrated /v1/me/tracks/contains → /v1/me/library/contains in
    -- March 2026; the old endpoint silently 403s for development-mode apps.
    -- New endpoint takes URIs (spotify:track:ID) instead of bare IDs.
    local uri = hs.http.encodeForQuery("spotify:track:" .. trackId)
    hs.http.asyncGet(
      "https://api.spotify.com/v1/me/library/contains?uris=" .. uri,
      { Authorization = "Bearer " .. token },
      function(status, body, headers)
        -- Track ID may have changed while the request was in flight.
        if trackId ~= currentTrackId then return end
        local liked = nil
        if status == 200 then
          local data = hs.json.decode(body)
          if type(data) == "table" and type(data[1]) == "boolean" then
            liked = data[1]
          end
        elseif status == 429 then
          noteLibraryRateLimit(headers)
        else
          log.w("liked-check: status=" .. tostring(status))
        end
        if liked ~= currentLiked then
          currentLiked = liked
          notify()
        end
      end
    )
  end)
end

-- Persist the playlist list to disk so a Hammerspoon restart doesn't trigger
-- ~30 API requests just to repopulate. Stored alongside its fetch time so the
-- usual freshness check still applies after a reload.
local function savePlaylistsCache()
  if not playlistsCache then return end
  local f = io.open(PLAYLISTS_CACHE_PATH, "w")
  if not f then return end
  f:write(hs.json.encode({ fetchedAt = playlistsFetchedAt, playlists = playlistsCache }))
  f:close()
end

local function loadPlaylistsCache()
  local f = io.open(PLAYLISTS_CACHE_PATH, "r")
  if not f then return end
  local body = f:read("*a")
  f:close()
  local ok, data = pcall(hs.json.decode, body)
  if ok and data and data.playlists then
    playlistsCache = data.playlists
    playlistsFetchedAt = data.fetchedAt or 0
  end
end

local function fetchUserId(callback)
  if currentUserId then callback(currentUserId) return end
  ensureAccessToken(function(token)
    if not token then callback(nil) return end
    hs.http.asyncGet(
      "https://api.spotify.com/v1/me",
      { Authorization = "Bearer " .. token },
      function(status, body)
        if status ~= 200 then
          log.w("get user: status=" .. tostring(status))
          callback(nil)
          return
        end
        local data = hs.json.decode(body)
        currentUserId = data and data.id or nil
        callback(currentUserId)
      end
    )
  end)
end

-- Walks /v1/me/playlists pages and returns the WHOLE library — playlists you own
-- and ones you follow — each tagged with `owned` so the menu can route them: Add
-- to Playlist shows owned only (you can't add tracks to playlists you don't own),
-- Play Playlist shows everything. We keep the API's native return order (roughly
-- "most recent"); Spotify no longer exposes the per-playlist timestamps needed to
-- reproduce any specific Library sort, so re-sorting would cost one request per
-- playlist for a worse result. Cached for PLAYLISTS_FRESH_SEC.
local function fetchPlaylists(callback)
  callback = callback or function() end
  local now = hs.timer.secondsSinceEpoch()
  if playlistsCache and (now - playlistsFetchedAt) < PLAYLISTS_FRESH_SEC then
    callback(playlistsCache)
    return
  end
  if playlistsFetching then
    callback(playlistsCache)
    return
  end
  playlistsFetching = true
  local function done(result)
    playlistsFetching = false
    callback(result)
  end
  fetchUserId(function(uid)
    if not uid then done(nil) return end
    ensureAccessToken(function(token)
      if not token then done(nil) return end
      local results = {}
      local function fetchPage(url)
        hs.http.asyncGet(url, { Authorization = "Bearer " .. token }, function(status, body)
          if status ~= 200 then
            log.w("playlists page: status=" .. tostring(status))
            done(playlistsCache)
            return
          end
          local data = hs.json.decode(body)
          if data and data.items then
            for _, p in ipairs(data.items) do
              -- p.owner is absent on rare malformed entries; skip those.
              if p.id and p.owner then
                table.insert(results, {
                  id = p.id,
                  name = p.name,
                  owned = p.owner.id == uid,
                  imageUrl = p.images and p.images[1] and p.images[1].url or nil,
                  uri = "spotify:playlist:" .. p.id,
                })
              end
            end
          end
          if data and data.next then
            fetchPage(data.next)
          else
            playlistsCache = results
            playlistsFetchedAt = hs.timer.secondsSinceEpoch()
            savePlaylistsCache()
            done(results)
          end
        end)
      end
      fetchPage("https://api.spotify.com/v1/me/playlists?limit=50")
    end)
  end)
end

-- Spotify renamed POST/DELETE /v1/playlists/{id}/tracks → /items in the
-- February 2026 Web API migration; the old endpoint 404s for new apps.
local function addToPlaylist(playlistId, trackId, callback)
  callback = callback or function() end
  ensureAccessToken(function(token)
    if not token then
      hs.alert.show("Spotify: re-authenticate to add to playlist")
      callback(false)
      return
    end
    local url = "https://api.spotify.com/v1/playlists/" .. playlistId .. "/items"
    local body = hs.json.encode({ uris = { "spotify:track:" .. trackId } })
    hs.http.doAsyncRequest(
      url, "POST", body,
      { Authorization = "Bearer " .. token, ["Content-Type"] = "application/json" },
      function(status, response)
        if status == 200 or status == 201 then
          callback(true)
        else
          log.e("addToPlaylist failed: status=" .. tostring(status) .. " body=" .. tostring(response))
          callback(false)
        end
      end
    )
  end)
end


-- Playlist cover art for items not in the library list (e.g. Discover Weekly /
-- Release Radar, which you play but don't follow). /v1/playlists/{id}?fields=images
-- works for normal playlists; editorial/algorithmic ones 404 (Nov-2024
-- deprecation), so fall back to scraping og:image off the public page.
local function fetchImageViaScrape(id, onUrl)
  local url = "https://open.spotify.com/playlist/" .. id
  hs.http.asyncGet(url, { ["User-Agent"] = "Mozilla/5.0" }, function(status, body)
    if status ~= 200 or not body then onUrl(nil) return end
    local img = body:match('<meta property="og:image" content="([^"]+)"')
    onUrl(img and decodeEntities(img) or nil)
  end)
end

local function fetchPlaylistImage(token, uri, onUrl)
  local cached = imageCache[uri]  -- stores `false` for known-misses, like nameCache
  if cached ~= nil then onUrl(cached or nil) return end
  local id = uri:match("^spotify:playlist:(.+)$")
  if not id then onUrl(nil) return end
  hs.http.asyncGet(
    "https://api.spotify.com/v1/playlists/" .. id .. "?fields=images",
    { Authorization = "Bearer " .. token },
    function(status, body)
      if status == 200 then
        local data = hs.json.decode(body)
        local imgs = data and data.images
        local url = imgs and imgs[1] and imgs[1].url or nil
        if url then imageCache[uri] = url; onUrl(url); return end
      end
      fetchImageViaScrape(id, function(url)
        imageCache[uri] = url or false
        onUrl(url)
      end)
    end
  )
end

-- Distinct playlists from /v1/me/player/recently-played, most-recent first (the
-- endpoint returns plays newest-first; we keep the first hit per playlist). This
-- is the only API surface that exposes algorithmic playlists you've played but
-- don't follow (Discover Weekly, Release Radar), so the menu pins these on top of
-- Play Playlist to mirror the app's Library "Recents" view. Names/covers come
-- from the library cache when present, else a per-playlist lookup.
local function fetchRecentlyPlayed(callback)
  callback = callback or function() end
  local now = hs.timer.secondsSinceEpoch()
  if recentlyPlayedCache and (now - recentlyPlayedFetchedAt) < RECENTLY_PLAYED_FRESH_SEC then
    callback(recentlyPlayedCache)
    return
  end
  ensureAccessToken(function(token)
    if not token then callback(nil) return end
    hs.http.asyncGet(
      "https://api.spotify.com/v1/me/player/recently-played?limit=50",
      { Authorization = "Bearer " .. token },
      function(status, body)
        if status ~= 200 then
          log.w("recently-played: status=" .. tostring(status))
          callback(nil)
          return
        end
        local data = hs.json.decode(body)
        if not (data and data.items) then callback(nil) return end
        local nameById, imageById = {}, {}
        for _, p in ipairs(playlistsCache or {}) do
          nameById[p.id] = p.name
          imageById[p.id] = p.imageUrl
        end
        local seen = {}
        local results = {}
        for _, item in ipairs(data.items) do
          local ctx = item.context
          if ctx and ctx.type == "playlist" and ctx.uri and not seen[ctx.uri] then
            seen[ctx.uri] = true
            local id = ctx.uri:match("^spotify:playlist:(.+)$")
            if id then
              table.insert(results, {
                id = id,
                uri = ctx.uri,
                playedAt = item.played_at,
                name = nameById[id] or nameCache[ctx.uri] or nil,
                imageUrl = imageById[id] or imageCache[ctx.uri] or nil,
              })
            end
          end
        end
        local function finish()
          recentlyPlayedCache = results
          recentlyPlayedFetchedAt = hs.timer.secondsSinceEpoch()
          callback(results)
        end
        -- Sentinel keeps the count above zero until the loop finishes dispatching,
        -- so a synchronous cache-hit callback can't call finish() prematurely.
        local pending = 1
        local function maybeFinish()
          if pending == 0 then finish() end
        end
        for _, r in ipairs(results) do
          if not r.name then
            pending = pending + 1
            fetchName(token, r.uri, function(name)
              r.name = name or r.uri
              pending = pending - 1
              maybeFinish()
            end)
          end
          if not r.imageUrl then
            pending = pending + 1
            fetchPlaylistImage(token, r.uri, function(url)
              r.imageUrl = url or nil
              pending = pending - 1
              maybeFinish()
            end)
          end
        end
        pending = pending - 1
        maybeFinish()
      end
    )
  end)
end

local function setShuffle(state, cb)
  cb = cb or function() end
  ensureAccessToken(function(token)
    if not token then cb() return end
    hs.http.doAsyncRequest(
      "https://api.spotify.com/v1/me/player/shuffle?state=" .. tostring(state),
      "PUT", "", { Authorization = "Bearer " .. token },
      function() cb() end
    )
  end)
end

-- Forward decl: playContext calls queueSmartTracks for mode == "smart".
local queueSmartTracks

-- Modes: "play" (shuffle off), "shuffle" (on), "smart" (on + queue recs).
-- Web API is the only reliable way to start an arbitrary context (AppleScript
-- only resumes the current track for collection URIs). If no active device
-- (Spotify closed), launch the app and retry once.
local function playContext(contextUri, mode)
  if not contextUri then return end
  mode = mode or "play"
  local function attempt(canRetry)
    setShuffle(mode ~= "play", function()
      ensureAccessToken(function(token)
        if not token then
          hs.alert.show("Spotify: re-authenticate to play")
          return
        end
        local body = hs.json.encode({ context_uri = contextUri })
        local hdrs = { Authorization = "Bearer " .. token, ["Content-Type"] = "application/json" }
        hs.http.doAsyncRequest(
          "https://api.spotify.com/v1/me/player/play", "PUT", body, hdrs,
          function(status, response)
            if status == 200 or status == 202 or status == 204 then
              if mode == "smart" then queueSmartTracks(contextUri) end
              return
            end
            if status == 404 and canRetry then
              hs.application.launchOrFocus("Spotify")
              hs.timer.doAfter(1.5, function() attempt(false) end)
              return
            end
            log.e("playContext " .. mode .. " failed: " .. tostring(status) .. " " .. tostring(response))
          end
        )
      end)
    end)
  end
  attempt(true)
end

-- "Smart shuffle" emulation: pull 20 tracks from the context, fan out 4
-- /v1/recommendations calls (the endpoint caps seeds at 5 per call), dedupe
-- and queue the results so they interleave with the context's own tracks
-- under shuffle. Spotify deprecated this endpoint for new dev-mode apps in
-- Nov 2024, so calls may 404; alert only if every batch fails.
local SMART_SEED_COUNT = 20
local SMART_SEEDS_PER_CALL = 5
local SMART_RECS_PER_CALL = 5
queueSmartTracks = function(contextUri)
  local seedsUrl
  local pid = contextUri:match("^spotify:playlist:(.+)$")
  if pid then
    seedsUrl = "https://api.spotify.com/v1/playlists/" .. pid ..
      "/items?fields=items(track(id))&limit=" .. SMART_SEED_COUNT
  elseif contextUri:match(":collection$") then
    seedsUrl = "https://api.spotify.com/v1/me/library/tracks?limit=" .. SMART_SEED_COUNT
  else
    return
  end
  ensureAccessToken(function(token)
    if not token then return end
    hs.http.asyncGet(seedsUrl, { Authorization = "Bearer " .. token }, function(s, b)
      if s ~= 200 then return end
      local d = hs.json.decode(b)
      local seeds = {}
      for _, it in ipairs((d and d.items) or {}) do
        if it.track and it.track.id then table.insert(seeds, it.track.id) end
      end
      if #seeds == 0 then return end
      local batches = {}
      for i = 1, #seeds, SMART_SEEDS_PER_CALL do
        local batch = {}
        for j = i, math.min(i + SMART_SEEDS_PER_CALL - 1, #seeds) do
          table.insert(batch, seeds[j])
        end
        table.insert(batches, batch)
      end
      local pending, successes, queued = #batches, 0, {}
      for _, batch in ipairs(batches) do
        hs.http.asyncGet(
          "https://api.spotify.com/v1/recommendations?limit=" .. SMART_RECS_PER_CALL ..
            "&seed_tracks=" .. table.concat(batch, ","),
          { Authorization = "Bearer " .. token },
          function(rs, rb)
            pending = pending - 1
            if rs == 200 then
              successes = successes + 1
              local rd = hs.json.decode(rb)
              for _, t in ipairs((rd and rd.tracks) or {}) do
                if t.uri and not queued[t.uri] then
                  queued[t.uri] = true
                  hs.http.doAsyncRequest(
                    "https://api.spotify.com/v1/me/player/queue?uri=" ..
                      hs.http.encodeForQuery(t.uri),
                    "POST", "", { Authorization = "Bearer " .. token },
                    function() end
                  )
                end
              end
            end
            if pending == 0 and successes == 0 then
              hs.alert.show("Smart shuffle: recommendations API unavailable")
            end
          end
        )
      end
    end)
  end)
end

local function playLikedSongs(mode)
  fetchUserId(function(uid)
    if not uid then
      hs.alert.show("Spotify: re-authenticate to play Liked Songs")
      return
    end
    playContext("spotify:user:" .. uid .. ":collection", mode)
  end)
end

local function rateLimitAlert(verb, waitSecs)
  hs.alert.show(("Spotify: %s blocked by rate limit, try again in ~%d min")
    :format(verb, math.max(1, math.ceil(waitSecs / 60))))
end

local function setLiked(trackId, liked, verb)
  local wait = libraryLockedFor()
  if wait then
    rateLimitAlert(verb, wait)
    return
  end
  ensureAccessToken(function(token)
    if not token then
      hs.alert.show("Spotify: re-authenticate to " .. verb)
      return
    end
    local method = liked and "PUT" or "DELETE"
    -- Migrated alongside /contains: PUT/DELETE /v1/me/tracks → /v1/me/library.
    local uri = hs.http.encodeForQuery("spotify:track:" .. trackId)
    hs.http.doAsyncRequest(
      "https://api.spotify.com/v1/me/library?uris=" .. uri,
      method,
      "",
      { Authorization = "Bearer " .. token, ["Content-Type"] = "application/json" },
      function(status, _, headers)
        if status == 429 then
          noteLibraryRateLimit(headers)
          rateLimitAlert(verb, libraryLockedFor() or 3600)
          return
        end
        if status ~= 200 then
          log.e(verb .. " failed: status=" .. tostring(status))
          hs.alert.show("Spotify: " .. verb .. " failed (" .. tostring(status) .. ")")
          return
        end
        if trackId == currentTrackId and currentLiked ~= liked then
          currentLiked = liked
          notify()
        end
      end
    )
  end)
end

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

-- Parse a non-empty SPOTIFY_QUERY result line into the backend state table.
-- Pure (no hs.*), so it's unit-testable in isolation.
local function parseSpotifyState(result)
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
    artPath = nil,
    trackId = trackId,
    shuffle = shuffle == "true",
  }
end

module.getState = function()
  local ok, result = hs.osascript.applescript(SPOTIFY_QUERY)
  if not ok or type(result) ~= "string" or result == "" then
    return { running = false }
  end
  return parseSpotifyState(result)
end

module.next = function() hs.spotify.next() end
module.previous = function() hs.spotify.previous() end
module.playpause = function() hs.spotify.playpause() end
module.play = function() hs.spotify.play() end
module.getPosition = function() return hs.spotify.getPosition() end
module.setPosition = function(sec) hs.spotify.setPosition(sec) end
-- AppleScript toggles shuffle on the local app synchronously and without Web API
-- auth. It can't exit Spotify's real Smart Shuffle (a platform limitation), which
-- the menu reflects by showing Smart Shuffle as read-only.
module.setShuffling = function(on)
  hs.osascript.applescript('tell application "Spotify" to set shuffling to ' .. tostring(on))
end

module.appName = "Spotify"
module.supportsSmartShuffle = true
module.supportsReauth = true
-- Accent for the "liked" heart on the pill (a Spotify-ish green).
module.likedColor = { red = 0.07, green = 0.5, blue = 0.24 }
-- Pure helpers exposed for unit tests (see tests/). Not part of the backend
-- interface pill.lua depends on.
module._test = {
  parseSpotifyState = parseSpotifyState,
  parseRetryAfter = parseRetryAfter,
  singleFlight = singleFlight,
}

module.getName = function() return currentName end
module.getUri = function() return currentUri end
module.getLiked = function() return currentLiked end
module.getSmartShuffle = function() return currentSmartShuffle end
module.refresh = refresh
module.refreshLiked = refreshLiked
module.like = function(trackId) if trackId then setLiked(trackId, true, "like") end end
module.unlike = function(trackId) if trackId then setLiked(trackId, false, "unlike") end end
module.getPlaylists = function() return playlistsCache end
module.refreshPlaylists = fetchPlaylists
module.addToPlaylist = function(playlistId, trackId, cb)
  if playlistId and trackId then addToPlaylist(playlistId, trackId, cb) end
end
module.playContext = playContext
module.playLikedSongs = playLikedSongs
module.getRecentlyPlayed = function() return recentlyPlayedCache end
module.refreshRecentlyPlayed = fetchRecentlyPlayed

-- ---------------------------------------------------------------------------
-- Guided Web API setup (optional)
-- ---------------------------------------------------------------------------
-- Wraps authenticate() so the user never edits init.lua or hand-copies IDs.
-- Reached from the right-click menu ("Enable Spotify extras…") and offered once
-- on the first unauthenticated run. A per-user Spotify app is unavoidable
-- (free dev-mode apps are capped at 25 manually-added users), so the wizard
-- guides app creation rather than shipping a shared key.

local OFFER_SETTING_KEY = "Hammertunes.spotifyExtrasOfferShown"

-- True when the Web API has no usable credentials yet.
local function needsSetup()
  loadCreds()
  return not (cachedClientId and cachedRefreshToken)
end

-- Consent -> Client ID -> approval. Each dialog is modal; cancelling any step
-- (or an empty Client ID) aborts with no state change.
local function setupWizard()
  local choice = hs.dialog.blockAlert(
    "Enable Spotify extras?",
    "Adds playlists, like/unlike, Play Liked Songs, and the playing-from name " ..
    "to the menu.\n\n" ..
    "It's free. You create a Spotify API key with limited permissions (just " ..
    "playback and your playlists/library) and approve it on Spotify's own " ..
    "site, so the spoon never sees your password. Everything it stores - the " ..
    "login and cached playlists - stays on your Mac.",
    "Set it up", "Not now"
  )
  if choice ~= "Set it up" then return end

  -- Pre-stage the redirect URI on the clipboard and open the dashboard so the
  -- user can paste both pieces without leaving the flow.
  hs.pasteboard.setContents(REDIRECT_URI)
  hs.urlevent.openURL("https://developer.spotify.com/dashboard")

  local btn, clientId = hs.dialog.textPrompt(
    "Paste your Spotify Client ID",
    "In the dashboard that just opened:\n" ..
    "  1. Create app\n" ..
    "  2. Set the Redirect URI to (already copied to your clipboard):\n" ..
    "       " .. REDIRECT_URI .. "\n" ..
    "  3. Copy the app's Client ID and paste it below.",
    "", "Continue", "Cancel"
  )
  if btn ~= "Continue" then return end
  clientId = (clientId or ""):gsub("%s+", "")
  if clientId == "" then
    hs.alert.show("Spotify setup cancelled (no Client ID)")
    return
  end
  module.authenticate(clientId)
end

module.needsSetup = needsSetup
module.setup = setupWizard
-- Menu label for the setup item, kept here so pill.lua stays backend-agnostic.
module.setupLabel = "Enable Spotify extras…"

module.start = function(changeCallback)
  onChange = changeCallback
  loadCreds()
  loadPlaylistsCache()
  if needsSetup() then
    log.i("not authenticated; skipping context fetch")
    -- Offer the guided setup once, ever (deferred so the pill renders first).
    -- The flag is set when shown, not on success, so declining doesn't re-prompt.
    if not hs.settings.get(OFFER_SETTING_KEY) then
      hs.settings.set(OFFER_SETTING_KEY, true)
      hs.timer.doAfter(1.5, setupWizard)
    end
    return
  end
  hs.timer.doAfter(0.5, refresh)
  -- fetchPlaylists is throttled by PLAYLISTS_FRESH_SEC, so this is a no-op
  -- when the just-loaded disk cache is still fresh; otherwise it refreshes.
  hs.timer.doAfter(1.0, function() fetchPlaylists() end)
  hs.timer.doAfter(1.5, function() fetchRecentlyPlayed() end)
end

module.stop = function()
  if authServer then authServer:stop() end
  if authServerTimer then authServerTimer:stop() end
  authServer, authServerTimer, onChange = nil, nil, nil
  accessToken, accessExpiry = nil, 0
  currentUri, currentName = nil, nil
  currentTrackId, currentLiked, currentSmartShuffle = nil, nil, nil
  currentUserId, playlistsCache, playlistsFetching, playlistsFetchedAt = nil, nil, false, 0
  recentlyPlayedCache, recentlyPlayedFetchedAt = nil, 0
  -- nameCache intentionally preserved: pure URI→name mapping, safe to keep.
end

module.authenticate = function(clientId)
  loadCreds()
  clientId = clientId or cachedClientId
  if not clientId then
    hs.alert.show("Spotify auth: pass clientId on first call")
    return
  end
  saveClientId(clientId)

  local verifier = b64url(urandom(48))
  local challenge = pkceChallenge(verifier)
  local state = b64url(urandom(16))

  if authServer then authServer:stop() end
  if authServerTimer then authServerTimer:stop() end
  authServer = hs.httpserver.new(false, false)
  authServer:setName("spotify-auth")
  authServer:setPort(AUTH_PORT)
  authServer:setCallback(function(_method, path)
    local code = path:match("[?&]code=([^&]+)")
    local recvState = path:match("[?&]state=([^&]+)")
    if not (code and recvState == state) then
      return "Authorization failed or state mismatch.", 400, {}
    end
    hs.timer.doAfter(0.1, function()
      local body = "client_id=" .. hs.http.encodeForQuery(clientId) ..
        "&grant_type=authorization_code" ..
        "&code=" .. hs.http.encodeForQuery(code) ..
        "&redirect_uri=" .. hs.http.encodeForQuery(REDIRECT_URI) ..
        "&code_verifier=" .. hs.http.encodeForQuery(verifier)
      hs.http.asyncPost(
        "https://accounts.spotify.com/api/token",
        body,
        { ["Content-Type"] = "application/x-www-form-urlencoded" },
        function(status, response)
          if authServer then
            authServer:stop()
            authServer = nil
          end
          if status ~= 200 then
            hs.alert.show("Spotify auth failed: " .. tostring(status))
            log.e("auth POST: " .. tostring(status) .. " " .. tostring(response))
            return
          end
          local data = hs.json.decode(response)
          if not (data and data.refresh_token) then
            hs.alert.show("Spotify auth: no refresh_token in response")
            return
          end
          saveRefreshToken(data.refresh_token)
          accessToken = data.access_token
          accessExpiry = hs.timer.secondsSinceEpoch() + (data.expires_in or 3600)
          log.i("auth saved; granted scope=" .. tostring(data.scope))
          hs.alert.show("Spotify auth saved")
          hs.timer.doAfter(0.5, refresh)
        end
      )
    end)
    return "Spotify authorization complete. You can close this tab.", 200, {}
  end)
  authServer:start()
  -- If the user never completes the redirect, don't leave the server bound.
  authServerTimer = hs.timer.doAfter(120, function()
    if authServer then authServer:stop() end
    authServer, authServerTimer = nil, nil
  end)

  -- show_dialog=true forces Spotify to re-prompt. Without this, a user who has
  -- previously approved the app gets silently re-granted the OLD scope set,
  -- even when SCOPES has changed — the new scopes never make it onto the token.
  local authUrl = "https://accounts.spotify.com/authorize" ..
    "?response_type=code" ..
    "&client_id=" .. hs.http.encodeForQuery(clientId) ..
    "&scope=" .. hs.http.encodeForQuery(SCOPES) ..
    "&redirect_uri=" .. hs.http.encodeForQuery(REDIRECT_URI) ..
    "&state=" .. state ..
    "&show_dialog=true" ..
    "&code_challenge_method=S256" ..
    "&code_challenge=" .. challenge
  hs.urlevent.openURL(authUrl)
  hs.alert.show("Spotify: complete auth in your browser")
end

return module

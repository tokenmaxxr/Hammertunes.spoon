local t = require("helper")

local function withImages(fn)
  local saved = hs
  local requests, loads = {}, 0
  hs = {
    http = { asyncGet = function(url, _, callback)
      requests[#requests + 1] = { url = url, finish = callback }
    end },
    image = { imageFromPath = function(path) loads = loads + 1; return { path = path } end },
  }
  local ok, err = pcall(fn, t.loadModule("images.lua"), requests, function() return loads end)
  hs = saved
  if not ok then error(err, 0) end
end

t.test("images: reset discards stale HTTP responses without clearing a new request", function()
  withImages(function(images, requests, loads)
    local notifications = 0
    local cache = images.newCache(2, { onLoad = function() notifications = notifications + 1 end })
    cache.getUrl("cover")
    cache.reset()
    cache.getUrl("cover")
    requests[1].finish(200, "old body")
    cache.getUrl("cover")
    t.eq(#requests, 2)
    t.eq(loads(), 0)
    t.eq(notifications, 0)
    requests[2].finish(200, "new body")
    t.ok(cache.getUrl("cover"))
    t.eq(notifications, 1)
  end)
end)

t.test("images: capacity evicts one least-used entry and preserves failures", function()
  withImages(function(images, requests)
    local cache = images.newCache(2)
    cache.getUrl("a"); requests[1].finish(200, "a")
    cache.getUrl("b"); requests[2].finish(404, "missing")
    cache.getUrl("a")
    cache.getUrl("c"); requests[3].finish(200, "c")
    t.ok(cache.getUrl("a"))
    t.ok(cache.getUrl("c"))
    t.eq(#requests, 3)
    cache.getUrl("b"); requests[4].finish(404, "missing")
    cache.getUrl("b")
    t.eq(#requests, 4)
  end)
end)

t.test("images: menu selection over 100 covers stays warm across repeated renders", function()
  withImages(function(images, requests)
    local rightclick = t.loadModule("rightclick.lua")
    local playlists, recent = {}, {}
    for i = 1, 130 do
      playlists[i] = { id = "p" .. i, uri = "u" .. i, owned = true, imageUrl = "p" .. i }
      recent[i] = { id = "r" .. i, uri = "r" .. i, imageUrl = "r" .. i }
    end
    local ctx = { running = true, trackId = "track", api = {
      getPlaylists = function() return playlists end,
      getRecentlyPlayed = function() return recent end,
    } }
    local cache = images.newCache(100)
    for _ = 1, 3 do
      local selection = rightclick.selectEntries(ctx)
      for _, entries in ipairs({ selection.owned, selection.play }) do
        t.eq(#entries, 25)
        for _, entry in ipairs(entries) do cache.getUrl(entry.imageUrl) end
      end
      for _, request in ipairs(requests) do
        if not request.done then request.finish(200, "image"); request.done = true end
      end
    end
    t.eq(#requests, 50)
  end)
end)

-- Shared image loading and caching for the pill artwork and menu icons.
-- A cache maps a URL or file path to a ready hs.image (or false for a known
-- failure, so bad keys aren't refetched). URL misses fetch asynchronously;
-- path misses load synchronously (the file is already local).
local module = {}

-- Write an HTTP image body to a temp file and load it as an hs.image, or nil if
-- the body is missing/unreadable.
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

-- Resize via canvas, not hs.image:setSize. A setSize'd file-backed image won't
-- draw as a menu-item icon (verified: a system image and the full-size file
-- image both render, but the setSize copy shows nothing). Drawing into a canvas
-- yields a fresh bitmap that renders like the pill's own canvas icon.
module.scaleTo = function(img, size)
  local c = hs.canvas.new({ x = 0, y = 0, w = size, h = size })
  c:appendElements({
    type = "image",
    image = img,
    imageScaling = "scaleToFit",
    frame = { x = 0, y = 0, w = size, h = size },
  })
  local out = c:imageFromCanvas()
  c:delete()
  return out
end

-- newCache(max, opts) -> { getUrl, getPath, reset }. The whole cache is dropped
-- once it holds `max` entries (simple, allocation-free eviction).
--  * opts.transform - runs on freshly fetched images before caching.
--  * opts.onLoad    - fires after an async fetch stores a usable image.
module.newCache = function(max, opts)
  opts = opts or {}
  local cache, count, fetching = {}, 0, {}

  local function put(key, img)
    if count >= max then cache, count = {}, 0 end
    cache[key] = img or false
    count = count + 1
  end

  -- Local file: load synchronously, no async fetch needed.
  local function getPath(path)
    if not path then return nil end
    local cached = cache[path]
    if cached ~= nil then return cached or nil end
    local img = hs.image.imageFromPath(path)
    put(path, img)
    return img
  end

  -- Returns the cached image, or nil while a miss kicks off the async fetch.
  local function getUrl(url)
    if not url then return nil end
    local cached = cache[url]
    if cached ~= nil then return cached or nil end
    if fetching[url] then return nil end
    fetching[url] = true
    hs.http.asyncGet(url, nil, function(code, body)
      fetching[url] = nil
      local img = (code == 200 and bodyToImage(body)) or nil
      if img and opts.transform then img = opts.transform(img) end
      put(url, img)
      if img and opts.onLoad then opts.onLoad() end
    end)
    return nil
  end

  local function reset()
    cache, count, fetching = {}, 0, {}
  end

  return { getPath = getPath, getUrl = getUrl, reset = reset }
end

return module

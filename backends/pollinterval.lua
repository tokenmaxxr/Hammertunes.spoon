-- Shared now-playing poll interval (seconds between expensive AppleScript or
-- MediaRemote reads). Both backends load this as a sibling via dofile, like init.lua
-- and the test harness load backend files, so neither backend hard-codes the key,
-- default, or clamp logic — they live here once and can't drift apart. The value
-- is persisted under a single hs.settings key, so the right-click "Refresh
-- interval" choice applies consistently whichever backend is active.
--
-- Shorter intervals poll more often: more responsive, but more battery. The
-- caller (rightclick.lua) warns on the short end; this module only clamps to a
-- sane range.
local M = {}

local KEY = "Hammertunes.pollIntervalSec"
local DEFAULT, MIN, MAX = 3, 1, 60
local value = DEFAULT

local function clamp(sec)
  sec = math.floor((tonumber(sec) or DEFAULT) + 0.5)
  return math.max(MIN, math.min(MAX, sec))
end

-- Re-read the persisted value into this instance's cache. Call from a backend's
-- start() so a switch (which reloads the backend) picks up the shared choice.
function M.load()
  if hs.settings then value = clamp(hs.settings.get(KEY) or DEFAULT) end
  return value
end

-- Current interval in seconds (cached; cheap enough to call on every poll tick).
function M.get() return value end

-- Persist a new interval (clamped) and update this instance's cache.
function M.set(sec)
  value = clamp(sec)
  if hs.settings then hs.settings.set(KEY, value) end
  return value
end

M.DEFAULT = DEFAULT
M.MIN = MIN
M.MAX = MAX

return M

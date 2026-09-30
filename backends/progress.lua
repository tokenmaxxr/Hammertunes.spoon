-- Shared progress helpers for the polling backends. Loaded as a sibling (like
-- pollinterval.lua) so both backends share one implementation instead of each
-- carrying a near-identical copy that can drift.
local M = {}

-- Clamp a position/duration pair to a 0..1 progress fraction.
function M.calcProgress(posSec, durMs)
  if durMs <= 0 then return 0 end
  return math.max(0, math.min(1, posSec / (durMs / 1000)))
end

-- Advance a throttled snapshot's progress by the wall-clock seconds since it was
-- read, so the bar moves smoothly between reads. Returns a copy (the cached
-- snapshot keeps its read-time progress); a paused or zero-duration snapshot is
-- returned unchanged.
function M.interpolate(snap, elapsed)
  if not snap or not snap.playing or (snap.durMs or 0) <= 0 then return snap end
  local posSec = snap.progress * (snap.durMs / 1000) + elapsed
  local out = {}
  for k, v in pairs(snap) do out[k] = v end
  out.progress = M.calcProgress(posSec, snap.durMs)
  return out
end

return M

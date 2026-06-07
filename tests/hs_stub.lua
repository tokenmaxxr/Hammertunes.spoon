-- Minimal fake `hs` global so the Spoon's modules load and the pure helpers run
-- outside Hammerspoon. Only the bits the tested code touches at load time or
-- inside the pure helpers are stubbed; everything else is intentionally absent
-- (the pure layer must not reach for it).

local hs = {}

-- Loggers: any method (.e/.w/.i/.d/.f) is a silent no-op.
hs.logger = {
  new = function()
    return setmetatable({}, { __index = function() return function() end end })
  end,
}

-- Clock: deterministic. Tests set hs.timer._now to control "now".
hs.timer = {
  _now = 0,
  secondsSinceEpoch = function() return hs.timer._now end,
}

return hs

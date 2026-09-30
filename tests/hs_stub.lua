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

-- image: imageFromPath returns a truthy stub when the file exists, nil otherwise.
-- Tests can plant fake image stubs by writing to hs.image._files[path].
hs.image = {
  _files = {},
  imageFromPath = function(path)
    return hs.image._files[path] or nil
  end,
}

-- json.decode: minimal parser for the flat objects the MediaRemote JXA emits -
-- string, number, and null values only, no nesting. Enough for readMediaRemote.
hs.json = {
  decode = function(s)
    if type(s) ~= "string" then return nil end
    local out = {}
    -- string values: "key":"value" (no escaped quotes in our JXA output)
    for k, v in s:gmatch('"([%w_]+)"%s*:%s*"([^"]*)"') do out[k] = v end
    -- number values: "key":123.45
    for k, v in s:gmatch('"([%w_]+)"%s*:%s*(%-?%d[%d%.]*)') do out[k] = tonumber(v) end
    return out
  end,
}

-- application.get: tests set hs.application._running["Music"] = <truthy> to make
-- the app appear running. Absent by default (apps not running).
-- applicationsForBundleID is the cheap running-check the Apple Music hot path
-- uses; it resolves the bundle id back to a name via _bundleNames and reports
-- the same _running state, so tests keep toggling _running["Music"] as before.
hs.application = {
  _running = {},
  _bundleNames = { ["com.apple.Music"] = "Music", ["com.spotify.client"] = "Spotify" },
  get = function(name) return hs.application._running[name] end,
  applicationsForBundleID = function(bundleID)
    local name = hs.application._bundleNames[bundleID]
    local app = name and hs.application._running[name]
    return app and { app } or {}
  end,
}

-- settings: in-memory NSUserDefaults stand-in so persisted prefs (poll interval,
-- "Show Other Sources") round-trip in tests. Tests can clear hs.settings._store.
hs.settings = {
  _store = {},
  get = function(key) return hs.settings._store[key] end,
  set = function(key, value) hs.settings._store[key] = value end,
}

-- osascript: programmable so getState() can be driven end-to-end. Tests assign
-- hs.osascript._applescript / ._javascript to functions that dispatch on the
-- script body (each query is identifiable by a substring) and return
-- (ok, result) the way hs.osascript really does. Default: failure.
hs.osascript = {
  _applescript = function(_) return false, nil end,
  applescript = function(s) return hs.osascript._applescript(s) end,
}

-- execute: the synchronous MediaRemote read (FALLBACK first tick, libArtUrl)
-- runs osascript via hs.execute; tests drive it by assigning hs._exec to return
-- its stdout. Default: empty output (no MediaRemote data).
hs._exec = function(_) return "" end
hs.execute = function(cmd) return hs._exec(cmd) end

-- task: the steady-state MediaRemote refresh runs asynchronously via hs.task.
-- The stub fires the done-callback SYNCHRONOUSLY on :start(), driving it from
-- the same hs._exec stdout seam, so getState()'s async refresh is deterministic
-- in tests (the snapshot is updated by the time :start() returns).
hs.task = {
  new = function(launchPath, doneCb, args)
    local cmd = launchPath .. " " .. table.concat(args or {}, " ")
    return {
      start = function(self)
        if doneCb then doneCb(0, hs._exec(cmd), "") end
        return self
      end,
    }
  end,
}

return hs

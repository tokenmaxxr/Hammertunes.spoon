local t = require("helper")

-- Fresh instances of the shared module (each backend dofiles its own copy; they
-- coordinate through the single hs.settings key, not a shared Lua table).
local function fresh() return t.loadModule("backends/pollinterval.lua") end

t.test("pollinterval: clamps to the sane range and rounds to whole seconds", function()
  local p = fresh()
  t.eq(p.set(0), p.MIN)        -- below MIN -> MIN
  t.eq(p.set(999), p.MAX)      -- above MAX -> MAX
  t.eq(p.set(2.6), 3)          -- rounded
  t.eq(p.set("nonsense"), p.DEFAULT) -- non-number -> default
end)

t.test("pollinterval: set persists and get reflects the cached value", function()
  hs.settings._store = {}
  local p = fresh()
  t.eq(p.get(), p.DEFAULT)     -- default before anything is stored
  p.set(5)
  t.eq(p.get(), 5)
  t.eq(hs.settings._store["Hammertunes.pollIntervalSec"], 5)
end)

t.test("pollinterval: load reads the shared key (consistent across backends)", function()
  hs.settings._store = {}
  -- One backend's instance persists a choice...
  local a = fresh()
  a.set(10)
  -- ...a second instance (the other backend, loaded fresh on switch) picks it up.
  local b = fresh()
  t.eq(b.get(), b.DEFAULT)     -- not yet loaded
  t.eq(b.load(), 10)           -- load() pulls the shared value
  t.eq(b.get(), 10)
end)

t.test("pollinterval: load falls back to default when nothing is stored", function()
  hs.settings._store = {}
  local p = fresh()
  t.eq(p.load(), p.DEFAULT)
end)

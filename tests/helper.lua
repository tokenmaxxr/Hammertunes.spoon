-- Tiny zero-dependency test harness. No busted/luarocks needed: run with
--   lua tests/run.lua
-- Specs call M.test("name", fn) and assert with M.eq / M.ok. M.report() prints
-- a summary and returns a process exit code (0 = all passed).

local M = { passed = 0, failed = 0, failures = {} }

-- Repo root (with trailing slash), derived from this file's own path so
-- loadModule works regardless of the current working directory.
local thisPath = debug.getinfo(1, "S").source:sub(2)
M.ROOT = thisPath:gsub("tests[/\\]helper%.lua$", "")

-- dofile a Spoon source file (path relative to repo root) and return its module.
function M.loadModule(rel)
  return dofile(M.ROOT .. rel)
end

-- Deep equality. Numbers compare within a small epsilon so progress fractions
-- (e.g. 15/200) don't fail on float representation.
local function eq(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) == "number" then return math.abs(a - b) < 1e-9 end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do
    if not eq(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end
M.deepEqual = eq

local function show(v)
  if type(v) ~= "table" then return tostring(v) end
  local parts = {}
  for k, x in pairs(v) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(x) end
  table.sort(parts)
  return "{ " .. table.concat(parts, ", ") .. " }"
end

local current = "?"

function M.test(name, fn)
  current = name
  local ok, err = pcall(fn)
  if ok then
    M.passed = M.passed + 1
  else
    M.failed = M.failed + 1
    M.failures[#M.failures + 1] = name .. ": " .. tostring(err)
  end
end

function M.ok(cond, msg)
  if not cond then error(msg or "expected truthy", 2) end
end

function M.eq(got, want, msg)
  if not eq(got, want) then
    error((msg and (msg .. ": ") or "") ..
      "got " .. show(got) .. ", want " .. show(want), 2)
  end
end

function M.report()
  print(string.format("\n%d passed, %d failed", M.passed, M.failed))
  for _, f in ipairs(M.failures) do print("  FAIL  " .. f) end
  return M.failed == 0 and 0 or 1
end

return M

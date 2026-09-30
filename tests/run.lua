-- Test runner. Sets up a fake `hs` global, loads every *_spec, prints a summary.
-- Usage (from the repo root):  lua tests/run.lua

local here = debug.getinfo(1, "S").source:sub(2)
local testsDir = here:gsub("[^/\\]*$", "")
package.path = testsDir .. "?.lua;" .. package.path

_G.hs = require("hs_stub")
local t = require("helper")

require("pollinterval_spec")
require("spotify_spec")
require("applemusic_spec")
require("interface_spec")
require("init_spec")
require("menubar_spec")
require("pill_spec")
require("rightclick_spec")
require("images_spec")

os.exit(t.report())

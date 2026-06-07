local t = require("helper")
local menubar = t.loadModule("menubar.lua")
local T = menubar._test

t.test("menubar: truncate leaves short strings unchanged", function()
  t.eq(T.truncate("hello", 10), "hello")
  t.eq(T.truncate("hello", 5), "hello")
end)

t.test("menubar: truncate keeps (max-1) chars plus an ellipsis", function()
  t.eq(T.truncate("hello world", 5), "hell…")
end)

t.test("menubar: truncate counts characters, not bytes (utf8)", function()
  t.eq(T.truncate("café", 10), "café")       -- 4 chars, under the limit
end)

t.test("menubar: truncate handles nil as empty string", function()
  t.eq(T.truncate(nil, 5), "")
end)

t.test("menubar: playMode maps click modifiers to playback modes", function()
  t.eq(T.playMode({ cmd = true, alt = true }), "smart")
  t.eq(T.playMode({ cmd = true }), "shuffle")
  t.eq(T.playMode({}), "play")
  t.eq(T.playMode(nil), "play")
end)

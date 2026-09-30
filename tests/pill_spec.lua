local t = require("helper")

local function withPill(fn)
  local saved = hs
  local icons = {}
  hs = {
    styledtext = { new = function(text) return text end },
    drawing = { getTextDrawingSize = function(text) return { w = #text * 6, h = 12 } end },
    canvas = { new = function(frame)
      return {
        appendElements = function() end,
        imageFromCanvas = function() return { width = frame.w } end,
        delete = function() end,
      }
    end },
  }
  local ok, err = pcall(function()
    local pill = t.loadModule("pill.lua").new({ setIcon = function(_, image)
      icons[#icons + 1] = image.width
    end }, {})
    fn(pill, icons)
  end)
  hs = saved
  if not ok then error(err, 0) end
end

t.test("pill: artwork arrival does not change the width reserved for a new song", function()
  withPill(function(pill, widths)
    pill.update("A long first song", { leadingImage = {}, leadingImageKey = "old" })
    pill.update("Next", { reserveLeadingImage = true })
    local finalWidth = widths[#widths]
    t.ok(finalWidth < widths[1], "shorter songs should still shrink to their final size")
    pill.update("Next", { reserveLeadingImage = true, leadingImage = {}, leadingImageKey = "new" })
    t.eq(widths[#widths], finalWidth)
  end)
end)

t.test("pill: empty transition holds width, then shorter and artless tracks can resize", function()
  withPill(function(pill, widths)
    pill.update("A long first song", { leadingImage = {}, leadingImageKey = "old" })
    local oldWidth = widths[1]
    pill.update("♪", { holdWidth = true })
    t.eq(widths[#widths], oldWidth)
    pill.update("Next")
    t.ok(widths[#widths] < oldWidth)
    local nextWidth = widths[#widths]
    pill.update("♪", { holdWidth = true })
    t.eq(widths[#widths], nextWidth)
    pill.update("♪")
    t.ok(widths[#widths] < nextWidth, "stopping should release the held width")
  end)
end)

t.test("pill: reset forgets held width and repeated renders stay cached", function()
  withPill(function(pill, widths)
    pill.update("A long first song")
    pill.update("A long first song")
    t.eq(#widths, 1)
    pill.reset()
    pill.update("♪", { holdWidth = true })
    t.ok(widths[#widths] < widths[1])
  end)
end)

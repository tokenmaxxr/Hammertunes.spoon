local t = require("helper")

local function withPill(fn)
  local saved = hs
  local icons = {}
  local calls = { styled = 0, measured = 0, progressWidths = {} }
  local baseOpts = { font = { name = ".AppleSystemUIFont", size = 12 },
    color = { white = 1 }, progressBg = { white = 0.5 } }
  hs = {
    styledtext = { new = function(text)
      calls.styled = calls.styled + 1
      return text
    end },
    drawing = { getTextDrawingSize = function(text)
      calls.measured = calls.measured + 1
      return { w = #text * 6, h = 12 }
    end },
    canvas = { new = function(frame)
      return {
        appendElements = function(_, ...)
          for _, element in ipairs({...}) do
            if element.fillColor == baseOpts.progressBg then
              calls.progressWidths[#calls.progressWidths + 1] = element.frame.w
            end
          end
        end,
        imageFromCanvas = function() return { width = frame.w } end,
        delete = function() end,
      }
    end },
  }
  local ok, err = pcall(function()
    local pill = t.loadModule("pill.lua").new({ setIcon = function(_, image)
      icons[#icons + 1] = image.width
    end }, baseOpts)
    fn(pill, icons, calls, baseOpts)
  end)
  hs = saved
  if not ok then error(err, 0) end
end

t.test("pill: progress redraws reuse only the current text layout", function()
  withPill(function(pill, widths, calls, baseOpts)
    local function update(text, subtitle, liked)
      pill.update(text, { subtitle = subtitle, likedOverlay = liked, force = true })
    end
    update("Song", "Artist", true)
    t.eq(calls.measured, 3)
    pill.update("Song", { subtitle = "Artist", likedOverlay = true, progress = 0.2 })
    t.eq(#widths, 2)
    t.eq(calls.measured, 3)
    t.eq(calls.styled, 3)
    update("Next", "Artist", true)
    t.eq(calls.measured, 6)
    update("Song", "Artist", true)
    t.eq(calls.measured, 9, "only the current layout is retained")
    update("Song", "Other", true)
    t.eq(calls.measured, 12)
    baseOpts.font.size = 14
    update("Song", "Other", true)
    t.eq(calls.measured, 15)
    baseOpts.color.white = 0.5
    update("Song", "Other", true)
    t.eq(calls.measured, 18)
    update("Song", "Other", false)
    t.eq(calls.measured, 20)
    pill.reset()
    update("Song", "Other", false)
    t.eq(calls.measured, 22)
  end)
end)

t.test("pill: forced updates bypass the image cache without losing held width", function()
  withPill(function(pill, widths, calls)
    pill.update("A long first song", { progress = 0.501 })
    t.eq(calls.progressWidths[1], widths[1] * 0.5)
    pill.update("A long first song", { progress = 0.5001 })
    t.eq(#widths, 1)
    pill.update("A long first song", { progress = 0.5001, force = true })
    t.eq(#widths, 2)
    t.eq(calls.progressWidths[2], widths[2] * 0.5001)
    pill.update("♪", { holdWidth = true, force = true })
    t.eq(widths[3], widths[1])
  end)
end)

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

local module = {}

local DEFAULTS = {
  font = { name = ".AppleSystemUIFont", size = 12 },
  color = { white = 1 },
  bg = { red = 0, green = 0, blue = 0, alpha = 0.85 },
  padX = 14,
  radius = 10,
  height = 24,
}

local function merge(base, overrides)
  local out = {}
  for k, v in pairs(base) do out[k] = v end
  if overrides then
    for k, v in pairs(overrides) do out[k] = v end
  end
  return out
end

module.image = function(text, opts)
  opts = merge(DEFAULTS, opts)
  local styled = hs.styledtext.new(text, { font = opts.font, color = opts.color })
  local mainSize = hs.drawing.getTextDrawingSize(styled)
  local mainW = math.ceil(mainSize.w)
  local mainH = math.ceil(mainSize.h)

  local subStyled, subW, subH
  if opts.subtitle and opts.subtitle ~= "" then
    if type(opts.subtitle) == "string" then
      local subFont = opts.subtitleFont or { name = opts.font.name, size = 9 }
      local subColor = opts.subtitleColor or { white = 1, alpha = 0.8 }
      subStyled = hs.styledtext.new(opts.subtitle, { font = subFont, color = subColor })
    else
      subStyled = opts.subtitle
    end
    local subSize = hs.drawing.getTextDrawingSize(subStyled)
    subW = math.ceil(subSize.w)
    subH = math.ceil(subSize.h)
  end

  local h = opts.height
  local leadingImage = opts.leadingImage
  local artSize = opts.artSize or (h - 6)
  local artRadius = opts.artRadius or 3
  local artGap = opts.artGap or 6
  local leadingW = leadingImage and (artSize + artGap) or 0

  local heartStyled, heartW, heartH = nil, 0, 0
  if opts.likedOverlay then
    local heartSize = opts.likedFontSize or 9
    local heartColor = opts.likedColor or { red = 0.07, green = 0.5, blue = 0.24 }
    heartStyled = hs.styledtext.new("♥", {
      font = { name = opts.font.name, size = heartSize },
      color = heartColor,
    })
    local hSize = hs.drawing.getTextDrawingSize(heartStyled)
    heartW = math.ceil(hSize.w)
    heartH = math.ceil(hSize.h)
  end

  local heartGap = heartStyled and (opts.likedGap or 4) or 0
  local subRowW = (subW or 0) + (heartStyled and (heartGap + heartW) or 0)
  local innerW = math.max(mainW, subRowW)
  local w = leadingW + innerW + opts.padX * 2
  local canvas = hs.canvas.new({ x = 0, y = 0, w = w, h = h })

  local progress = opts.progress
  if progress and progress > 0 and opts.progressBg then
    local clipped = math.max(0, math.min(1, progress))
    local splitX = clipped * w
    canvas:appendElements({
      type = "rectangle",
      action = "clip",
      roundedRectRadii = { xRadius = opts.radius, yRadius = opts.radius },
      frame = { x = 0, y = 0, w = w, h = h },
    }, {
      type = "rectangle",
      action = "fill",
      fillColor = opts.progressBg,
      frame = { x = 0, y = 0, w = splitX, h = h },
    }, {
      type = "rectangle",
      action = "fill",
      fillColor = opts.bg,
      frame = { x = splitX, y = 0, w = w - splitX, h = h },
    }, { type = "resetClip" })
  else
    canvas:appendElements({
      type = "rectangle",
      action = "fill",
      roundedRectRadii = { xRadius = opts.radius, yRadius = opts.radius },
      fillColor = opts.bg,
      frame = { x = 0, y = 0, w = w, h = h },
    })
  end

  if leadingImage then
    local artX = opts.padX
    local artY = (h - artSize) / 2
    canvas:appendElements({
      type = "rectangle",
      action = "clip",
      roundedRectRadii = { xRadius = artRadius, yRadius = artRadius },
      frame = { x = artX, y = artY, w = artSize, h = artSize },
    }, {
      type = "image",
      image = leadingImage,
      imageScaling = "scaleToFit",
      frame = { x = artX, y = artY, w = artSize, h = artSize },
    }, { type = "resetClip" })
  end

  local textX = opts.padX + leadingW
  if subStyled then
    canvas:appendElements({
      type = "text",
      text = subStyled,
      frame = { x = textX, y = 1, w = innerW + 2, h = subH },
    }, {
      type = "text",
      text = styled,
      frame = { x = textX, y = h - mainH - 1, w = innerW + 2, h = mainH },
    })
  else
    canvas:appendElements({
      type = "text",
      text = styled,
      frame = {
        x = textX,
        y = (h - mainH) / 2,
        w = innerW + 2,
        h = mainH,
      },
    })
  end

  if heartStyled then
    canvas:appendElements({
      type = "text",
      text = heartStyled,
      frame = { x = textX + innerW - heartW, y = 1, w = heartW + 2, h = heartH },
    })
  end

  local img = canvas:imageFromCanvas()
  canvas:delete()
  return img
end

-- Stateful wrapper around a menubar item: quantizes progress, caches the last
-- visual state, and skips setIcon when nothing changed.
module.new = function(menu, baseOpts, opts)
  opts = opts or {}
  local progressSteps = opts.progressSteps or 100
  local lastKey = nil

  local function update(text, renderOpts)
    renderOpts = renderOpts or {}
    local progress = renderOpts.progress
    local step = progress and math.floor(progress * progressSteps + 0.5) or 0
    local progressQ = progress and step / progressSteps or nil
    local key = string.format("%s|%d|%s|%s|%s",
      text, step, tostring(renderOpts.subtitle or ""), renderOpts.leadingImageKey or "",
      renderOpts.likedOverlay and "1" or "0")
    if key == lastKey then return end
    lastKey = key
    menu:setIcon(module.image(text, merge(baseOpts, {
      progress = progressQ,
      subtitle = renderOpts.subtitle,
      leadingImage = renderOpts.leadingImage,
      likedOverlay = renderOpts.likedOverlay,
      likedColor = renderOpts.likedColor,
    })), false)
  end

  local function reset()
    lastKey = nil
  end

  return { update = update, reset = reset }
end

return module

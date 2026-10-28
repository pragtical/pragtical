-- Deterministic versions of audiovisu's polygon strips, without audio or plugins.
-- Shared by drawing tests and the polygon visualization benchmark.
local fixture = {}
fixture.names = { "battery", "spikes", "scope" }
fixture.width, fixture.height = 560, 320
fixture.background = { 2, 4, 8, 255 }

local function draw_path(draw, points, width, color)
  local polygon, count = {}, #points
  for i = 1, count do
    local before, after = points[math.max(1, i - 1)], points[math.min(count, i + 1)]
    local dx, dy = after[1] - before[1], after[2] - before[2]
    local length = math.max(0.001, math.sqrt(dx * dx + dy * dy))
    local nx, ny = -dy / length * width / 2, dx / length * width / 2
    polygon[i] = { points[i][1] + nx, points[i][2] + ny }
    polygon[count * 2 - i + 1] = { points[i][1] - nx, points[i][2] - ny }
  end
  draw(polygon, color)
end

function fixture.draw(name, frame, draw)
  local w, h = fixture.width, fixture.height
  local cx, cy, time = w / 2, h / 2, frame * 1.25
  local wave, levels = {}, {}
  for i = 1, 256 do
    wave[i] = math.sin(i * 0.11 + frame) * 0.5 + math.sin(i * 0.47 - frame * 0.3) * 0.22
  end
  for i = 1, 24 do levels[i] = 0.2 + (math.sin(i * 0.6 + frame) + 1) * 0.3 end
  local colors = { {240, 100, 30}, {40, 230, 100}, {110, 90, 240} }
  local function glow(points, width, color)
    for _, layer in ipairs { {4, 24}, {2, 70}, {1, 255} } do
      draw_path(draw, points, width * layer[1], {color[1], color[2], color[3], layer[2]})
    end
  end

  if name == "battery" then
    for trail = 2, 0, -1 do
      for ribbon = 1, 3 do
        local points = {}
        local phase = time * 0.6 - trail * 0.07 + ribbon * 2.1
        for i = 0, 128 do
          local a = i / 128 * math.pi * 2
          local band = levels[i % #levels + 1]
          local sample = wave[math.floor(i / 128 * 255) + 1]
          local radius = 0.3 + math.sin(a * 3 + phase) * 0.07 + band * 0.06
          points[i + 1] = {
            cx + math.cos(a + phase * 0.35) * w * radius,
            cy + math.sin(a * 2 - phase) * h * 0.24 + sample * h * 0.12
          }
        end
        glow(points, math.max(1, h / 250), colors[ribbon])
      end
    end
  elseif name == "spikes" then
    local radius, ring = math.min(w, h) * 0.22, {}
    for i = 0, 96 do
      local angle = i / 96 * math.pi * 2 + time * 0.12
      local band = levels[i % #levels + 1]
      local inner = radius * (0.8 + 0.65 * 0.35)
      local outer = inner + radius * (0.15 + band * 0.85 + 0.25 * 0.25)
      local cosine, sine = math.cos(angle), math.sin(angle)
      ring[i + 1] = { cx + cosine * inner, cy + sine * inner }
      if i < 96 then
        glow({ring[i + 1], {cx + cosine * outer, cy + sine * outer}},
          math.max(1, w / 650), colors[i % #colors + 1])
      end
    end
    glow(ring, math.max(1, w / 500), colors[3])
  elseif name == "scope" then
    for trail = 3, 0, -1 do
      local points = {}
      for i = 1, 256 do
        points[i] = { w * (i - 1) / 255,
          cy + wave[i] * h * (0.32 - trail * 0.025) + math.sin(i / 25 + time) * trail * h / 300 }
      end
      glow(points, math.max(1, h / 250), colors[trail % #colors + 1])
    end
  else
    error("unknown visualization: " .. name)
  end
end

return fixture

-- Draws Frontra-style polygon models and captures them to PNG.
--
-- Run once per backend and compare the generated images:
--   PRAGTICAL_RENDERER=surface ./scripts/run-local build run scripts/lua/benchmarks/poly_capture.lua /tmp/frontra-poly-surface
--   PRAGTICAL_RENDERER=sdlgpu  ./scripts/run-local build run scripts/lua/benchmarks/poly_capture.lua /tmp/frontra-poly-sdlgpu
--
-- The window capture uses renderer.to_canvas(window, ...). The offscreen
-- capture renders the same shapes into a canvas and saves it directly, which
-- helps compare window-native polygon replay with canvas-native polygon draws.

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local renwindow = require "renwindow"
local canvas = require "canvas"

local WIDTH, HEIGHT = 960, 640
local SCALE = 4

local C = {
  bg = { 8, 12, 26, 255 },
  panel = { 19, 28, 45, 255 },
  grid = { 44, 67, 91, 110 },
  player = { 25, 177, 187, 255 },
  player_dark = { 13, 91, 113, 255 },
  player_armor = { 17, 128, 138, 255 },
  skin = { 243, 176, 92, 255 },
  gun = { 245, 196, 77, 255 },
  robot = { 106, 112, 140, 255 },
  robot_dark = { 47, 49, 70, 255 },
  robot_light = { 161, 167, 191, 255 },
  red = { 236, 68, 72, 255 },
  red_dark = { 126, 28, 32, 255 },
  boss = { 84, 89, 119, 255 },
  frame_dark = { 43, 39, 52, 255 },
  frame_mid = { 68, 65, 78, 255 },
  frame_light = { 125, 130, 151, 255 },
  field = { 38, 78, 52, 255 },
  field_hi = { 64, 150, 88, 255 },
  text = { 224, 232, 241, 255 },
}

local function arg_after_script(default)
  if not ARGS then return default end
  for i = 1, #ARGS do
    if ARGS[i] and ARGS[i]:match("scripts/lua/benchmarks/poly_capture%.lua$") then
      return ARGS[i + 1] or default
    end
  end
  return default
end

local function rgba(c, a)
  return { c[1], c[2], c[3], a or c[4] or 255 }
end

local function draw_poly(ops, pts, color)
  ops.draw_poly(pts, color)
end

local function poly_at(x, y, s, pts, flip)
  local out = {}
  for _, pt in ipairs(pts) do
    local px = flip and -pt[1] or pt[1]
    out[#out + 1] = { x + px * s, y + pt[2] * s }
  end
  return out
end

local function ellipse_poly(cx, cy, rx, ry, segments)
  local pts = {}
  for i = 0, segments do
    local t = 2 * math.pi * i / segments
    pts[#pts + 1] = { cx + math.cos(t) * rx, cy + math.sin(t) * ry }
  end
  return pts
end

local function draw_rect_poly(ops, x, y, w, h, color)
  draw_poly(ops, {
    { x, y }, { x + w, y }, { x + w, y + h }, { x, y + h },
  }, color)
end

local function draw_line_poly(ops, x1, y1, x2, y2, w, color)
  local dx, dy = x2 - x1, y2 - y1
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 0.001 then return end
  local ux, uy = -dy / len * w / 2, dx / len * w / 2
  draw_poly(ops, {
    { x1 + ux, y1 + uy }, { x1 - ux, y1 - uy },
    { x2 - ux, y2 - uy }, { x2 + ux, y2 + uy },
  }, color)
end

local function draw_background(ops)
  ops.draw_rect(0, 0, WIDTH, HEIGHT, C.bg, true)
  draw_rect_poly(ops, 34, 34, WIDTH - 68, HEIGHT - 68, C.panel)
  for x = 70, WIDTH - 70, 40 do
    draw_line_poly(ops, x, 50, x, HEIGHT - 50, 1, C.grid)
  end
  for y = 70, HEIGHT - 70, 40 do
    draw_line_poly(ops, 50, y, WIDTH - 50, y, 1, C.grid)
  end
end

local function draw_player(ops, x, y, s, flip)
  draw_poly(ops, ellipse_poly(x, y + 36 * s, 18 * s, 20 * s, 20), rgba(C.player, 34))
  draw_poly(ops, poly_at(x, y, s, {
    { -2, 8 }, { 14, 8 }, { 17, 14 }, { 13, 28 }, { 1, 28 }, { -5, 15 },
  }, flip), C.player_armor)
  draw_poly(ops, poly_at(x, y, s, {
    { 2, 10 }, { 11, 10 }, { 12, 25 }, { 0, 25 },
  }, flip), C.player)
  draw_poly(ops, poly_at(x, y, s, {
    { 0, 4 }, { 8, -3 }, { 16, 4 }, { 13, 12 }, { 3, 12 },
  }, flip), C.skin)
  draw_poly(ops, poly_at(x, y, s, {
    { -1, 0 }, { 12, -5 }, { 18, 0 }, { 13, 4 }, { 2, 4 },
  }, flip), C.player_dark)
  draw_poly(ops, poly_at(x, y, s, {
    { 12, 13 }, { 20, 12 }, { 20, 16 }, { 13, 18 },
  }, flip), C.skin)
  draw_poly(ops, poly_at(x, y, s, {
    { 18, 11 }, { 30, 10 }, { 32, 13 }, { 18, 15 },
  }, flip), C.gun)
  draw_poly(ops, poly_at(x, y, s, {
    { 1, 27 }, { 7, 27 }, { 6, 40 }, { -1, 40 },
  }, flip), C.player_dark)
  draw_poly(ops, poly_at(x, y, s, {
    { 8, 27 }, { 14, 27 }, { 18, 40 }, { 10, 40 },
  }, flip), C.player_dark)
end

local function draw_robot(ops, x, y, s)
  draw_poly(ops, ellipse_poly(x + 8 * s, y + 15 * s, 13 * s, 16 * s, 18), rgba(C.robot, 35))
  draw_poly(ops, poly_at(x, y, s, {
    { 3, 0 }, { 13, 0 }, { 16, 4 }, { 15, 11 }, { 1, 11 }, { 0, 4 },
  }), C.robot_dark)
  draw_poly(ops, poly_at(x, y, s, {
    { 1, 11 }, { 15, 11 }, { 16, 17 }, { 13, 28 }, { 3, 28 }, { 0, 17 },
  }), C.robot)
  draw_poly(ops, poly_at(x, y, s, {
    { 4, 14 }, { 12, 14 }, { 11, 25 }, { 5, 25 },
  }), rgba(C.robot_dark, 130))
  draw_poly(ops, poly_at(x, y, s, {
    { 0, 15 }, { -5, 18 }, { -4, 23 }, { 1, 20 },
  }), C.robot_dark)
  draw_poly(ops, poly_at(x, y, s, {
    { 16, 15 }, { 21, 18 }, { 20, 23 }, { 15, 20 },
  }), C.robot_dark)
  draw_rect_poly(ops, x + 4 * s, y + 5 * s, 3 * s, 3 * s, C.red)
  draw_rect_poly(ops, x + 10 * s, y + 5 * s, 3 * s, 3 * s, C.red)
end

local function draw_boss(ops, x, y, s)
  draw_poly(ops, ellipse_poly(x + 24 * s, y + 26 * s, 34 * s, 32 * s, 24), rgba(C.boss, 42))
  draw_poly(ops, poly_at(x, y, s, {
    { 8, 0 }, { 40, 0 }, { 47, 6 }, { 49, 18 }, { 42, 44 },
    { 47, 48 }, { 38, 52 }, { 10, 52 }, { 1, 48 }, { 6, 44 }, { -1, 18 }, { 1, 6 },
  }), C.boss)
  draw_poly(ops, poly_at(x, y, s, {
    { 4, 9 }, { 15, 6 }, { 15, 24 }, { 1, 27 }, { -1, 18 },
  }), C.robot_dark)
  draw_poly(ops, poly_at(x, y, s, {
    { 44, 9 }, { 33, 6 }, { 33, 24 }, { 47, 27 }, { 49, 18 },
  }), C.robot_dark)
  draw_poly(ops, poly_at(x, y, s, {
    { 11, 14 }, { 37, 14 }, { 34, 42 }, { 14, 42 },
  }), rgba(C.robot_dark, 130))
  draw_rect_poly(ops, x + 8 * s, y + 7 * s, 32 * s, 5 * s, C.red)
  draw_rect_poly(ops, x + 19 * s, y + 28 * s, 10 * s, 9 * s, C.red)
end

local function draw_main_frame(ops, x, y, s)
  draw_poly(ops, poly_at(x, y, s, {
    { 10, 0 }, { 110, 0 }, { 120, 15 }, { 115, 30 }, { 120, 45 },
    { 115, 122 }, { 120, 132 }, { 115, 136 }, { 5, 136 },
    { 0, 132 }, { 5, 122 }, { 0, 45 }, { 5, 30 }, { 0, 15 },
  }), C.frame_dark)
  draw_poly(ops, poly_at(x, y, s, {
    { 22, 14 }, { 98, 14 }, { 90, 118 }, { 30, 118 },
  }), C.frame_mid)
  draw_poly(ops, poly_at(x, y, s, {
    { 42, 32 }, { 78, 32 }, { 72, 56 }, { 48, 56 },
  }), C.frame_light)
  draw_rect_poly(ops, x - 20 * s, y + 10 * s, 20 * s, 116 * s, C.frame_mid)
  draw_rect_poly(ops, x + 120 * s, y + 10 * s, 20 * s, 116 * s, C.frame_mid)
  draw_rect_poly(ops, x + 36 * s, y + 54 * s, 48 * s, 38 * s, C.red_dark)
  draw_rect_poly(ops, x + 42 * s, y + 61 * s, 36 * s, 24 * s, C.red)
  for i = 1, 3 do
    local gy = y + ({ 24, 68, 116 })[i] * s
    draw_rect_poly(ops, x - 18 * s, gy - 4 * s, 18 * s, 8 * s, C.frame_mid)
    draw_rect_poly(ops, x - 26 * s, gy - 5 * s, 8 * s, 10 * s, C.red_dark)
  end
end

local function draw_field_scene(ops, x, y, s)
  draw_poly(ops, {
    { x, y + 84 * s }, { x + 220 * s, y + 84 * s },
    { x + 186 * s, y + 126 * s }, { x + 22 * s, y + 126 * s },
  }, C.field)
  for i = 0, 7 do
    local bx = x + (18 + i * 24) * s
    draw_line_poly(ops, bx, y + 82 * s, bx + 18 * s, y + 114 * s, 2 * s, C.field_hi)
    draw_line_poly(ops, bx + 8 * s, y + 88 * s, bx + 24 * s, y + 118 * s, 2 * s, C.field_hi)
  end
  draw_poly(ops, poly_at(x + 34 * s, y + 54 * s, s, {
    { 0, 34 }, { 0, 10 }, { 34, -4 }, { 68, 10 }, { 68, 34 },
  }), { 108, 38, 42, 255 })
  draw_poly(ops, poly_at(x + 34 * s, y + 54 * s, s, {
    { 8, 14 }, { 34, 2 }, { 60, 14 }, { 56, 18 }, { 34, 8 }, { 12, 18 },
  }), { 205, 82, 64, 255 })
end

local function draw_curve_cases(ops, x, y)
  draw_poly(ops, {
    { x, y + 90 }, { x + 150, y + 90 },
    { x + 150, y + 90, x + 76, y - 12, x, y + 90 },
  }, { 54, 204, 183, 210 })
  draw_poly(ops, {
    { x + 18, y + 92 }, { x + 166, y + 92 },
    { x + 166, y + 92, x + 142, y - 24, x + 46, y - 24, x + 18, y + 92 },
  }, { 248, 178, 66, 170 })
end

local function draw_scene(ops)
  draw_background(ops)
  draw_field_scene(ops, 72, 84, 1.25)
  draw_player(ops, 156, 338, SCALE, false)
  draw_player(ops, 290, 338, SCALE, true)
  draw_robot(ops, 424, 330, SCALE)
  draw_robot(ops, 514, 330, SCALE)
  draw_boss(ops, 622, 292, 3.1)
  draw_main_frame(ops, 112, 444, 1.0)
  draw_curve_cases(ops, 612, 488)
end

local function renderer_ops()
  return {
    draw_rect = renderer.draw_rect,
    draw_poly = renderer.draw_poly,
  }
end

local function canvas_ops(c)
  return {
    draw_rect = function(...) c:draw_rect(...) end,
    draw_poly = function(...) c:draw_poly(...) end,
  }
end

local output_dir = arg_after_script("/tmp/frontra-poly-captures")
local ok, err = common.mkdirp(output_dir)
if not ok then error(err or ("failed to create " .. output_dir)) end

config.draw_stats = false
config.fps = 1000

local window = core.window or renwindow.create("Frontra Polygon Capture", WIDTH, HEIGHT)
renderer.begin_frame(window)
renderer.set_clip_rect(0, 0, WIDTH, HEIGHT)
draw_scene(renderer_ops())
renderer.end_frame()

local window_capture = renderer.to_canvas(window, 0, 0, WIDTH, HEIGHT)
local window_path = output_dir .. PATHSEP .. "frontra-poly-window.png"
local saved, save_err = window_capture:save_image(window_path)
if not saved then error(save_err or ("failed to save " .. window_path)) end

local offscreen = canvas.new(WIDTH, HEIGHT, C.bg, true)
draw_scene(canvas_ops(offscreen))
offscreen:render()
local canvas_path = output_dir .. PATHSEP .. "frontra-poly-canvas.png"
saved, save_err = offscreen:save_image(canvas_path)
if not saved then error(save_err or ("failed to save " .. canvas_path)) end

print("Saved Frontra polygon captures:")
print("  " .. window_path)
print("  " .. canvas_path)
print("Run this script once with PRAGTICAL_RENDERER=surface and once with PRAGTICAL_RENDERER=sdlgpu, then compare PNGs.")

os.exit(0)

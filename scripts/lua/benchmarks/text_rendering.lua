local core = require "core"
local config = require "core.config"
local style = require "core.style"
local renwindow = require "renwindow"

local bench_window

local function find_script_argument()
  if not ARGS then return nil end
  for i = 1, #ARGS do
    local value = ARGS[i]
    if value and value:match("scripts/lua/benchmarks/text_rendering%.lua$") then
      return i
    end
  end
end

local function parse_inputs()
  local script_idx = find_script_argument()
  local frames = 240
  local rows = 140

  if script_idx and ARGS then
    local frames_arg = tonumber(ARGS[script_idx + 1])
    local rows_arg = tonumber(ARGS[script_idx + 2])
    if frames_arg and frames_arg >= 1 then frames = math.floor(frames_arg) end
    if rows_arg and rows_arg >= 1 then rows = math.floor(rows_arg) end
  end

  return frames, rows
end

local function percentile(values, pct)
  local index = math.max(1, math.min(#values, math.ceil(#values * pct)))
  return values[index]
end

local function summarize(times)
  table.sort(times)
  local total = 0
  for _, value in ipairs(times) do total = total + value end
  return {
    avg = total / #times,
    min = times[1],
    p50 = percentile(times, 0.50),
    p95 = percentile(times, 0.95),
    max = times[#times],
  }
end

local function print_summary(label, summary)
  print(string.format(
    "%-20s avg %.3fms | p50 %.3fms | p95 %.3fms | min %.3fms | max %.3fms",
    label,
    summary.avg * 1000,
    summary.p50 * 1000,
    summary.p95 * 1000,
    summary.min * 1000,
    summary.max * 1000
  ))
end

local function file_exists(path)
  local file = io.open(path, "rb")
  if file then
    file:close()
    return true
  end
  return false
end

local function make_font_group(fonts)
  local loaded = {}
  for _, spec in ipairs(fonts) do
    if file_exists(spec.path) then
      loaded[#loaded + 1] = renderer.font.load(spec.path, spec.size, spec.options)
    end
  end
  if #loaded == 1 then return loaded[1] end
  return renderer.font.group(loaded)
end

local function color_for_row(row, frame)
  local colors = {
    style.text or {230, 230, 230, 255},
    style.dim or {140, 140, 140, 255},
    style.accent or {120, 180, 255, 255},
    style.syntax and style.syntax.keyword or {220, 150, 90, 255},
    style.syntax and style.syntax.string or {150, 210, 120, 255},
  }
  return colors[((row + frame) % #colors) + 1]
end

local function begin_text_frame(label, frame)
  local w, h = bench_window:get_size()
  local bg = style.background or {30, 30, 30, 255}
  local selection = style.selection or {70, 80, 90, 255}
  local accent = style.accent or {120, 180, 255, 255}

  renderer.begin_frame(bench_window)
  renderer.set_clip_rect(0, 0, w, h)
  renderer.draw_rect(0, 0, w, h, bg)
  renderer.draw_rect(0, 0, w, 32 * SCALE, selection)
  renderer.draw_text(style.font, string.format("%s frame %d", label, frame), 12, 8, accent)
  return w, h
end

local hot_samples = {
  "local value = object:method(index, fallback) -- stable cached text",
  "if path ~= nil and #items >= limit then return item.text end",
  "renderer.draw_text(font, text, x, y, color) => glyph batch",
  "tabs\tindent\tcolumns\tcache\tclip\tbatch",
  "ffi != nil and a == b and c <= d and e >= f and g -> h",
}

local cold_samples = {
  "Greek alpha beta gamma delta theta lambda omega",
  "Cyrillic privet mir tekst glif atlas obnovlenie",
  "Latin accents cafe naive facade jalapeno ano cooperate",
  "Math forall exists sum integral approx not-equal arrows",
  "Emoji fallback 😀 😃 😄 😁 😆 😅 😂 🙂 😉 😍",
  "Symbols blocks lines stars bullets currency arrows",
}

local icon_samples = {
  "o", "f", "D", "C", "<", ">", "M", "5", "6", "7", "8", "9",
}

local function draw_hot_text(font, label, frame, rows)
  local w, h = begin_text_frame(label, frame)
  local line_h = math.max(1, font:get_height())
  local top = 42 * SCALE
  local columns = 3
  local col_w = math.floor((w - 24 * SCALE) / columns)
  local rows_per_col = math.max(1, math.floor((h - top - 8 * SCALE) / line_h))

  for i = 1, rows do
    local col = math.floor((i - 1) / rows_per_col)
    if col >= columns then break end
    local row = (i - 1) % rows_per_col
    local x = 12 * SCALE + col * col_w
    local y = top + row * line_h
    local sample = hot_samples[((i + frame) % #hot_samples) + 1]
    renderer.draw_text(
      font,
      string.format("%03d %s [%d]", i, sample, frame),
      x,
      y,
      color_for_row(i, frame)
    )
  end

  renderer.end_frame()
end

local function draw_cold_text(font, frame, rows)
  local w, h = begin_text_frame("text cold glyphs", frame)
  local line_h = math.max(1, font:get_height())
  local top = 42 * SCALE
  local columns = 2
  local col_w = math.floor((w - 24 * SCALE) / columns)
  local rows_per_col = math.max(1, math.floor((h - top - 8 * SCALE) / line_h))

  for i = 1, rows do
    local col = math.floor((i - 1) / rows_per_col)
    if col >= columns then break end
    local row = (i - 1) % rows_per_col
    local x = 12 * SCALE + col * col_w
    local y = top + row * line_h
    local sample = cold_samples[((i + frame) % #cold_samples) + 1]
    local suffix = string.char(33 + ((i + frame) % 90), 33 + ((i * 7 + frame) % 90))
    renderer.draw_text(
      font,
      string.format("%03d %s %s frame=%d", i, sample, suffix, frame),
      x,
      y,
      color_for_row(i, frame)
    )
  end

  renderer.end_frame()
end

local function draw_icon_text(font, icon_font, frame, rows)
  local w, h = begin_text_frame("text icons", frame)
  local line_h = math.max(font:get_height(), icon_font:get_height())
  local top = 42 * SCALE
  local columns = 4
  local col_w = math.floor((w - 24 * SCALE) / columns)
  local rows_per_col = math.max(1, math.floor((h - top - 8 * SCALE) / line_h))

  for i = 1, rows do
    local col = math.floor((i - 1) / rows_per_col)
    if col >= columns then break end
    local row = (i - 1) % rows_per_col
    local x = 12 * SCALE + col * col_w
    local y = top + row * line_h
    local icon = icon_samples[((i + frame) % #icon_samples) + 1]
    renderer.draw_text(icon_font, icon, x, y, color_for_row(i, frame))
    renderer.draw_text(
      font,
      string.format("item-%03d cached icon text %d", i, frame),
      x + 24 * SCALE,
      y,
      color_for_row(i + 2, frame)
    )
  end

  renderer.end_frame()
end

local function draw_clipped_text(font, icon_font, frame, rows)
  local w, h = begin_text_frame("text clipped", frame)
  local line_h = math.max(font:get_height(), icon_font:get_height())
  local tab_h = line_h + 10 * SCALE
  local y = 42 * SCALE

  for i = 1, math.min(rows, 36) do
    local tab_w = 112 * SCALE + (i % 5) * 18 * SCALE
    local x = 12 * SCALE + ((i - 1) % 6) * 146 * SCALE
    local row = math.floor((i - 1) / 6)
    local ty = y + row * (tab_h + 8 * SCALE)
    if ty + tab_h > h - 36 * SCALE then break end

    renderer.set_clip_rect(x, ty, tab_w, tab_h)
    renderer.draw_rect(x, ty, tab_w, tab_h, style.selection or {70, 80, 90, 255})
    renderer.draw_text(icon_font, "C", x + 6 * SCALE, ty + 5 * SCALE, color_for_row(i, frame))
    renderer.draw_text(
      font,
      string.format("tab-%02d very-long-title-%d.lua", i, frame),
      x + 26 * SCALE,
      ty + 5 * SCALE,
      color_for_row(i + 1, frame)
    )
  end

  renderer.set_clip_rect(0, 0, w, h)
  local status_y = h - line_h - 10 * SCALE
  renderer.draw_rect(0, status_y - 4 * SCALE, w, line_h + 8 * SCALE, style.line_highlight or {38, 42, 50, 255})
  for i = 1, 16 do
    local x = 12 * SCALE + (i - 1) * 78 * SCALE
    renderer.set_clip_rect(x, status_y - 2 * SCALE, 64 * SCALE, line_h + 4 * SCALE)
    renderer.draw_text(font, string.format("status-%02d-%d", i, frame), x, status_y, color_for_row(i, frame))
  end

  renderer.set_clip_rect(0, 0, w, h)
  renderer.end_frame()
end

local function run_phase(label, frames, draw)
  local warmup = math.min(30, math.max(5, math.floor(frames / 8)))
  for i = 1, warmup do draw(i) end

  local times = {}
  for i = 1, frames do
    local start = system.get_time()
    draw(i)
    times[#times + 1] = system.get_time() - start
  end

  print_summary(label, summarize(times))
end

local frames, rows = parse_inputs()
config.draw_stats = false
config.fps = 1000
bench_window = core.window or renwindow.create("Text Rendering Benchmark", 1280, 800)

local font_path = DATADIR .. PATHSEP .. "fonts" .. PATHSEP .. "JetBrainsMono-Regular.ttf"
local noto_path = DATADIR .. PATHSEP .. "fonts" .. PATHSEP .. "Noto-COLRv1.ttf"
local icon_path = DATADIR .. PATHSEP .. "fonts" .. PATHSEP .. "icons.ttf"

local gray_font = renderer.font.load(
  font_path,
  15 * SCALE,
  { antialiasing = "grayscale", ligatures = true }
)
local subpixel_font = renderer.font.load(
  font_path,
  15 * SCALE,
  { antialiasing = "subpixel", ligatures = true }
)
local cold_font = make_font_group({
  { path = font_path, size = 15 * SCALE, options = { antialiasing = "grayscale", ligatures = true } },
  { path = noto_path, size = 15 * SCALE, options = { antialiasing = "grayscale" } },
})
local icon_font = renderer.font.load(
  icon_path,
  18 * SCALE,
  { antialiasing = "grayscale", hinting = "full" }
)

print("Usage:")
print("  pragtical run -n scripts/lua/benchmarks/text_rendering.lua [frames] [rows]")
print(string.format("Frames: %d", frames))
print(string.format("Rows: %d", rows))
print(string.format("Window: %dx%d", bench_window:get_size()))
print(string.format("Font: %s", font_path))
print(string.format("Noto fallback: %s", file_exists(noto_path) and noto_path or "unavailable"))
print(string.format("Icon font: %s", icon_path))

run_phase("text hot grayscale", frames, function(frame)
  draw_hot_text(gray_font, "text hot grayscale", frame, rows)
end)
run_phase("text hot subpixel", frames, function(frame)
  draw_hot_text(subpixel_font, "text hot subpixel", frame, rows)
end)
run_phase("text cold glyphs", frames, function(frame)
  draw_cold_text(cold_font, frame, rows)
end)
run_phase("text icons", frames, function(frame)
  draw_icon_text(gray_font, icon_font, frame, rows)
end)
run_phase("text clipped", frames, function(frame)
  draw_clipped_text(gray_font, icon_font, frame, rows)
end)

os.exit(0)

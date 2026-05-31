-- Test script for codefold.lua core logic
-- Tests fold region detection, toggle, fold-all, unfold-all, translate functions
local test = require "core.test"
local Doc = require "core.doc"
local DocView = require "core.docview"
local core = require "core"
local command = require "core.command"
local config = require "core.config"
local common = require "core.common"
local style = require "core.style"
local syntax = require "core.syntax"

local source_path = debug.getinfo(1, "S").source:gsub("^@", "")
local source_root = common.dirname(
  common.dirname(common.dirname(common.dirname(source_path)))
)

local function dofile_from_source(relative_path)
  local candidates = {
    relative_path,
    source_root .. PATHSEP .. relative_path
  }
  for _, path in ipairs(candidates) do
    if system.get_file_info(path) then
      return dofile(path)
    end
  end
  error("cannot find test helper: " .. relative_path, 2)
end

local function write_file(path, content)
  local file, err = io.open(path, "wb")
  test.not_nil(file, err)
  file:write(content or "")
  file:close()
end

local function with_common_draw_text(fn)
  local original = common.draw_text
  local calls = {}
  common.draw_text = function(font, color, text, align, x, y, w, h)
    calls[#calls + 1] = {
      font = font,
      color = color,
      text = text,
      align = align,
      x = x,
      y = y,
      w = w,
      h = h
    }
    return x + font:get_width(tostring(text))
  end

  local ok, err = pcall(fn, calls)
  common.draw_text = original
  if not ok then error(err, 0) end
end

local function make_docview(lines)
  local doc = Doc(nil, nil, true)
  doc.lines = lines
  doc:reset_syntax()

  local view = DocView(doc)
  view.position.x = 0
  view.position.y = 0
  view.size.x = 320
  view.size.y = 200
  view.indentguide_indents = {}
  view.indentguide_indent_active = {}
  return view
end

local function make_c_doc(lines)
  require "plugins.language_c"
  local doc = Doc(nil, nil, true)
  doc.syntax = syntax.get("test.c")
  doc.lines = lines
  doc.highlighter:reset()
  return doc
end

local function make_php_doc(lines)
  dofile_from_source("subprojects/plugins/plugins/language_php.lua")
  local doc = Doc(nil, nil, true)
  doc.syntax = syntax.get("test.php")
  doc.lines = lines
  doc.highlighter:reset()
  return doc
end

-- Helper: compute line indent (same logic as in codefold.lua)
local function get_line_indent(doc, line, indent_size, dir)
  if line < 1 or line > #doc.lines then return -1 end
  local text = doc.lines[line]
  if not text or text == "\n" or text == "" then
    if dir then return get_line_indent(doc, line + dir, indent_size, dir) end
    return -1
  end
  local s, e = text:find("^%s*")
  if e == #text then
    if dir then return get_line_indent(doc, line + dir, indent_size, dir) end
    return -1
  end
  local n = 0
  for b in text:sub(s, e):gmatch(".") do
    n = n + (b == "\t" and indent_size or 1)
  end
  return n
end

local function get_effective_indent(doc, line, indent_size)
  local indent = get_line_indent(doc, line, indent_size)
  if indent >= 0 then return indent end
  local above = get_line_indent(doc, line - 1, indent_size, -1)
  local below = get_line_indent(doc, line + 1, indent_size, 1)
  if above >= 0 and below >= 0 then return math.max(above, below) end
  return above >= 0 and above or below
end

-- Helper: detect fold regions
local function detect_fold_regions(doc)
  local _, indent_size = doc:get_indent_info()
  local regions = {}
  local line_count = #doc.lines
  local line = 1
  while line <= line_count do
    local indent = get_effective_indent(doc, line, indent_size)
    if indent < 0 then
      line = line + 1
    else
      local next_line = line + 1
      if next_line > line_count then break end
      local next_indent = get_effective_indent(doc, next_line, indent_size)
      if next_indent > indent then
        local stop = next_line
        while stop < line_count do
          local peek_indent = get_effective_indent(doc, stop + 1, indent_size)
          if peek_indent < 0 then
            stop = stop + 1
          elseif peek_indent <= indent then
            break
          else
            stop = stop + 1
          end
        end
        regions[#regions + 1] = { indent = indent, start = line, stop = stop }
      end
      line = line + 1
    end
  end
  return regions
end

-- Helper: build fold_map/unfold_map
local function build_maps(doc_lines, regions, folded_indices)
  local hidden = {}
  for _, ri in ipairs(folded_indices) do
    local region = regions[ri]
    for l = region.start + 1, region.stop do
      hidden[l] = true
    end
  end
  local fold_map = {}
  local unfold_map = {}
  for real = 1, #doc_lines do
    if not hidden[real] then
      local virtual = #fold_map + 1
      fold_map[virtual] = real
      unfold_map[real] = virtual
    else
      unfold_map[real] = nil
    end
  end
  return fold_map, unfold_map
end

test.describe("codefold - region detection", function()
  test.test("detects flat regions", function()
    local doc = Doc(nil, nil, true)
    doc.lines = {
      "line1\n",    -- 1, indent 0
      "  line2\n",   -- 2, indent 2
      "  line3\n",   -- 3, indent 2
      "line4\n",     -- 4, indent 0
      "  line5\n",   -- 5, indent 2
      "    line6\n", -- 6, indent 4
      "  line7\n",   -- 7, indent 2
      "line8\n",     -- 8, indent 0
    }
    doc:reset_syntax()

    local regions = detect_fold_regions(doc)
    test.equal(#regions, 3, "expected 3 regions")
    test.equal(regions[1].start, 1)
    test.equal(regions[1].stop, 3)
    test.equal(regions[2].start, 4)
    test.equal(regions[2].stop, 7)
    test.equal(regions[3].start, 5)
    test.equal(regions[3].stop, 6)
  end)

  test.test("detects nested regions", function()
    local doc = Doc(nil, nil, true)
    doc.lines = {
      "line1\n",
      "  line2\n",
      "    line3\n",
      "      line4\n",
      "    line5\n",
      "  line6\n",
      "line7\n",
    }
    doc:reset_syntax()

    local regions = detect_fold_regions(doc)
    test.equal(#regions, 3, "expected 3 regions")
    test.equal(regions[1].start, 1)
    test.equal(regions[1].stop, 6)
    test.equal(regions[2].start, 2)
    test.equal(regions[2].stop, 5)
    test.equal(regions[3].start, 3)
    test.equal(regions[3].stop, 4)
  end)

  test.test("handles empty/blank lines", function()
    local doc = Doc(nil, nil, true)
    doc.lines = {
      "line1\n",
      "  line2\n",
      "\n",
      "  line4\n",
      "line5\n",
    }
    doc:reset_syntax()

    local regions = detect_fold_regions(doc)
    test.equal(#regions, 1, "expected 1 region")
    test.equal(regions[1].start, 1)
    test.equal(regions[1].stop, 4)
  end)

  test.test("tab-indented lines", function()
    local doc = Doc(nil, nil, true)
    doc.lines = {
      "line1\n",
      "\tline2\n",
      "\t\tline3\n",
      "\tline4\n",
      "line5\n",
    }
    doc:reset_syntax()

    local regions = detect_fold_regions(doc)
    test.equal(#regions, 2, "expected 2 regions")
    test.equal(regions[1].start, 1)
    test.equal(regions[1].stop, 4)
    test.equal(regions[2].start, 2)
    test.equal(regions[2].stop, 3)
  end)

  test.test("detects multiline block comment regions from tokens", function()
    local codefold = require "plugins.codefold"
    local doc = make_c_doc({
      "/**\n",
      " * Function that does something\n",
      " */\n",
      "function somefunction(){\n",
      "}\n",
    })
    doc.highlighter:get_line(1)

    local regions = codefold._test.detect_fold_regions(doc)

    test.equal(regions[1].kind, "comment")
    test.equal(regions[1].start, 1)
    test.equal(regions[1].stop, 3)
    test.equal(regions[1].hide_tail, false)
  end)

  test.test("block comment folds do not hide following code as tail", function()
    local codefold = require "plugins.codefold"

    local previous_start_folded = config.plugins.codefold.start_folded
    local previous_hide_tail = config.plugins.codefold.hide_tail_on_fold
    config.plugins.codefold.start_folded = true
    config.plugins.codefold.hide_tail_on_fold = true

    local doc = make_c_doc({
      "/**\n",
      " * Function that does something\n",
      " */\n",
      "function somefunction(){\n",
      "}\n",
    })
    local view = DocView(doc)
    local regions = codefold._test.detect_fold_regions(doc)
    codefold._test.apply_detected_regions(view, regions)

    test.ok(view.cf_hidden_lines[2])
    test.ok(view.cf_hidden_lines[3])
    test.is_nil(view.cf_hidden_lines[4])
    test.equal(view.cf_fold_map[1], 1)
    test.equal(view.cf_fold_map[2], 4)

    config.plugins.codefold.start_folded = previous_start_folded
    config.plugins.codefold.hide_tail_on_fold = previous_hide_tail
  end)

  test.test("block comment delimiters inside strings do not create folds", function()
    local codefold = require "plugins.codefold"
    local doc = make_c_doc({
      "const char *s = \"/* not a comment\";\n",
      "const char *e = \"*/ not a comment\";\n",
    })
    doc.highlighter:get_line(1)

    local regions = codefold._test.detect_fold_regions(doc)

    for _, region in ipairs(regions) do
      test.not_equal(region.kind, "comment")
    end
  end)

  test.test("untokenized fold heads do not hide tail lines", function()
    local codefold = require "plugins.codefold"

    local doc = make_c_doc({
      "/**\n",
      " * Function that does something\n",
      " */\n",
      "function somefunction(){\n",
      "}\n",
    })

    local regions = codefold._test.detect_fold_regions(doc)

    test.equal(regions[1].kind, "comment")
    test.equal(regions[1].hide_tail, false)
  end)

  test.test("comment marker fold heads do not hide tail after stale tokens", function()
    local codefold = require "plugins.codefold"

    local doc = make_c_doc({
      "/**\n",
      " * Function that does something\n",
      " */\n",
      "static function addFieldsets(\n",
      "}\n",
    })
    doc.highlighter.lines[1] = {
      init_state = nil,
      text = doc.lines[1],
      tokens = { "normal", doc.lines[1] },
      state = nil
    }

    local regions = codefold._test.detect_fold_regions(doc)

    test.equal(regions[1].kind, "comment")
    test.equal(regions[1].hide_tail, false)
  end)

  test.test("php subsyntax comment markers do not hide following function", function()
    local codefold = require "plugins.codefold"

    local doc = make_php_doc({
      "<?php\n",
      "/**\n",
      " * Add a new fieldset with fields to an array of fieldsets.\n",
      " */\n",
      "static function addFieldsets(\n",
      "    array $fieldsets,\n",
      ")\n",
      "{\n",
      "}\n",
    })
    doc.highlighter:get_line(1)

    local regions = codefold._test.detect_fold_regions(doc)

    test.equal(regions[1].start, 2)
    test.equal(regions[1].stop, 4)
    test.equal(regions[1].kind, "comment")
    test.equal(regions[1].hide_tail, false)

    local previous_start_folded = config.plugins.codefold.start_folded
    local previous_hide_tail = config.plugins.codefold.hide_tail_on_fold
    config.plugins.codefold.start_folded = true
    config.plugins.codefold.hide_tail_on_fold = true

    local view = DocView(doc)
    codefold._test.apply_detected_regions(view, regions)

    test.ok(view.cf_hidden_lines[3])
    test.ok(view.cf_hidden_lines[4])
    test.is_nil(view.cf_hidden_lines[5])
    test.equal(view.cf_fold_map[2], 2)
    test.equal(view.cf_fold_map[3], 5)

    config.plugins.codefold.start_folded = previous_start_folded
    config.plugins.codefold.hide_tail_on_fold = previous_hide_tail
  end)

  test.test("missing highlighter cache falls back to document syntax", function()
    local codefold = require "plugins.codefold"

    local doc = make_c_doc({
      "/**\n",
      " * Function that does something\n",
      " */\n",
      "function somefunction(){\n",
      "}\n",
    })
    doc.highlighter = {
      each_token = function()
        return function() end
      end
    }

    local regions = codefold._test.detect_fold_regions(doc)

    test.equal(regions[1].kind, "comment")
    test.equal(regions[1].stop, 3)
    test.equal(regions[1].hide_tail, false)
  end)

  test.test("incremental detection stops at unchanged next fold point", function()
    local codefold = require "plugins.codefold"

    local doc = Doc(nil, nil, true)
    doc.lines = {
      "changed text\n",
      "  changed child\n",
      "stable fold\n",
      "  stable child\n",
      "later fold\n",
      "  later child\n",
    }
    doc:reset_syntax()

    local previous_regions = {
      { indent = 0, start = 1, stop = 2, kind = "indent" },
      { indent = 0, start = 3, stop = 4, kind = "indent" },
      { indent = 0, start = 5, stop = 6, kind = "indent" },
    }

    local original_get_utf8_line = doc.get_utf8_line
    doc.get_utf8_line = function(self, line)
      test.ok(line < 5, "incremental detection scanned past stable fold point")
      return original_get_utf8_line(self, line)
    end

    local regions = codefold._test.detect_fold_regions(doc, 1, previous_regions)

    test.equal(#regions, 3)
    test.equal(regions[2], previous_regions[2])
    test.equal(regions[3], previous_regions[3])

    doc.get_utf8_line = original_get_utf8_line
  end)

  test.test("incremental detection keeps scanning inside changed fold", function()
    local codefold = require "plugins.codefold"

    local doc = Doc(nil, nil, true)
    doc.lines = {
      "outer\n",
      "  new fold\n",
      "    new child\n",
      "  sibling\n",
      "stable fold\n",
      "  stable child\n",
    }
    doc:reset_syntax()

    local previous_regions = {
      { indent = 0, start = 1, stop = 4, kind = "indent" },
      { indent = 0, start = 5, stop = 6, kind = "indent" },
    }

    local regions = codefold._test.detect_fold_regions(doc, 2, previous_regions)

    test.equal(#regions, 3)
    test.equal(regions[1].start, 1)
    test.equal(regions[1].stop, 4)
    test.equal(regions[2].start, 2)
    test.equal(regions[2].stop, 3)
    test.equal(regions[3], previous_regions[2])
  end)

  test.test("incremental detection catches fold created by next line", function()
    local codefold = require "plugins.codefold"

    local doc = Doc(nil, nil, true)
    doc.lines = {
      "{\n",
      "  something\n",
      "}\n",
    }
    doc:reset_syntax()

    local regions = codefold._test.detect_fold_regions(doc, 2, {})

    test.equal(#regions, 1)
    test.equal(regions[1].start, 1)
    test.equal(regions[1].stop, 2)
  end)
end)

test.describe("codefold - virtual line mapping", function()
  test.test("hide tail on fold is disabled by default", function()
    require "plugins.codefold"

    test.equal(config.plugins.codefold.hide_tail_on_fold, false)

    local found_spec = false
    for _, item in ipairs(config.plugins.codefold.config_spec) do
      if item.path == "hide_tail_on_fold" then
        found_spec = true
        test.equal(item.default, false)
      end
    end
    test.ok(found_spec)
  end)

  test.test("folded regions hide their ending boundary line", function()
    local codefold = require "plugins.codefold"

    local previous_hide_tail = config.plugins.codefold.hide_tail_on_fold
    local previous_start_folded = config.plugins.codefold.start_folded
    config.plugins.codefold.hide_tail_on_fold = true
    config.plugins.codefold.start_folded = true

    local doc = Doc(nil, nil, true)
    doc.lines = {
      "function main()\n",
      "  print('test')\n",
      "end\n",
      "print('done')\n",
    }
    doc:reset_syntax()

    local view = DocView(doc)
    codefold._test.apply_detected_regions(view, {
      { indent = 0, start = 1, stop = 2 },
    })

    test.ok(view.cf_hidden_lines[2])
    test.ok(view.cf_hidden_lines[3])
    test.is_nil(view.cf_hidden_lines[4])
    test.equal(#view.cf_fold_map, 2)
    test.equal(view.cf_fold_map[1], 1)
    test.equal(view.cf_fold_map[2], 4)

    config.plugins.codefold.hide_tail_on_fold = previous_hide_tail
    config.plugins.codefold.start_folded = previous_start_folded
  end)

  test.test("identity mapping when no folds", function()
    local regions = {
      { start = 2, stop = 3 },
    }
    local fold_map, unfold_map = build_maps(
      { "line1\n", "line2\n", "line3\n", "line4\n" },
      regions,
      {} -- nothing folded
    )
    test.equal(#fold_map, 4)
    test.equal(fold_map[1], 1)
    test.equal(fold_map[2], 2)
    test.equal(unfold_map[2], 2)
  end)

  test.test("fold one region", function()
    local regions = {
      { start = 2, stop = 3 },
    }
    local fold_map, unfold_map = build_maps(
      { "line1\n", "line2\n", "line3\n", "line4\n" },
      regions,
      { 1 } -- region 1 folded
    )
    test.equal(#fold_map, 3)
    test.equal(fold_map[1], 1)   -- line1
    test.equal(fold_map[2], 2)   -- line2 (fold header)
    test.equal(fold_map[3], 4)   -- line4

    test.equal(unfold_map[1], 1)
    test.equal(unfold_map[2], 2)
    test.equal(unfold_map[3], nil) -- hidden
    test.equal(unfold_map[4], 3)   -- shifted
  end)

  test.test("fold nested regions", function()
    local regions = {
      { start = 2, stop = 6 },  -- outer
      { start = 3, stop = 5 },  -- inner
    }
    local fold_map, unfold_map = build_maps(
      { "line1\n", "line2\n", "line3\n", "line4\n", "line5\n", "line6\n", "line7\n" },
      regions,
      { 1, 2 } -- both folded
    )
    -- outer: hides 3-6, inner: hides 4-5
    -- visible: 1, 2 (outer header), 7
    test.equal(#fold_map, 3, "both folded gives 3 visible lines")
    test.equal(fold_map[1], 1)
    test.equal(fold_map[2], 2)   -- outer header
    test.equal(fold_map[3], 7)

    test.equal(unfold_map[3], nil) -- hidden by outer
    test.equal(unfold_map[4], nil) -- hidden by both
    test.equal(unfold_map[5], nil) -- hidden by both
    test.equal(unfold_map[6], nil) -- hidden by outer
    test.equal(unfold_map[7], 3)
  end)

  test.test("fold only inner region", function()
    local regions = {
      { start = 2, stop = 6 },  -- outer
      { start = 3, stop = 5 },  -- inner
    }
    local fold_map, unfold_map = build_maps(
      { "line1\n", "line2\n", "line3\n", "line4\n", "line5\n", "line6\n", "line7\n" },
      regions,
      { 2 } -- only inner folded
    )
    test.equal(#fold_map, 5)
    test.equal(fold_map[1], 1)
    test.equal(fold_map[2], 2)
    test.equal(fold_map[3], 3)  -- inner header
    test.equal(fold_map[4], 6)  -- still in outer
    test.equal(fold_map[5], 7)

    test.equal(unfold_map[3], 3)
    test.equal(unfold_map[4], nil) -- hidden by inner
    test.equal(unfold_map[5], nil) -- hidden by inner
    test.equal(unfold_map[6], 4)   -- visible (open outer)
    test.equal(unfold_map[7], 5)
  end)

  test.test("unfold after fold", function()
    local regions = {
      { start = 2, stop = 4 },
    }
    local _, unfold_map = build_maps(
      { "line1\n", "line2\n", "line3\n", "line4\n", "line5\n" },
      regions,
      { 1 }
    )
    test.equal(unfold_map[3], nil) -- hidden

    local fold_map2, unfold_map2 = build_maps(
      { "line1\n", "line2\n", "line3\n", "line4\n", "line5\n" },
      regions,
      {} -- unfolded
    )
    test.equal(#fold_map2, 5)
    test.equal(unfold_map2[3], 3) -- visible again
  end)

  test.test("DocView position helpers use fold maps", function()
    require "plugins.codefold"

    local previous_hide_tail = config.plugins.codefold.hide_tail_on_fold
    config.plugins.codefold.hide_tail_on_fold = false

    local doc = Doc(nil, nil, true)
    doc.lines = { "a\n", "b\n", "c\n", "d\n", "e\n" }
    doc:reset_syntax()

    local view = DocView(doc)
    view.cf_regions = { { start = 2, stop = 4 } }
    view.cf_folded_regions = { 1 }
    view.cf_fold_map = { 1, 2, 5 }
    view.cf_unfold_map = { 1, 2, nil, nil, 3 }

    local line, col = view:position_from_offset(3)
    test.equal(line, 5)
    test.equal(col, 1)
    test.equal(view:offset_from_position(5, 1), 3)
    test.equal(view:offset_from_position(4, 1), 2)

    config.plugins.codefold.hide_tail_on_fold = previous_hide_tail
  end)

  test.test("indentguide caches visible folded real lines", function()
    local config = require "core.config"
    require "plugins.codefold"
    dofile_from_source("subprojects/plugins/plugins/indentguide.lua")

    local previous = config.plugins.indentguide.enabled
    local previous_highlight = config.plugins.indentguide.highlight
    local previous_hide_tail = config.plugins.codefold.hide_tail_on_fold
    config.plugins.indentguide.enabled = true
    config.plugins.indentguide.highlight = false
    config.plugins.codefold.hide_tail_on_fold = false

    local doc = Doc(nil, nil, true)
    doc.lines = { "a\n", "  b\n", "    c\n", "  d\n", "  e\n" }
    doc:reset_syntax()

    local view = DocView(doc)
    view.position.x = 0
    view.position.y = 0
    view.size.x = 320
    view.size.y = 200
    view.cf_regions = { { start = 1, stop = 4 } }
    view.cf_folded_regions = { 1 }
    view.cf_fold_map = { 1, 5 }
    view.cf_unfold_map = { 1, nil, nil, nil, 2 }
    view.cf_first_update = nil
    view.cf_invalidated = nil

    view:update()

    test.equal(view.indentguide_indents[1], 0)
    test.equal(view.indentguide_indents[5], 2)
    test.equal(view.indentguide_indents[2], nil)

    config.plugins.indentguide.enabled = previous
    config.plugins.indentguide.highlight = previous_highlight
    config.plugins.codefold.hide_tail_on_fold = previous_hide_tail
  end)

  test.test("indentguide active range uses visible offsets", function()
    local config = require "core.config"
    require "plugins.codefold"
    dofile_from_source("subprojects/plugins/plugins/indentguide.lua")

    local previous = config.plugins.indentguide.enabled
    local previous_highlight = config.plugins.indentguide.highlight
    config.plugins.indentguide.enabled = true
    config.plugins.indentguide.highlight = true

    local doc = Doc(nil, nil, true)
    doc.lines = {}
    for i = 1, 66 do
      doc.lines[i] = "line\n"
    end
    for i = 53, 57 do
      doc.lines[i] = "  line\n"
    end
    doc.lines[58] = "    line\n"
    doc.lines[59] = "    line\n"
    doc.lines[60] = "  line\n"
    doc:reset_syntax()
    doc:set_selection(55, 1)

    local view = DocView(doc)
    view.position.x = 0
    view.position.y = 0
    view.size.x = 320
    view.size.y = view:get_line_height() * 80
    view.cf_regions = { { start = 34, stop = 47 } }
    view.cf_folded_regions = { 1 }
    view.cf_fold_map = {}
    view.cf_unfold_map = {}
    for line = 1, #doc.lines do
      if line <= 34 or line > 47 then
        local offset = #view.cf_fold_map + 1
        view.cf_fold_map[offset] = line
        view.cf_unfold_map[line] = offset
      end
    end
    view.cf_first_update = nil
    view.cf_invalidated = nil

    view:update()

    test.equal(#view.cf_fold_map, 53)
    test.equal(view.indentguide_indent_active[55], 2)
    test.equal(view.indentguide_indent_active[56], 2)
    test.equal(view.indentguide_indent_active[57], 2)

    config.plugins.indentguide.enabled = previous
    config.plugins.indentguide.highlight = previous_highlight
  end)

  test.test("smooth caret visibility uses visible offsets", function()
    local config = require "core.config"
    require "plugins.codefold"
    dofile_from_source("subprojects/plugins/plugins/smoothcaret.lua")

    local previous_enabled = config.plugins.smoothcaret.enabled
    local previous_active_view = core.active_view
    config.plugins.smoothcaret.enabled = true

    local doc = Doc(nil, nil, true)
    doc.lines = {}
    for i = 1, 66 do
      doc.lines[i] = "line\n"
    end
    doc:reset_syntax()
    doc:set_selection(55, 1)

    local view = DocView(doc)
    view.position.x = 0
    view.position.y = 0
    view.size.x = 320
    view.size.y = view:get_line_height() * 80
    view.cf_fold_map = {}
    view.cf_unfold_map = {}
    for line = 1, #doc.lines do
      if line <= 34 or line > 47 then
        local offset = #view.cf_fold_map + 1
        view.cf_fold_map[offset] = line
        view.cf_unfold_map[line] = offset
      end
    end
    view.cf_first_update = nil
    view.cf_invalidated = nil
    core.active_view = view

    view:update()

    test.equal(#view.cf_fold_map, 53)
    test.equal(#view.visible_carets, 1)

    config.plugins.smoothcaret.enabled = previous_enabled
    core.active_view = previous_active_view
  end)

  test.test("fold gutter marker visibility and color reflect state", function()
    require "plugins.codefold"

    local previous_enabled = config.plugins.codefold.enabled
    local previous_always_show = config.plugins.codefold.always_show_fold_markers
    config.plugins.codefold.enabled = true
    config.plugins.codefold.always_show_fold_markers = false

    local view = make_docview({ "a\n", "  b\n", "c\n" })
    view.cf_regions = { { indent = 0, start = 1, stop = 2 } }
    view.cf_folded_regions = {}
    view.cf_fold_map = { 1, 2, 3 }
    view.cf_unfold_map = { 1, 2, 3 }
    view.cf_first_update = nil
    view.cf_invalidated = nil

    local _, y = view:get_line_screen_position(1)
    with_common_draw_text(function(calls)
      view:draw_line_gutter(1, view.position.x, y, view:get_gutter_width())
      test.equal(#calls, 1)

      view.hovering_gutter = true
      view:draw_line_gutter(1, view.position.x, y, view:get_gutter_width())
      test.equal(calls[#calls].color, style.dim or style.line_number)

      view.hovering_gutter = false
      config.plugins.codefold.always_show_fold_markers = true
      view:draw_line_gutter(1, view.position.x, y, view:get_gutter_width())
      test.equal(calls[#calls].color, style.dim or style.line_number)

      config.plugins.codefold.always_show_fold_markers = false
      view.cf_folded_regions = { 1 }
      view:draw_line_gutter(1, view.position.x, y, view:get_gutter_width())
      test.equal(calls[#calls].color, style.caret)
      local toggle_font = view.cf_toggle_font

      view.cf_hovering_toggle = 1
      view:draw_line_gutter(1, view.position.x, y, view:get_gutter_width())
      test.equal(calls[#calls].color, style.accent)
      test.equal(view.cf_toggle_font, toggle_font)
    end)

    config.plugins.codefold.enabled = previous_enabled
    config.plugins.codefold.always_show_fold_markers = previous_always_show
  end)

  test.test("fold gutter hover uses shifted marker bounds", function()
    require "plugins.codefold"

    local previous_enabled = config.plugins.codefold.enabled
    local previous_always_show = config.plugins.codefold.always_show_fold_markers
    config.plugins.codefold.enabled = true
    config.plugins.codefold.always_show_fold_markers = true

    local view = make_docview({ "a\n", "  b\n", "c\n" })
    view.cf_regions = { { indent = 0, start = 1, stop = 2 } }
    view.cf_folded_regions = {}
    view.cf_fold_map = { 1, 2, 3 }
    view.cf_unfold_map = { 1, 2, 3 }
    view.cf_first_update = nil
    view.cf_invalidated = nil

    local _, y = view:get_line_screen_position(1)
    local marker_x, marker_w
    with_common_draw_text(function(calls)
      view.hovering_gutter = true
      view:draw_line_gutter(1, view.position.x, y, view:get_gutter_width())
      marker_x = calls[#calls].x
      marker_w = calls[#calls].w
    end)

    view:on_mouse_moved(marker_x + marker_w / 2, y + view:get_line_height() / 2)
    test.equal(view.cf_hovering_toggle, 1)

    view:on_mouse_moved(marker_x + marker_w + 1, y + view:get_line_height() / 2)
    test.is_nil(view.cf_hovering_toggle)

    config.plugins.codefold.enabled = previous_enabled
    config.plugins.codefold.always_show_fold_markers = previous_always_show
  end)

  test.test("ensure_line_visible unfolds regions containing the line", function()
    require "plugins.codefold"

    local previous_enabled = config.plugins.codefold.enabled
    config.plugins.codefold.enabled = true

    local doc = Doc(nil, nil, true)
    doc.lines = {
      "a\n",
      "  b\n",
      "    c\n",
      "  d\n",
      "e\n"
    }
    doc:reset_syntax()

    local view = DocView(doc)
    view.cf_regions = {
      { indent = 0, start = 1, stop = 4 },
      { indent = 2, start = 2, stop = 3 }
    }
    view.cf_folded_regions = { 1, 2 }
    view.cf_first_update = nil
    view.cf_invalidated = nil
    view.cf_state_loaded = true
    view.cf_fold_map, view.cf_unfold_map = build_maps(
      doc.lines,
      view.cf_regions,
      view.cf_folded_regions
    )

    test.is_nil(view.cf_unfold_map[3])

    view:ensure_line_visible(3)

    test.equal(#view.cf_folded_regions, 0)
    test.ok(view:is_line_visible(3))
    test.equal(view.cf_unfold_map[3], 3)

    config.plugins.codefold.enabled = previous_enabled
  end)

  test.test("detected regions build lookup caches and hidden lines", function()
    local codefold = require "plugins.codefold"

    local previous_start_folded = config.plugins.codefold.start_folded
    config.plugins.codefold.start_folded = true

    local doc = Doc(nil, nil, true)
    doc.lines = {
      "a\n",
      "  b\n",
      "c\n"
    }
    doc:reset_syntax()

    local view = DocView(doc)
    local regions = {
      { indent = 0, start = 1, stop = 2 }
    }

    codefold._test.apply_detected_regions(view, regions)

    test.equal(view.cf_region_by_start[1], 1)
    test.ok(view.cf_folded_region_set[1])
    test.ok(view.cf_hidden_lines[2])
    test.is_nil(view.cf_unfold_map[2])

    config.plugins.codefold.start_folded = previous_start_folded
  end)

  test.test("detected regions without folded spans skip map rebuild", function()
    local codefold = require "plugins.codefold"

    local doc = Doc(nil, nil, true)
    doc.lines = {
      "a\n",
      "  b\n",
      "c\n",
      "  d\n"
    }
    doc:reset_syntax()

    local view = DocView(doc)
    view.cf_regions = {}
    view.cf_folded_regions = {}
    view.cf_state_loaded = true
    view.cf_fold_map = {}
    view.cf_unfold_map = {}
    view.cf_visibility_signature = ""
    view.visual_lines_dirty = false

    codefold._test.apply_detected_regions(view, {
      { indent = 0, start = 1, stop = 2 },
      { indent = 0, start = 3, stop = 4 }
    })

    test.equal(view.cf_region_by_start[1], 1)
    test.equal(view.cf_region_by_start[3], 2)
    test.equal(view.visual_lines_dirty, false)
    test.equal(#view.cf_fold_map, 0)
  end)

  test.test("unchanged folded spans skip map rebuild", function()
    local codefold = require "plugins.codefold"

    local doc = Doc(nil, nil, true)
    doc.lines = {
      "a\n",
      "  b\n",
      "c\n",
      "  d\n",
      "e\n",
      "  f\n"
    }
    doc:reset_syntax()

    local view = DocView(doc)
    view.cf_regions = {
      { indent = 0, start = 1, stop = 2 },
      { indent = 0, start = 3, stop = 4 }
    }
    view.cf_folded_regions = { 1 }
    view.cf_folded_region_set = { [1] = true }
    view.cf_hidden_lines = { [2] = true }
    view.cf_fold_map, view.cf_unfold_map = build_maps(
      doc.lines,
      view.cf_regions,
      view.cf_folded_regions
    )
    view.cf_visibility_signature = "false|1:2:1"
    view.cf_mapping_line_count = #doc.lines
    view.cf_state_loaded = true
    view.visual_lines_dirty = false

    codefold._test.apply_detected_regions(view, {
      { indent = 0, start = 1, stop = 2 },
      { indent = 0, start = 3, stop = 4 },
      { indent = 0, start = 5, stop = 6 }
    })

    test.equal(view.cf_region_by_start[5], 3)
    test.ok(view.cf_folded_region_set[1])
    test.equal(view.visual_lines_dirty, false)
    test.is_nil(view.cf_unfold_map[2])
  end)

  test.test("changed folded spans rebuild maps", function()
    local codefold = require "plugins.codefold"

    local doc = Doc(nil, nil, true)
    doc.lines = {
      "a\n",
      "  b\n",
      "  c\n",
      "d\n"
    }
    doc:reset_syntax()

    local view = DocView(doc)
    view.cf_regions = {
      { indent = 0, start = 1, stop = 2 }
    }
    view.cf_folded_regions = { 1 }
    view.cf_folded_region_set = { [1] = true }
    view.cf_hidden_lines = { [2] = true }
    view.cf_fold_map, view.cf_unfold_map = build_maps(
      doc.lines,
      view.cf_regions,
      view.cf_folded_regions
    )
    view.cf_visibility_signature = "true|1:2:1"
    view.cf_mapping_line_count = #doc.lines
    view.cf_state_loaded = true
    view.visual_lines_dirty = false

    codefold._test.apply_detected_regions(view, {
      { indent = 0, start = 1, stop = 3 }
    })

    test.equal(view.visual_lines_dirty, true)
    test.ok(view.cf_hidden_lines[2])
    test.ok(view.cf_hidden_lines[3])
    test.is_nil(view.cf_unfold_map[3])
  end)

  test.test("document edits debounce fold recalculation", function()
    require "plugins.codefold"

    local previous_get_views = core.get_views_referencing_doc

    local doc = Doc(nil, nil, true)
    doc.lines = {
      "a\n",
      "  b\n"
    }
    doc:reset_syntax()

    local view = DocView(doc)
    view.cf_regions = { { indent = 0, start = 1, stop = 2 } }
    view.cf_invalidated = false
    view.cf_invalidated_at = nil
    view.cf_thread_id = "codefold-test-thread"

    local old_thread_ran = false
    local old_cr = coroutine.create(function()
      old_thread_ran = true
    end)
    core.threads[view.cf_thread_id] = {
      cr = old_cr,
      wake = 999,
      avg_time = 10,
      time = 10,
      calls = 1
    }

    core.get_views_referencing_doc = function(target)
      return target == doc and { view } or {}
    end

    local before = system.get_time()
    doc:insert(1, 1, "x")

    test.ok(view.cf_invalidated)
    test.ok(view.cf_invalidated_at and view.cf_invalidated_at >= before)
    test.is_nil(view.cf_thread_id)
    test.ok(core.threads["codefold-test-thread"])
    test.not_equal(core.threads["codefold-test-thread"].cr, old_cr)
    test.equal(core.threads["codefold-test-thread"].wake, 0)
    test.is_nil(core.threads["codefold-test-thread"].avg_time)
    test.is_nil(core.threads["codefold-test-thread"].time)
    test.is_nil(core.threads["codefold-test-thread"].calls)

    local ok = coroutine.resume(core.threads["codefold-test-thread"].cr)
    test.ok(ok)
    test.equal(coroutine.status(core.threads["codefold-test-thread"].cr), "dead")
    test.equal(old_thread_ran, false)

    core.threads["codefold-test-thread"] = nil
    core.get_views_referencing_doc = previous_get_views
  end)

  test.test("select all occurrences reveals folded matches and keeps search highlight", function()
    require "plugins.codefold"
    require "core.commands.findreplace"

    local previous_enabled = config.plugins.codefold.enabled
    local previous_active_view = core.active_view
    config.plugins.codefold.enabled = true

    local doc = Doc(nil, nil, true)
    doc.lines = {
      "target\n",
      "if ok then\n",
      "  target\n",
      "end\n"
    }
    doc:reset_syntax()
    doc:set_selection(1, 1, 1, 7)

    local view = DocView(doc)
    view.cf_regions = {
      { indent = 0, start = 2, stop = 3 }
    }
    view.cf_folded_regions = { 1 }
    view.cf_first_update = nil
    view.cf_invalidated = nil
    view.cf_state_loaded = true
    view.cf_fold_map, view.cf_unfold_map = build_maps(
      doc.lines,
      view.cf_regions,
      view.cf_folded_regions
    )
    core.active_view = view

    test.is_nil(view.cf_unfold_map[3])

    command.perform("find-replace:select-add-all")

    test.equal(#view.cf_folded_regions, 0)
    test.ok(view:is_line_visible(3))
    test.ok(#doc.selections > 4)
    test.ok(doc:is_search_selection(3, 3, 3, 9))

    config.plugins.codefold.enabled = previous_enabled
    core.active_view = previous_active_view
  end)

  test.test("go to line fuzzy match reveals folded target line", function()
    require "plugins.codefold"
    require "core.commands.doc"

    local previous_enabled = config.plugins.codefold.enabled
    local previous_active_view = core.active_view
    config.plugins.codefold.enabled = true

    local doc = Doc(nil, nil, true)
    doc.lines = {
      "start\n",
      "if ok then\n",
      "  target match\n",
      "end\n"
    }
    doc:reset_syntax()

    local view = DocView(doc)
    view.cf_regions = {
      { indent = 0, start = 2, stop = 3 }
    }
    view.cf_folded_regions = { 1 }
    view.cf_first_update = nil
    view.cf_invalidated = nil
    view.cf_state_loaded = true
    view.cf_fold_map, view.cf_unfold_map = build_maps(
      doc.lines,
      view.cf_regions,
      view.cf_folded_regions
    )
    core.active_view = view

    test.is_nil(view.cf_unfold_map[3])

    command.perform("doc:go-to-line")
    core.command_view:set_text("target")
    core.command_view:update_suggestions()
    for idx, item in ipairs(core.command_view.suggestions) do
      if item.line == 3 then
        core.command_view.suggestion_idx = idx
        break
      end
    end
    core.command_view:submit()

    test.equal(#view.cf_folded_regions, 0)
    test.ok(view:is_line_visible(3))
    test.equal(doc:get_selection(), 3)

    config.plugins.codefold.enabled = previous_enabled
    core.active_view = previous_active_view
  end)

end)

test.describe("codefold - persistent state", function()
  local original_project_path

  test.before_each(function(context)
    original_project_path = core.root_project().path
    context.project_root = original_project_path
      .. PATHSEP .. "codefold-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    local ok, err = common.mkdirp(context.project_root .. PATHSEP .. "src")
    test.ok(ok, err)
    core.root_project().path = context.project_root
  end)

  test.after_each(function(context)
    core.root_project().path = original_project_path
    if context.project_root and system.get_file_info(context.project_root) then
      local ok, err = common.rm(context.project_root, true)
      test.ok(ok, err)
    end
  end)

  local function make_named_doc(filename, lines)
    local abs_filename = core.project_absolute_path(filename)
    write_file(abs_filename, table.concat(lines))
    local doc = Doc(filename, abs_filename, false)
    doc.lines = lines
    doc:reset_syntax()
    return doc
  end

  test.test("saving folded regions creates project-local state", function()
    local codefold = require "plugins.codefold"
    local doc = make_named_doc("src/main.lua", {
      "local function main()\n",
      "  print('hello')\n",
      "end\n"
    })
    local regions = { { indent = 0, start = 1, stop = 2 } }

    codefold._test.save_fold_state(doc, regions, { 1 })

    local path = codefold._test.state_path_for_doc(doc)
    test.not_nil(system.get_file_info(path))
    local state = dofile(path)
    test.equal(state.path, "src/main.lua")
    test.equal(#state.folds, 1)
    test.equal(state.folds[1].line, 1)
    test.equal(state.folds[1].text, "local function main()\n")
  end)

  test.test("saving no folded regions removes project state", function()
    local codefold = require "plugins.codefold"
    local doc = make_named_doc("src/main.lua", {
      "local function main()\n",
      "  print('hello')\n",
      "end\n"
    })
    local regions = { { indent = 0, start = 1, stop = 2 } }

    codefold._test.save_fold_state(doc, regions, { 1 })
    local path = codefold._test.state_path_for_doc(doc)
    test.not_nil(system.get_file_info(path))

    codefold._test.save_fold_state(doc, regions, {})
    test.is_nil(system.get_file_info(path))
  end)

  test.test("loads saved folds for the same document", function()
    local codefold = require "plugins.codefold"
    local doc = make_named_doc("src/main.lua", {
      "local function main()\n",
      "  print('hello')\n",
      "end\n"
    })
    local regions = { { indent = 0, start = 1, stop = 2 } }

    codefold._test.save_fold_state(doc, regions, { 1 })
    local loaded = codefold._test.load_fold_state(doc)
    local folded = codefold._test.match_fold_state(doc, regions, loaded)

    test.equal(#folded, 1)
    test.equal(folded[1], 1)
  end)

  test.test("ignores stale folds that no longer match", function()
    local codefold = require "plugins.codefold"
    local doc = make_named_doc("src/main.lua", {
      "local function main()\n",
      "  print('hello')\n",
      "end\n"
    })
    local regions = { { indent = 0, start = 1, stop = 2 } }

    codefold._test.save_fold_state(doc, regions, { 1 })
    doc.lines = {
      "local function renamed()\n",
      "  print('hello')\n",
      "end\n"
    }
    local loaded = codefold._test.load_fold_state(doc)
    local folded = codefold._test.match_fold_state(doc, regions, loaded)

    test.equal(#folded, 0)
  end)

  test.test("does not duplicate exact matches through fallback matching", function()
    local codefold = require "plugins.codefold"
    local doc = make_named_doc("src/main.lua", {
      "if ok then\n",
      "  one()\n",
      "end\n",
      "if ok then\n",
      "  two()\n",
      "end\n"
    })
    local regions = {
      { indent = 0, start = 1, stop = 2 },
      { indent = 0, start = 4, stop = 5 }
    }
    local folds = {
      { line = 1, indent = 0, text = "if ok then\n" }
    }

    local folded = codefold._test.match_fold_state(doc, regions, folds)

    test.equal(#folded, 1)
    test.equal(folded[1], 1)
  end)

  test.test("folds all detected regions on open when no saved state exists", function()
    local codefold = require "plugins.codefold"
    local previous_start_folded = config.plugins.codefold.start_folded
    config.plugins.codefold.start_folded = true

    local doc = make_named_doc("src/main.lua", {
      "local function one()\n",
      "  print('one')\n",
      "end\n",
      "local function two()\n",
      "  print('two')\n",
      "end\n"
    })
    local view = DocView(doc)
    local regions = {
      { indent = 0, start = 1, stop = 2 },
      { indent = 0, start = 4, stop = 5 }
    }

    codefold._test.apply_detected_regions(view, regions)

    test.equal(#view.cf_folded_regions, 2)
    test.equal(view.cf_folded_regions[1], 1)
    test.equal(view.cf_folded_regions[2], 2)
    test.is_nil(system.get_file_info(codefold._test.state_path_for_doc(doc)))

    config.plugins.codefold.start_folded = previous_start_folded
  end)

  test.test("saved state takes precedence over fold-on-open", function()
    local codefold = require "plugins.codefold"
    local previous_start_folded = config.plugins.codefold.start_folded
    config.plugins.codefold.start_folded = true

    local doc = make_named_doc("src/main.lua", {
      "local function one()\n",
      "  print('one')\n",
      "end\n",
      "local function two()\n",
      "  print('two')\n",
      "end\n"
    })
    local regions = {
      { indent = 0, start = 1, stop = 2 },
      { indent = 0, start = 4, stop = 5 }
    }
    codefold._test.save_fold_state(doc, regions, { 2 })

    local view = DocView(doc)
    codefold._test.apply_detected_regions(view, regions)

    test.equal(#view.cf_folded_regions, 1)
    test.equal(view.cf_folded_regions[1], 2)

    config.plugins.codefold.start_folded = previous_start_folded
  end)
end)

test.describe("codefold - translate functions", function()
  local function make_mock_dv(doc_lines, regions, folded_indices)
    local fold_map, unfold_map = build_maps(doc_lines, regions, folded_indices)
    return {
      cf_unfold_map = unfold_map,
      cf_fold_map = fold_map,
      cf_regions = regions,
      cf_folded_regions = folded_indices,
    }
  end

  -- Load the plugin to get access to translate overrides
  local codefold = require "plugins.codefold"

  test.test("next_line falls back when no regions are folded", function()
    local doc = Doc(nil, nil, true)
    doc.lines = { "line1\n", "line2\n", "line3\n" }
    doc:reset_syntax()

    local dv = DocView(doc)
    dv.cf_fold_map = {}
    dv.cf_unfold_map = {}
    dv.cf_folded_regions = {}
    dv.last_x_offset = { line = 1, col = 1, offset = 0 }

    local translate = require "core.docview".translate
    local nl = translate.next_line(doc, 1, 1, dv)
    test.equal(nl, 2)
  end)

  test.test("previous_line falls back when no regions are folded", function()
    local doc = Doc(nil, nil, true)
    doc.lines = { "line1\n", "line2\n", "line3\n" }
    doc:reset_syntax()

    local dv = DocView(doc)
    dv.cf_fold_map = {}
    dv.cf_unfold_map = {}
    dv.cf_folded_regions = {}
    dv.last_x_offset = { line = 2, col = 1, offset = 0 }

    local translate = require "core.docview".translate
    local nl = translate.previous_line(doc, 2, 1, dv)
    test.equal(nl, 1)
  end)

  test.test("next_line skips hidden lines", function()
    local dv = make_mock_dv(
      { "line1\n", "line2\n", "line3\n", "line4\n", "line5\n" },
      { { start = 2, stop = 4 } },
      { 1 } -- fold region 1
    )

    -- Starting at line 2 (visible, fold header)
    -- next visible line should be 5
    local doc = { lines = { "line1\n", "line2\n", "line3\n", "line4\n", "line5\n" } }
    local translate = require "core.docview".translate
    local nl, nc = translate.next_line(doc, 2, 1, dv)
    test.equal(nl, 5)
    test.equal(nc, 1)
  end)

  test.test("previous_line skips hidden lines", function()
    local dv = make_mock_dv(
      { "line1\n", "line2\n", "line3\n", "line4\n", "line5\n" },
      { { start = 2, stop = 4 } },
      { 1 }
    )

    local doc = { lines = { "line1\n", "line2\n", "line3\n", "line4\n", "line5\n" } }
    local translate = require "core.docview".translate
    local nl, nc = translate.previous_line(doc, 5, 1, dv)
    test.equal(nl, 2)
  end)

  test.test("next_line at last visible line", function()
    local dv = make_mock_dv(
      { "line1\n", "line2\n", "line3\n" },
      { { start = 2, stop = 3 } },
      { 1 }
    )

    local doc = { lines = { "line1\n", "line2\n", "line3\n" } }
    local translate = require "core.docview".translate
    local nl, nc = translate.next_line(doc, 2, 1, dv)
    -- line 1 is before, line 2 is header, 3 is hidden. End of doc.
    test.equal(nl, 2, "stays at line 2 since no more visible lines")
  end)

  test.test("next_page / previous_page", function()
    local lines = {}
    for i = 1, 10 do
      lines[i] = "line" .. i .. "\n"
    end
    local dv = make_mock_dv(
      lines,
      { { start = 5, stop = 8 } },
      { 1 } -- fold region 5-8
    )
    -- visible: 1,2,3,4,5(header),9,10

    -- Mock get_visible_line_range
    dv.get_visible_line_range = function()
      return 1, math.min(7, #lines) -- 7 visible lines
    end
    dv.size = { y = 200 }

    local translate = require "core.docview".translate
    local nl = translate.next_page(nil, 2, 1, dv)
    -- virtual line 2 + (7-1) = 8, but max virtual is 7
    test.equal(nl, 10, "page down from line 2 lands on last line")

    nl = translate.previous_page(nil, 10, 1, dv)
    test.equal(nl, 1, "page up from last line lands on first")
  end)
end)

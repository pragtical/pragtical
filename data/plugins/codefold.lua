-- mod-version:3
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local command = require "core.command"
local keymap = require "core.keymap"
local DocView = require "core.docview"
local Doc = require "core.doc"

---Configuration for code folding plugin.
---@class config.plugins.codefold
config.plugins.codefold = common.merge({
  -- Whether code folding is enabled.
  enabled = true,
  -- If true, newly opened documents have all fold regions initially collapsed.
  start_folded = false,
  -- Width in pixels reserved for fold toggle indicators in the gutter.
  toggle_width = common.round(24 * SCALE),
  -- The config specification used by the settings GUI.
  config_spec = {
    name = "Code Folding",
    {
      label = "Enable",
      description = "Toggle code folding capabilities.",
      path = "enabled",
      type = "toggle",
      default = true
    },
    {
      label = "Fold On Open",
      description = "Collapse all foldable regions when opening a file.",
      path = "start_folded",
      type = "toggle",
      default = false
    }
  }
}, config.plugins.codefold)

local TOGGLE_OPEN  = "\226\150\190"  -- ▾  (U+25BE)
local TOGGLE_CLOSE = "\226\150\184"  -- ▸  (U+25B8)

local codefold = {}

---------------------------------------------------------------------
-- Persistent state
---------------------------------------------------------------------

local function hash_text(text)
  local hash = 2166136261
  for i = 1, #text do
    hash = (hash * 16777619 + text:byte(i)) % 4294967296
  end
  return string.format("%08x", hash)
end

---@param path string
---@return string
local function normalize_state_key(path)
  return common.normalize_path(path):gsub("[/\\]", "/")
end

---@param doc core.doc
---@return string? relative_path
local function doc_state_key(doc)
  if not doc or not doc.filename and not doc.abs_filename then
    return nil
  end
  local path = doc.filename
  if not path and doc.abs_filename then
    path = common.relative_path(core.root_project().path, doc.abs_filename)
  end
  return normalize_state_key(path)
end

---@return string directory
local function state_directory()
  return core.root_project().path
    .. PATHSEP .. ".pragtical"
    .. PATHSEP .. "codefold"
end

---@param doc core.doc
---@return string? path
local function state_path_for_doc(doc)
  local key = doc_state_key(doc)
  if not key then return nil end
  return state_directory() .. PATHSEP .. hash_text(key) .. ".lua"
end

---@param doc core.doc
---@param regions table[]
---@param folded_regions integer[]
---@return table[] folds
local function make_state_folds(doc, regions, folded_regions)
  local folds = {}
  for _, region_idx in ipairs(folded_regions or {}) do
    local region = regions[region_idx]
    if region then
      folds[#folds + 1] = {
        line = region.start,
        indent = region.indent,
        text = doc.lines[region.start]
      }
    end
  end
  return folds
end

---@param doc core.doc
---@param regions table[]
---@param folded_regions integer[]
local function save_fold_state(doc, regions, folded_regions)
  local key = doc_state_key(doc)
  local path = state_path_for_doc(doc)
  if not key or not path then return end

  local folds = make_state_folds(doc, regions, folded_regions)
  if #folds == 0 then
    if system.get_file_info(path) then
      os.remove(path)
    end
    return
  end

  local dir = common.dirname(path)
  if not system.get_file_info(dir) then
    local ok, err = common.mkdirp(dir)
    if not ok then
      core.error("error creating codefold state directory %s: %s", dir, err)
      return
    end
  end

  local fp, err = io.open(path, "wb")
  if not fp then
    core.error("error opening codefold state file %s: %s", path, err)
    return
  end
  fp:write("return " .. common.serialize({
    path = key,
    folds = folds
  }, { pretty = true }))
  fp:close()
end

---@param doc core.doc
---@return table[]? folds
local function load_fold_state(doc)
  local key = doc_state_key(doc)
  local path = state_path_for_doc(doc)
  if not key or not path or not system.get_file_info(path) then
    return nil
  end

  local loader, err = loadfile(path)
  if not loader then
    core.error("error loading codefold state file %s: %s", path, err)
    return nil
  end

  local ok, state = pcall(loader)
  if not ok then
    core.error("error reading codefold state file %s: %s", path, state)
    return nil
  end
  if type(state) ~= "table" or state.path ~= key or type(state.folds) ~= "table" then
    return nil
  end
  return state.folds
end

---@param doc core.doc
---@param regions table[]
---@param folds table[]
---@return integer[] folded_regions
local function match_fold_state(doc, regions, folds)
  local folded = {}
  local used = {}
  local unmatched_folds = {}

  local function use_region(idx)
    if used[idx] then return end
    used[idx] = true
    folded[#folded + 1] = idx
  end

  for _, fold in ipairs(folds or {}) do
    if type(fold) == "table" then
      local line = fold.line
      if type(line) == "number" then
        local region
        for idx, candidate in ipairs(regions) do
          if candidate.start == line
            and candidate.indent == fold.indent
            and doc.lines[candidate.start] == fold.text
          then
            region = idx
            break
          end
        end
        if region then
          use_region(region)
        else
          unmatched_folds[#unmatched_folds + 1] = fold
        end
      else
        unmatched_folds[#unmatched_folds + 1] = fold
      end
    end
  end

  for _, fold in ipairs(unmatched_folds) do
    if type(fold) == "table" and type(fold.text) == "string" then
      local best, best_distance
      for idx, candidate in ipairs(regions) do
        if not used[idx]
          and candidate.indent == fold.indent
          and doc.lines[candidate.start] == fold.text
        then
          local distance = math.abs(candidate.start - (fold.line or candidate.start))
          if not best_distance or distance < best_distance then
            best, best_distance = idx, distance
          elseif distance == best_distance then
            best = nil
          end
        end
      end
      if best then
        use_region(best)
      end
    end
  end

  return folded
end

---------------------------------------------------------------------
-- Indent helpers (adapted from indentguide)
---------------------------------------------------------------------

---Computes the indent width for a line, ignoring blank/whitespace-only lines
---by walking in `dir` (-1 up, 1 down) until a non-blank line is found.
---@param doc core.doc
---@param line integer
---@param indent_size integer
---@param dir integer?
---@return integer indent_width (-1 if no non-blank line found)
local function get_line_indent(doc, line, indent_size, dir)
  if line < 1 or line > #doc.lines then
    return -1
  end
  local text = doc.lines[line]
  if not text or text == "\n" or text == "" then
    if dir then
      return get_line_indent(doc, line + dir, indent_size, dir)
    end
    return -1
  end
  local s, e = text:find("^%s*")
  if e == #text then
    -- All whitespace — skip
    if dir then
      return get_line_indent(doc, line + dir, indent_size, dir)
    end
    return -1
  end
  local n = 0
  for b in text:sub(s, e):gmatch(".") do
    n = n + (b == "\t" and indent_size or 1)
  end
  return n
end

---Resolve indent for a possibly-blank line by looking both directions.
---@param doc core.doc
---@param line integer
---@param indent_size integer
---@return integer
local function get_effective_indent(doc, line, indent_size)
  local indent = get_line_indent(doc, line, indent_size)
  if indent >= 0 then
    return indent
  end
  local above = get_line_indent(doc, line - 1, indent_size, -1)
  local below = get_line_indent(doc, line + 1, indent_size, 1)
  if above >= 0 and below >= 0 then
    return math.max(above, below)
  end
  return above >= 0 and above or below
end

---------------------------------------------------------------------
-- Fold region detection
---------------------------------------------------------------------

---Detect all foldable regions in the document based on indentation.
---A fold region starts at line `s` (indent I) and continues through line `e`
---where line `e+1` has indent <= I (or e is the last line).
---@param doc core.doc
---@param invalidate_from? integer
---@param invalidate_to? integer
---@return table[] regions
local function detect_fold_regions(doc, invalidate_from, invalidate_to)
  local _, indent_size = doc:get_indent_info()
  local regions = {}
  local line_count = #doc.lines

  local start_line = 1
  local stop_line = line_count
  if invalidate_from then
    -- Find the first region that might be affected
    start_line = math.max(1, invalidate_from)
    stop_line = math.min(line_count, invalidate_to or line_count)
  end

  local line = start_line
  while line <= stop_line do
    if line % 100 == 0 then
      coroutine.yield()
    end

    local indent = get_effective_indent(doc, line, indent_size)
    if indent < 0 then
      line = line + 1
      goto continue
    end

    local next_line = line + 1
    if next_line > line_count then break end

    local next_indent = get_effective_indent(doc, next_line, indent_size)
    if next_indent > indent then
      -- Line `line` starts a fold region. Find where it ends.
      local stop = next_line
      while stop < line_count do
        local peek_indent = get_effective_indent(doc, stop + 1, indent_size)
        if peek_indent < 0 then
          -- blank — continue
          stop = stop + 1
        elseif peek_indent <= indent then
          break
        else
          stop = stop + 1
        end
      end
      regions[#regions + 1] = {
        indent = indent,
        start = line,
        stop = stop
      }
      line = line + 1
    else
      line = line + 1
    end
    ::continue::
  end

  return regions
end

---------------------------------------------------------------------
-- Virtual line mapping
---------------------------------------------------------------------

---Determine which real lines are hidden based on collapsed fold regions.
---@param self core.docview
---@return table<integer, boolean> hidden_set
local function build_hidden_set(self)
  local hidden = {}
  for _, region_idx in ipairs(self.cf_folded_regions) do
    local region = self.cf_regions[region_idx]
    if region then
      for l = region.start + 1, region.stop do
        hidden[l] = true
      end
    end
  end
  return hidden
end

---Rebuild fold_map (virtual→real) and unfold_map (real→virtual).
---@param self core.docview
local function rebuild_mappings(self)
  local hidden = build_hidden_set(self)
  self.cf_fold_map = {}
  self.cf_unfold_map = {}

  for real = 1, #self.doc.lines do
    if not hidden[real] then
      local virtual = #self.cf_fold_map + 1
      self.cf_fold_map[virtual] = real
      self.cf_unfold_map[real] = virtual
    else
      self.cf_unfold_map[real] = nil
    end
  end
  self:invalidate_visual_lines()
end

---Given a real line that may be hidden, find the nearest visible ancestor.
---@param self core.docview
---@param line integer
---@return integer visible_real_line
local function visible_ancestor(self, line)
  if not self.cf_unfold_map or #self.cf_unfold_map == 0 then
    return line
  end
  while line > 0 and not self.cf_unfold_map[line] do
    line = line - 1
  end
  return math.max(line, 1)
end

---Apply detected regions and restore persisted or in-memory fold state.
---@param self core.docview
---@param regions table[]
local function apply_detected_regions(self, regions)
  local previous_folds = make_state_folds(
    self.doc,
    self.cf_regions or {},
    self.cf_folded_regions or {}
  )
  local should_resave = false
  self.cf_regions = regions

  if not self.cf_state_loaded then
    local saved_folds = load_fold_state(self.doc)
    self.cf_state_loaded = true
    if saved_folds then
      self.cf_folded_regions = match_fold_state(self.doc, regions, saved_folds)
      should_resave = true
    elseif config.plugins.codefold.start_folded then
      self.cf_folded_regions = {}
      for idx = 1, #regions do
        self.cf_folded_regions[#self.cf_folded_regions + 1] = idx
      end
    else
      self.cf_folded_regions = {}
    end
  else
    self.cf_folded_regions = match_fold_state(self.doc, regions, previous_folds)
    should_resave = #previous_folds > 0
  end

  rebuild_mappings(self)
  if should_resave then
    save_fold_state(self.doc, self.cf_regions, self.cf_folded_regions)
  end
end

---Recalculate everything after fold state or document change.
---Runs in a background thread to avoid UI stalls on large documents.
---@param self core.docview
local function recalculate(self)
  -- Cancel any previous in-flight recalculation.
  if self.cf_thread_id then
    core.threads[self.cf_thread_id] = nil
    self.cf_thread_id = nil
  end

  self.cf_thread_id = core.add_thread(function()
    apply_detected_regions(self, detect_fold_regions(self.doc))
    self.cf_thread_id = nil
    core.redraw = true
  end)
end

---Initialize fold state for a DocView.
---@param self core.docview
local function init_fold_state(self)
  self.cf_regions = {}
  self.cf_folded_regions = {}
  self.cf_fold_map = {}
  self.cf_unfold_map = {}
  self.cf_invalidated = true
  self.cf_state_loaded = false
end

---Fold all regions.
---@param self core.docview
local function fold_all(self)
  local folded = {}
  for idx = 1, #self.cf_regions do
    folded[#folded + 1] = idx
  end
  self.cf_folded_regions = folded
  rebuild_mappings(self)
end

---Unfold all regions.
---@param self core.docview
local function unfold_all(self)
  self.cf_folded_regions = {}
  rebuild_mappings(self)
end

---Check if a fold region is collapsed.
---@param self core.docview
---@param region_idx integer
---@return boolean
local function is_folded(self, region_idx)
  for _, idx in ipairs(self.cf_folded_regions) do
    if idx == region_idx then
      return true
    end
  end
  return false
end

---Find the fold region that starts at a given real line.
---@param self core.docview
---@param line integer
---@return integer? region_idx
local function region_at_line(self, line)
  for idx, region in ipairs(self.cf_regions) do
    if region.start == line then
      return idx
    end
  end
  return nil
end

---Find the innermost fold region that contains a given real line
---(not as the header).
---@param self core.docview
---@param line integer
---@return integer? region_idx
local function region_containing(self, line)
  local best, best_indent = nil, -1
  for idx, region in ipairs(self.cf_regions) do
    if line > region.start and line <= region.stop then
      if region.indent > best_indent then
        best, best_indent = idx, region.indent
      end
    end
  end
  return best
end

---Toggle a fold region.
---@param self core.docview
---@param region_idx integer
local function toggle_region(self, region_idx)
  local folded = {}
  local was_folded = false
  for _, idx in ipairs(self.cf_folded_regions) do
    if idx == region_idx then
      was_folded = true
    else
      folded[#folded + 1] = idx
    end
  end
  if not was_folded then
    folded[#folded + 1] = region_idx
  end
  self.cf_folded_regions = folded
  rebuild_mappings(self)
  save_fold_state(self.doc, self.cf_regions, self.cf_folded_regions)

  -- If the caret is now hidden, snap it to the fold header
  local line1, col1 = self.doc:get_selection()
  if not self.cf_unfold_map[line1] then
    self.doc:set_selection(visible_ancestor(self, line1), col1)
  end
end

---Normalize the caret position: if on a hidden line, move to nearest visible.
---Safe to call when maps are not yet built (during async recalculation).
---@param self core.docview
local function normalize_caret(self)
  if not self.cf_unfold_map or #self.cf_unfold_map == 0 then
    return
  end
  local line1, col1, line2, col2 = self.doc:get_selection(true)
  if not self.cf_unfold_map[line1] then
    local ancestor = visible_ancestor(self, line1)
    if not self.cf_unfold_map[line2] then
      line2 = visible_ancestor(self, line2)
    end
    self.doc:set_selection(ancestor, col1, line2, col2)
  end
end


local docview_get_hidden_lines = DocView.get_hidden_lines
function DocView:get_hidden_lines()
  if config.plugins.codefold.enabled and self:is(DocView)
    and self.cf_folded_regions and #self.cf_folded_regions > 0 then
    return build_hidden_set(self)
  end
  return docview_get_hidden_lines(self)
end

local docview_ensure_line_visible = DocView.ensure_line_visible
function DocView:ensure_line_visible(line)
  line = docview_ensure_line_visible(self, line)
  if not config.plugins.codefold.enabled or not self:is(DocView) then
    return line
  end
  if not self.cf_unfold_map or self.cf_unfold_map[line] then
    return line
  end

  local folded = {}
  local changed = false
  for _, region_idx in ipairs(self.cf_folded_regions or {}) do
    local region = self.cf_regions[region_idx]
    if region and line > region.start and line <= region.stop then
      changed = true
    else
      folded[#folded + 1] = region_idx
    end
  end

  if changed then
    self.cf_folded_regions = folded
    rebuild_mappings(self)
    save_fold_state(self.doc, self.cf_regions, self.cf_folded_regions)
    core.redraw = true
  end
  return line
end

---------------------------------------------------------------------
-- Method overrides: DocView
---------------------------------------------------------------------

local docview_new = DocView.new
function DocView:new(doc, ...)
  docview_new(self, doc, ...)
  init_fold_state(self)
  self.cf_first_update = true
end

local docview_update = DocView.update
function DocView:update(...)
  docview_update(self, ...)

  if not config.plugins.codefold.enabled or not self:is(DocView) then
    return
  end

  -- Detect fold regions on first update
  if self.cf_first_update then
    self.cf_first_update = nil
    recalculate(self)
  end

  -- Recalculate if the document changed
  if self.cf_invalidated then
    self.cf_invalidated = nil
    recalculate(self)
  end

  normalize_caret(self)
end

---------------------------------------------------------------------
-- Method overrides: gutter width
---------------------------------------------------------------------

local docview_get_gutter_width = DocView.get_gutter_width
function DocView:get_gutter_width()
  if not config.plugins.codefold.enabled or not self:is(DocView) then
    return docview_get_gutter_width(self)
  end
  local base_width, padding = docview_get_gutter_width(self)
  local toggle_w = config.plugins.codefold.toggle_width
  return base_width + toggle_w, padding + toggle_w
end

local docview_draw_line_gutter = DocView.draw_line_gutter
function DocView:draw_line_gutter(line, x, y, width)
  local result = docview_draw_line_gutter(self, line, x, y, width)
  if config.plugins.codefold.enabled and self:is(DocView) then
    local region_idx = region_at_line(self, line)
    if region_idx then
      local folded = is_folded(self, region_idx)
      local toggle_char = folded and TOGGLE_CLOSE or TOGGLE_OPEN
      local toggle_color = folded and style.caret or (style.dim or style.line_number)
      if self.cf_hovering_toggle == line then
        toggle_color = style.accent
      end
      local lh = self:get_line_height()
      local toggle_w = config.plugins.codefold.toggle_width
      local font = self:get_font()
      local toggle_font = font:copy(common.round(font:get_size() * 1.5))
      local toggle_x = self.position.x + self:get_gutter_width() - toggle_w * 1.5
      local toggle_y = y
      common.draw_text(toggle_font, toggle_color, toggle_char, "right", toggle_x, toggle_y, toggle_w, lh)
    end
  end
  return result
end

---------------------------------------------------------------------
-- Method overrides: mouse
---------------------------------------------------------------------

local docview_on_mouse_pressed = DocView.on_mouse_pressed
function DocView:on_mouse_pressed(button, x, y, clicks)
  -- Mirror the original gutter handler: trust the hover flag set in on_mouse_moved.
  if config.plugins.codefold.enabled and self:is(DocView)
    and button == "left" and self.cf_hovering_toggle then
    local line = self:resolve_screen_position(x, y)
    if line then
      local region_idx = region_at_line(self, line)
      if region_idx then
        toggle_region(self, region_idx)
        core.redraw = true
        return true
      end
    end
  end
  return docview_on_mouse_pressed(self, button, x, y, clicks)
end

local docview_on_mouse_moved = DocView.on_mouse_moved
function DocView:on_mouse_moved(x, y, ...)
  -- Let the original handle scrollbar and gutter hover state first.
  docview_on_mouse_moved(self, x, y, ...)
  -- Then decide if we're hovering a fold toggle (leftmost portion of gutter).
  local was_hovering = self.cf_hovering_toggle
  self.cf_hovering_toggle = nil
  if config.plugins.codefold.enabled and self:is(DocView) then
    local tw = config.plugins.codefold.toggle_width
    local gw = self:get_gutter_width()
    if x >= self.position.x + gw - tw and x < self.position.x + gw then
      local line = self:resolve_screen_position(x, y)
      if line and region_at_line(self, line) then
        self.cf_hovering_toggle = line
        self.cursor = "arrow"
      end
    end
  end
  if was_hovering ~= self.cf_hovering_toggle then
    core.redraw = true
  end
end

---------------------------------------------------------------------
-- Method overrides: Doc (incremental invalidation)
---------------------------------------------------------------------

local doc_raw_insert = Doc.raw_insert
function Doc:raw_insert(line, col, text, undo_stack, time)
  local result = doc_raw_insert(self, line, col, text, undo_stack, time)
  -- Invalidate fold state on all views of this doc
  for _, view in ipairs(core.get_views_referencing_doc(self)) do
    if view:is(DocView) and view.cf_regions then
      view.cf_invalidated = true
    end
  end
  return result
end

local doc_raw_remove = Doc.raw_remove
function Doc:raw_remove(line1, col1, line2, col2, undo_stack, time)
  local result = doc_raw_remove(self, line1, col1, line2, col2, undo_stack, time)
  for _, view in ipairs(core.get_views_referencing_doc(self)) do
    if view:is(DocView) and view.cf_regions then
      view.cf_invalidated = true
    end
  end
  return result
end

---------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------

command.add(nil, {
  ["code-folding:toggle"] = function()
    local view = core.active_view
    if not view or not view:is(DocView) or not view.cf_regions then
      return
    end
    local line = view.doc:get_selection()
    -- First check if the line itself starts a fold region
    local region_idx = region_at_line(view, line)
    if not region_idx then
      -- Find the innermost region containing this line
      region_idx = region_containing(view, line)
    end
    if region_idx then
      toggle_region(view, region_idx)
    end
  end,

  ["code-folding:fold-all"] = function()
    local view = core.active_view
    if not view or not view:is(DocView) or not view.cf_regions then
      return
    end
    fold_all(view)
    save_fold_state(view.doc, view.cf_regions, view.cf_folded_regions)
  end,

  ["code-folding:unfold-all"] = function()
    local view = core.active_view
    if not view or not view:is(DocView) or not view.cf_regions then
      return
    end
    unfold_all(view)
    save_fold_state(view.doc, view.cf_regions, view.cf_folded_regions)
  end,
})

---------------------------------------------------------------------
-- Keybindings
---------------------------------------------------------------------

keymap.add {
  ["alt+shift+left"] = "code-folding:toggle",
  ["alt+shift+right"] = "code-folding:toggle",
  ["alt+shift+up"] = "code-folding:fold-all",
  ["alt+shift+down"] = "code-folding:unfold-all"
}

---------------------------------------------------------------------
-- Translate overrides: skip hidden lines during cursor movement
---------------------------------------------------------------------

local original_next_line = DocView.translate.next_line
local original_previous_line = DocView.translate.previous_line
local original_next_page = DocView.translate.next_page
local original_previous_page = DocView.translate.previous_page

---Skip hidden (folded) lines when moving the cursor down.
---@param doc core.doc
---@param line integer
---@param col integer
---@param dv core.docview
---@return integer line
---@return integer col
DocView.translate.next_line = function(doc, line, col, dv)
  local function skip_hidden(l)
    if not dv.cf_unfold_map then return l end
    while l <= #doc.lines and not dv.cf_unfold_map[l] do
      l = l + 1
    end
    if l > #doc.lines then
      -- Walk backwards to find the last visible line
      l = #doc.lines
      while l >= 1 and not dv.cf_unfold_map[l] do
        l = l - 1
      end
    end
    return l
  end
  local nl = skip_hidden(line + 1)
  if nl == line then return line, math.huge end
  return nl, 1
end

---Skip hidden (folded) lines when moving the cursor up.
DocView.translate.previous_line = function(doc, line, col, dv)
  local function skip_hidden(l)
    if not dv.cf_unfold_map then return l end
    while l >= 1 and not dv.cf_unfold_map[l] do
      l = l - 1
    end
    if l < 1 then
      -- Walk forwards to find the first visible line
      l = 1
      while l <= #doc.lines and not dv.cf_unfold_map[l] do
        l = l + 1
      end
    end
    return l
  end
  local nl = skip_hidden(line - 1)
  if nl == line then return line, 1 end
  return nl, math.huge
end

---Page down, skipping folded regions.
DocView.translate.next_page = function(doc, line, col, dv)
  if not dv.cf_fold_map or #dv.cf_fold_map == 0 then
    return original_next_page(doc, line, col, dv)
  end
  local virtual = dv.cf_unfold_map[line]
  if not virtual then return dv.cf_fold_map[#dv.cf_fold_map], math.huge end
  local min, max = dv:get_visible_line_range()
  local new_virtual = math.min(#dv.cf_fold_map, virtual + (max - min))
  local new_real = dv.cf_fold_map[new_virtual] or #doc.lines
  return new_real, 1
end

---Page up, skipping folded regions.
DocView.translate.previous_page = function(doc, line, col, dv)
  if not dv.cf_fold_map or #dv.cf_fold_map == 0 then
    return original_previous_page(doc, line, col, dv)
  end
  local virtual = dv.cf_unfold_map[line]
  if not virtual then return 1, 1 end
  local min, max = dv:get_visible_line_range()
  local new_virtual = math.max(1, virtual - (max - min))
  local new_real = dv.cf_fold_map[new_virtual] or 1
  return new_real, 1
end

codefold._test = {
  apply_detected_regions = apply_detected_regions,
  doc_state_key = doc_state_key,
  hash_text = hash_text,
  load_fold_state = load_fold_state,
  match_fold_state = match_fold_state,
  save_fold_state = save_fold_state,
  state_path_for_doc = state_path_for_doc,
}

return codefold

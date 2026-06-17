-- mod-version:3
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local command = require "core.command"
local keymap = require "core.keymap"
local DocView = require "core.docview"
local Doc = require "core.doc"
local tokenizer = require "core.tokenizer"

---Configuration for code folding plugin.
---@class config.plugins.codefold
config.plugins.codefold = common.merge({
  -- Whether code folding is enabled.
  enabled = true,
  -- If true, newly opened documents have all fold regions initially collapsed.
  start_folded = false,
  -- If true, folded regions hide the folded end-line tail.
  hide_tail_on_fold = false,
  -- If true, all fold markers are always visible.
  always_show_fold_markers = false,
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
    },
    {
      label = "Hide Fold Tail",
      description = "Hide the folded end-line tail when a region is collapsed.",
      path = "hide_tail_on_fold",
      type = "toggle",
      default = false
    },
    {
      label = "Always Show Fold Markers",
      description = "Always draw markers for unfolded fold regions.",
      path = "always_show_fold_markers",
      type = "toggle",
      default = false
    }
  }
}, config.plugins.codefold)

local TOGGLE_OPEN  = "\226\150\190"  -- ▾  (U+25BE)
local TOGGLE_CLOSE = "\226\150\184"  -- ▸  (U+25B8)
local RECALC_DEBOUNCE_SECONDS = 0.12
local TOGGLE_WIDTH = common.round(24 * SCALE)
---@type renderer.font?
local CODEFOLD_FONT = nil
---@type renderer.font?
local CODEFOLD_SOURCE_FONT = nil

local codefold = {}

---Return whether code folding should run for a given view.
---@param self core.view
---@return boolean
local function codefold_enabled_for_view(self)
  return config.plugins.codefold.enabled
    and self:is(DocView)
    and not self.code_folding_disabled
end

local function maybe_yield()
  if coroutine.isyieldable() then coroutine.yield() end
end

---@param self core.docview
---@return renderer.font
local function get_toggle_font(self)
  local font = self:get_font()
  local size = common.round(font:get_size() * 1.5)
  if not CODEFOLD_FONT or CODEFOLD_SOURCE_FONT ~= font
    or self.cf_toggle_font_size ~= size
  then
    CODEFOLD_FONT = font:copy(size)
    CODEFOLD_SOURCE_FONT = font
    self.cf_toggle_font_size = size
  end
  return CODEFOLD_FONT
end

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
  local exact = {}
  local by_text = {}

  local function fold_key(line, indent, text)
    return tostring(line) .. "\0" .. tostring(indent) .. "\0" .. tostring(text)
  end

  local function text_key(indent, text)
    return tostring(indent) .. "\0" .. tostring(text)
  end

  for idx, candidate in ipairs(regions) do
    if idx % 500 == 0 then maybe_yield() end
    local text = doc.lines[candidate.start]
    exact[fold_key(candidate.start, candidate.indent, text)] = idx
    local key = text_key(candidate.indent, text)
    local list = by_text[key]
    if not list then
      list = {}
      by_text[key] = list
    end
    list[#list + 1] = idx
  end

  local function use_region(idx)
    if used[idx] then return end
    used[idx] = true
    folded[#folded + 1] = idx
  end

  for fold_idx, fold in ipairs(folds or {}) do
    if fold_idx % 500 == 0 then maybe_yield() end
    if type(fold) == "table" then
      local line = fold.line
      if type(line) == "number" then
        local region = exact[fold_key(line, fold.indent, fold.text)]
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

  for fold_idx, fold in ipairs(unmatched_folds) do
    if fold_idx % 500 == 0 then maybe_yield() end
    if type(fold) == "table" and type(fold.text) == "string" then
      local best, best_distance
      local candidates = by_text[text_key(fold.indent, fold.text)] or {}
      for idx_idx, idx in ipairs(candidates) do
        if idx_idx % 500 == 0 then maybe_yield() end
        local candidate = regions[idx]
        if not used[idx]
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

---Computes the indent width for a line without resolving blank lines.
---@param doc core.doc
---@param line integer
---@param indent_size integer
---@return integer indent_width (-1 for blank/whitespace-only lines)
local function get_direct_line_indent(doc, line, indent_size)
  if line < 1 or line > #doc.lines then
    return -1
  end
  local text = doc.lines[line]
  if not text or text == "\n" or text == "" then
    return -1
  end
  local s, e = text:find("^%s*")
  if e == #text then
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

---@param doc core.doc
---@param indent_size integer
---@return integer[] indents
local function build_effective_indents(doc, indent_size)
  local line_count = #doc.lines
  local raw = {}
  local prev = {}
  local next = {}
  local last = -1

  for line = 1, line_count do
    if line % 500 == 0 then maybe_yield() end
    local indent = get_direct_line_indent(doc, line, indent_size)
    raw[line] = indent
    if indent >= 0 then
      last = indent
    end
    prev[line] = last
  end

  last = -1
  for line = line_count, 1, -1 do
    if line % 500 == 0 then maybe_yield() end
    local indent = raw[line]
    if indent >= 0 then
      last = indent
    end
    next[line] = last
  end

  local indents = {}
  for line = 1, line_count do
    if line % 500 == 0 then maybe_yield() end
    local indent = raw[line]
    if indent >= 0 then
      indents[line] = indent
    elseif prev[line] >= 0 and next[line] >= 0 then
      indents[line] = math.max(prev[line], next[line])
    else
      indents[line] = prev[line] >= 0 and prev[line] or next[line]
    end
  end
  return indents
end

---------------------------------------------------------------------
-- Fold region detection
---------------------------------------------------------------------

---@param token_type any
---@return boolean
local function is_comment_token(token_type)
  if type(token_type) == "string" then
    return token_type:find("comment", 1, true) ~= nil
  elseif type(token_type) == "table" then
    for _, item in ipairs(token_type) do
      if is_comment_token(item) then return true end
    end
  end
  return false
end

---@param doc core.doc
---@param line integer
---@return boolean? starts_with_comment
local function line_starts_with_comment_token(doc, line)
  local highlighter = doc.highlighter
  if not highlighter or not highlighter.lines then
    return nil
  end
  local cached = highlighter.lines[line]
  if not cached or cached.text ~= doc:get_utf8_line(line) or cached.resume then
    return nil
  end
  if line > 1 then
    local previous = highlighter.lines[line - 1]
    if not previous or previous.text ~= doc:get_utf8_line(line - 1)
      or previous.resume or cached.init_state ~= previous.state then
      return nil
    end
  end

  for _, token_type, text in tokenizer.each_token(cached.tokens) do
    if text:find("%S") then
      return is_comment_token(token_type)
    end
  end
  return false
end

---@param doc core.doc
---@param line integer
---@return core.syntax.syntax?
local function get_line_syntax(doc, line)
  local current_syntax = doc.syntax
  if not current_syntax or line <= 1 then
    return current_syntax
  end

  local highlighter = doc.highlighter
  if not highlighter or not highlighter.lines then
    return current_syntax
  end

  local previous = highlighter.lines[line - 1]
  if previous and previous.text == doc:get_utf8_line(line - 1)
    and not previous.resume and previous.state then
    local syntaxes = tokenizer.extract_subsyntaxes(doc.syntax, previous.state)
    for _, syntax in pairs(syntaxes) do
      if syntax.comment or syntax.block_comment then
        return syntax
      end
    end
  end
  return current_syntax
end

---@param doc core.doc
---@param line integer
---@return boolean
local function line_starts_with_comment_marker(doc, line)
  local text = doc:get_utf8_line(line)
  local _, start = text:find("^%s*")
  text = text:sub(start + 1)

  local syntax = get_line_syntax(doc, line)
  if not syntax then return false end
  if syntax.block_comment and text:find(syntax.block_comment[1], 1, true) == 1 then
    return true
  end
  if syntax.comment and text:find(syntax.comment, 1, true) == 1 then
    return true
  end
  return false
end

---@param doc core.doc
---@param line integer
---@return integer? stop_line
local function block_comment_stop_line(doc, line)
  local syntax = get_line_syntax(doc, line)
  if not syntax or not syntax.block_comment then return nil end

  local start_marker, stop_marker = syntax.block_comment[1], syntax.block_comment[2]
  local text = doc:get_utf8_line(line)
  local _, ws_end = text:find("^%s*")
  text = text:sub(ws_end + 1)

  local start_pos = text:find(start_marker, 1, true)
  if start_pos ~= 1 then return nil end
  if text:find(stop_marker, start_pos + #start_marker, true) then
    return nil
  end

  for stop = line + 1, #doc.lines do
    if stop % 500 == 0 then maybe_yield() end
    if doc:get_utf8_line(stop):find(stop_marker, 1, true) then
      return stop
    end
  end
  return nil
end

---@param a table
---@param b table
---@return boolean
local function same_region(a, b)
  return a.start == b.start
    and a.stop == b.stop
    and a.indent == b.indent
    and a.kind == b.kind
    and a.hide_tail == b.hide_tail
end

---@param previous_regions table[]
---@param from_line integer
---@return integer start_line
---@return integer prefix_count
local function incremental_scan_start(previous_regions, from_line)
  local start_line = from_line
  for _, region in ipairs(previous_regions or {}) do
    if region.start <= from_line and region.stop >= from_line then
      start_line = math.min(start_line, region.start)
    end
  end

  local prefix_count = 0
  for idx, region in ipairs(previous_regions or {}) do
    if region.stop < start_line then
      prefix_count = idx
    else
      break
    end
  end
  return start_line, prefix_count
end

---Find the previous non-blank line that may become a fold head.
---@param doc core.doc
---@param line integer
---@param indent_size integer
---@return integer line
local function previous_fold_candidate_line(doc, line, indent_size)
  for candidate = line - 1, 1, -1 do
    if candidate % 500 == 0 then maybe_yield() end
    if get_effective_indent(doc, candidate, indent_size) >= 0 then
      return candidate
    end
  end
  return line
end

---Detect all foldable regions in the document based on indentation.
---A fold region starts at line `s` (indent I) and continues through line `e`
---where line `e+1` has indent <= I (or e is the last line).
---@param doc core.doc
---@param invalidate_from? integer
---@param previous_regions? table[]
---@return table[] regions
local function detect_fold_regions(doc, invalidate_from, previous_regions)
  local _, indent_size = doc:get_indent_info()
  local regions = {}
  local line_count = #doc.lines
  local indents = not invalidate_from and build_effective_indents(doc, indent_size)
  local indent_cache = {}
  local previous_by_start = {}
  local invalidated_line = invalidate_from

  local start_line = 1
  local stop_line = line_count
  if invalidate_from and previous_regions then
    start_line = previous_fold_candidate_line(
      doc,
      math.max(1, invalidate_from),
      indent_size
    )
    local prefix_count
    start_line, prefix_count = incremental_scan_start(previous_regions, start_line)
    for idx = 1, prefix_count do
      regions[#regions + 1] = previous_regions[idx]
    end
    for idx, region in ipairs(previous_regions) do
      previous_by_start[region.start] = idx
    end
  end

  local function get_indent(line)
    if indents then return indents[line] end
    if indent_cache[line] == nil then
      indent_cache[line] = get_effective_indent(doc, line, indent_size)
    end
    return indent_cache[line]
  end

  local line = start_line
  while line <= stop_line do
    if line % 100 == 0 then
      maybe_yield()
    end

    local indent = get_indent(line)
    if indent < 0 then
      line = line + 1
      goto continue
    end

    local next_line = line + 1
    if next_line > line_count then break end

    local next_indent = get_indent(next_line)
    if next_indent > indent then
      -- Line `line` starts a fold region. Find where it ends.
      local stop = next_line
      while stop < line_count do
        if stop % 500 == 0 then maybe_yield() end
        local peek_indent = get_indent(stop + 1)
        if peek_indent < 0 then
          -- blank — continue
          stop = stop + 1
        elseif peek_indent <= indent then
          break
        else
          stop = stop + 1
        end
      end
      local comment_stop = block_comment_stop_line(doc, line)
      if comment_stop then
        stop = comment_stop
      end
      local is_comment = line_starts_with_comment_token(doc, line)
      local region = {
        indent = indent,
        start = line,
        stop = stop,
        kind = (comment_stop or is_comment) and "comment" or "indent"
      }
      if comment_stop or is_comment == true or line_starts_with_comment_marker(doc, line) then
        region.hide_tail = false
      end
      local previous_idx = previous_by_start[region.start]
      local previous = previous_idx and previous_regions[previous_idx]
      if previous and same_region(region, previous)
        and (not invalidated_line or region.start > invalidated_line)
      then
        for idx = previous_idx, #previous_regions do
          regions[#regions + 1] = previous_regions[idx]
        end
        return regions
      end
      regions[#regions + 1] = region
      line = line + 1
    else
      line = line + 1
    end
    ::continue::
  end

  table.sort(regions, function(a, b)
    if a.start == b.start then
      return a.stop > b.stop
    end
    return a.start < b.start
  end)

  return regions
end

---------------------------------------------------------------------
-- Virtual line mapping
---------------------------------------------------------------------

---@param self core.docview
---@param regions table[]
local function set_regions(self, regions)
  self.cf_regions = regions or {}
  self.cf_region_by_start = {}
  for idx, region in ipairs(self.cf_regions) do
    if idx % 500 == 0 then maybe_yield() end
    self.cf_region_by_start[region.start] = idx
  end
end

---@param self core.docview
---@param folded integer[]
local function set_folded_regions(self, folded)
  self.cf_folded_regions = folded or {}
  self.cf_folded_region_set = {}
  for idx, region_idx in ipairs(self.cf_folded_regions) do
    if idx % 500 == 0 then maybe_yield() end
    self.cf_folded_region_set[region_idx] = true
  end
end

---@param regions table[]
---@param folded_regions integer[]
---@return string signature
local function folded_visibility_signature(regions, folded_regions)
  if not folded_regions or #folded_regions == 0 then
    return ""
  end

  local items = {}
  for idx, region_idx in ipairs(folded_regions) do
    if idx % 500 == 0 then maybe_yield() end
    local region = regions[region_idx]
    if region then
      items[#items + 1] = table.concat({
        region.start,
        region.stop,
        region.hide_tail == false and "0" or "1",
      }, ":")
    end
  end
  table.sort(items)
  return tostring(config.plugins.codefold.hide_tail_on_fold) .. "|"
    .. table.concat(items, ",")
end

---Determine which real lines are hidden based on collapsed fold regions.
---@param self core.docview
---@return table<integer, boolean> hidden_set
local function build_hidden_set(self)
  local hidden = {}
  for idx, region_idx in ipairs(self.cf_folded_regions) do
    if idx % 100 == 0 then maybe_yield() end
    local region = self.cf_regions[region_idx]
    if region then
      for l = region.start + 1, region.stop do
        if l % 500 == 0 then maybe_yield() end
        hidden[l] = true
      end
      if config.plugins.codefold.hide_tail_on_fold
        and region.hide_tail ~= false
        and region.stop < #self.doc.lines
      then
        hidden[region.stop + 1] = true
      end
    end
  end
  return hidden
end

---Rebuild fold_map (virtual→real) and unfold_map (real→virtual).
---@param self core.docview
local function rebuild_mappings(self)
  local hidden = build_hidden_set(self)
  self.cf_hidden_lines = hidden
  self.cf_fold_map = {}
  self.cf_unfold_map = {}

  for real = 1, #self.doc.lines do
    if real % 500 == 0 then maybe_yield() end
    if not hidden[real] then
      local virtual = #self.cf_fold_map + 1
      self.cf_fold_map[virtual] = real
      self.cf_unfold_map[real] = virtual
    else
      self.cf_unfold_map[real] = nil
    end
  end
  self.cf_visibility_signature = folded_visibility_signature(
    self.cf_regions or {},
    self.cf_folded_regions or {}
  )
  self.cf_mapping_line_count = #self.doc.lines
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
  local previous_signature = self.cf_visibility_signature
    or folded_visibility_signature(
      self.cf_regions or {},
      self.cf_folded_regions or {}
    )
  local should_resave = false
  set_regions(self, regions)

  if not self.cf_state_loaded then
    local saved_folds = load_fold_state(self.doc)
    self.cf_state_loaded = true
    if saved_folds then
      set_folded_regions(self, match_fold_state(self.doc, regions, saved_folds))
      should_resave = true
    elseif config.plugins.codefold.start_folded then
      local folded = {}
      for idx = 1, #regions do
        folded[#folded + 1] = idx
      end
      set_folded_regions(self, folded)
    else
      set_folded_regions(self, {})
    end
  else
    set_folded_regions(self, match_fold_state(self.doc, regions, previous_folds))
    should_resave = #previous_folds > 0
  end

  local new_signature = folded_visibility_signature(
    self.cf_regions or {},
    self.cf_folded_regions or {}
  )
  local mappings_missing = new_signature ~= ""
    and (
      not self.cf_fold_map
      or not self.cf_unfold_map
      or not self.cf_hidden_lines
      or self.cf_mapping_line_count ~= #self.doc.lines
    )
  if mappings_missing or previous_signature ~= new_signature then
    rebuild_mappings(self)
  else
    self.cf_visibility_signature = new_signature
  end
  if should_resave then
    save_fold_state(self.doc, self.cf_regions, self.cf_folded_regions)
  end
end

---Replace a stale scheduled recalculation with a no-op coroutine.
---@param self core.docview
local function replace_recalculation_thread(self)
  local thread_id = self.cf_thread_id
  if not thread_id then return end

  local thread = core.threads[thread_id]
  if thread then
    thread.cr = coroutine.create(function() end)
    thread.wake = 0
    thread.avg_time = nil
    thread.time = nil
    thread.calls = nil
  end
  self.cf_thread_id = nil
end

---@param self core.docview
---@param from_line? integer
local function schedule_recalculation(self, from_line)
  replace_recalculation_thread(self)
  self.cf_invalidated = true
  self.cf_invalidated_at = system.get_time() + RECALC_DEBOUNCE_SECONDS
  if from_line then
    self.cf_invalidated_from = self.cf_invalidated_from
      and math.min(self.cf_invalidated_from, from_line)
      or from_line
  end
end

---Recalculate everything after fold state or document change.
---Runs in a yielding core coroutine to avoid long uninterrupted UI stalls.
---@param self core.docview
local function recalculate(self)
  replace_recalculation_thread(self)

  self.cf_thread_id = core.add_thread(function()
    apply_detected_regions(
      self,
      detect_fold_regions(self.doc, self.cf_invalidated_from, self.cf_regions)
    )
    self.cf_thread_id = nil
    self.cf_invalidated = false
    self.cf_invalidated_at = nil
    self.cf_invalidated_from = nil
    core.redraw = true
  end)
end

---Initialize fold state for a DocView.
---@param self core.docview
local function init_fold_state(self)
  set_regions(self, {})
  set_folded_regions(self, {})
  self.cf_hidden_lines = nil
  self.cf_fold_map = {}
  self.cf_unfold_map = {}
  self.cf_invalidated = false
  self.cf_invalidated_at = nil
  self.cf_state_loaded = false
end

---Fold all regions.
---@param self core.docview
local function fold_all(self)
  local folded = {}
  for idx = 1, #self.cf_regions do
    folded[#folded + 1] = idx
  end
  set_folded_regions(self, folded)
  rebuild_mappings(self)
end

---Unfold all regions.
---@param self core.docview
local function unfold_all(self)
  set_folded_regions(self, {})
  rebuild_mappings(self)
end

---Check if a fold region is collapsed.
---@param self core.docview
---@param region_idx integer
---@return boolean
local function is_folded(self, region_idx)
  if self.cf_folded_region_set and self.cf_folded_region_set[region_idx] then
    return true
  end
  for _, idx in ipairs(self.cf_folded_regions or {}) do
    if idx == region_idx then return true end
  end
  return false
end

---Find the fold region that starts at a given real line.
---@param self core.docview
---@param line integer
---@return integer? region_idx
local function region_at_line(self, line)
  if self.cf_region_by_start and self.cf_region_by_start[line] then
    return self.cf_region_by_start[line]
  end
  for idx, region in ipairs(self.cf_regions or {}) do
    if region.start == line then return idx end
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
  set_folded_regions(self, folded)
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
  if not self.cf_folded_regions or #self.cf_folded_regions == 0 then
    return
  end
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
  if codefold_enabled_for_view(self)
    and self.cf_folded_regions and #self.cf_folded_regions > 0 then
    return self.cf_hidden_lines or build_hidden_set(self)
  end
  return docview_get_hidden_lines(self)
end

local docview_ensure_line_visible = DocView.ensure_line_visible
function DocView:ensure_line_visible(line)
  line = docview_ensure_line_visible(self, line)
  if not codefold_enabled_for_view(self) then
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
    set_folded_regions(self, folded)
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

  if not codefold_enabled_for_view(self) then
    return
  end

  -- Detect fold regions on first update
  if self.cf_first_update then
    self.cf_first_update = nil
    recalculate(self)
  end

  -- Recalculate if the document changed
  if self.cf_invalidated
    and (not self.cf_invalidated_at or system.get_time() >= self.cf_invalidated_at)
  then
    self.cf_invalidated = nil
    self.cf_invalidated_at = nil
    recalculate(self)
  end

  normalize_caret(self)
end

local docview_on_scale_change = DocView.on_scale_change
function DocView:on_scale_change(...)
  docview_on_scale_change(self, ...)
  TOGGLE_WIDTH = common.round(24 * SCALE)
end

---------------------------------------------------------------------
-- Method overrides: gutter width
---------------------------------------------------------------------

local docview_get_gutter_width = DocView.get_gutter_width
function DocView:get_gutter_width()
  if not codefold_enabled_for_view(self) then
    return docview_get_gutter_width(self)
  end
  local base_width, padding = docview_get_gutter_width(self)
  return base_width + TOGGLE_WIDTH, padding
end

local function fold_toggle_rect(self)
  return self.position.x + self:get_gutter_width() - TOGGLE_WIDTH * 1.5, TOGGLE_WIDTH
end

local docview_draw_line_gutter = DocView.draw_line_gutter
function DocView:draw_line_gutter(line, x, y, width)
  local base_width = codefold_enabled_for_view(self)
    and math.max(0, width - TOGGLE_WIDTH)
    or width
  local result = docview_draw_line_gutter(self, line, x, y, base_width)
  if codefold_enabled_for_view(self) then
    local region_idx = region_at_line(self, line)
    if region_idx then
      local folded = is_folded(self, region_idx)
      if not folded
        and not self.hovering_gutter
        and not config.plugins.codefold.always_show_fold_markers
      then
        return result
      end
      local toggle_char = folded and TOGGLE_CLOSE or TOGGLE_OPEN
      local toggle_color = folded and style.caret or (style.dim or style.line_number)
      if self.cf_hovering_toggle == line then
        toggle_color = style.accent
      end
      local lh = self:get_line_height()
      local toggle_x, toggle_w = fold_toggle_rect(self)
      local toggle_font = get_toggle_font(self)
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
  if codefold_enabled_for_view(self)
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
  if codefold_enabled_for_view(self) then
    local toggle_x, toggle_w = fold_toggle_rect(self)
    if x >= toggle_x and x < toggle_x + toggle_w then
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

local docview_on_mouse_left = DocView.on_mouse_left
function DocView:on_mouse_left()
  docview_on_mouse_left(self)
  if self.cf_hovering_toggle then
    self.cf_hovering_toggle = nil
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
    if codefold_enabled_for_view(view) and view.cf_regions then
      schedule_recalculation(view, line)
    end
  end
  return result
end

local doc_raw_remove = Doc.raw_remove
function Doc:raw_remove(line1, col1, line2, col2, undo_stack, time)
  local result = doc_raw_remove(self, line1, col1, line2, col2, undo_stack, time)
  for _, view in ipairs(core.get_views_referencing_doc(self)) do
    if codefold_enabled_for_view(view) and view.cf_regions then
      schedule_recalculation(view, line1)
    end
  end
  return result
end

---------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------

command.add(nil, {
  ["code-folding:toggle"] = function()
    config.plugins.codefold.enabled = not config.plugins.codefold.enabled
    core.redraw = true
  end,

  ["code-folding:toggle-fold"] = function()
    local view = core.active_view
    if not view or not codefold_enabled_for_view(view) or not view.cf_regions then
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
    if not view or not codefold_enabled_for_view(view) or not view.cf_regions then
      return
    end
    fold_all(view)
    save_fold_state(view.doc, view.cf_regions, view.cf_folded_regions)
  end,

  ["code-folding:unfold-all"] = function()
    local view = core.active_view
    if not view or not codefold_enabled_for_view(view) or not view.cf_regions then
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
  ["alt+shift+left"] = "code-folding:toggle-fold",
  ["alt+shift+right"] = "code-folding:toggle-fold",
  ["alt+shift+up"] = "code-folding:fold-all",
  ["alt+shift+down"] = "code-folding:unfold-all"
}

codefold._test = {
  apply_detected_regions = apply_detected_regions,
  detect_fold_regions = detect_fold_regions,
  doc_state_key = doc_state_key,
  hash_text = hash_text,
  load_fold_state = load_fold_state,
  match_fold_state = match_fold_state,
  save_fold_state = save_fold_state,
  state_path_for_doc = state_path_for_doc,
}

return codefold

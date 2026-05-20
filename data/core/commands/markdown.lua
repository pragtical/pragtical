local core = require "core"
local command = require "core.command"
local config = require "core.config"
local DocView = require "core.docview"
local MarkdownView = require "core.markdownview"

local markdown_preview_split_directions = {
  bottom = "down",
  top = "up",
  left = "left",
  right = "right"
}

local markdown_raw_split_directions = {
  bottom = "up",
  top = "down",
  left = "right",
  right = "left"
}

local function get_doc_preview(dv)
  local doc = dv.doc
  for _, view in ipairs(core.root_view.root_node:get_children()) do
    if view:extends(MarkdownView) and view.linked_doc == doc then
      return view
    end
  end
end

local function get_raw_doc_view(path)
  for _, view in ipairs(core.root_view.root_node:get_children()) do
    if view:extends(DocView) and view.doc and view.doc.abs_filename == path then
      return view
    end
  end
end

local function bind_preview_to_raw_view(mv, raw_view)
  if not (raw_view and raw_view:extends(DocView)) then
    return
  end
  mv.linked_doc = raw_view.doc
  mv.path = raw_view.doc.abs_filename
  mv.title = raw_view.doc:get_name()
  mv:refresh_from_doc()
end

local function open_raw_doc_view(path, mv)
  local doc = core.open_doc(path)
  local node = core.root_view.root_node:get_node_for_view(mv)
    or core.root_view:get_active_node_default()
  if config.markdown_preview_mode == "newtab" then
    for _, view in ipairs(node.views) do
      if view:extends(DocView) and view.doc == doc then
        node:set_active_view(view)
        return view
      end
    end
    local view = DocView(doc)
    node:add_view(view)
    core.root_view.root_node:update_layout()
    view:scroll_to_line(view.doc:get_selection(), true, true)
    return view
  end

  local view = DocView(doc)
  local split_direction = markdown_raw_split_directions[config.markdown_preview_mode] or "left"
  node:split(split_direction, view)
  core.root_view.root_node:update_layout()
  view:scroll_to_line(view.doc:get_selection(), true, true)
  return view
end

command.add(function()
  if not core.active_view:extends(DocView) then
    return false
  end
  local dv = core.active_view
  return MarkdownView.is_supported(dv.doc.filename or ""), dv
end, {
  ["markdown-view:preview"] = function(dv)
    local view = get_doc_preview(dv)
    if view then
      local node = core.root_view.root_node:get_node_for_view(view)
      if node then
        node:set_active_view(view)
      end
      return
    end

    local node = core.root_view.root_node:get_node_for_view(dv)
      or core.root_view:get_active_node_default()
    view = MarkdownView({
      linked_doc = dv.doc,
      path = dv.doc.abs_filename,
      title = dv.doc:get_name()
    })
    local mode = config.markdown_preview_mode
    local split_direction = markdown_preview_split_directions[mode]
    if mode == "newtab" then
      node:add_view(view)
    else
      (split_direction and node or core.root_view:get_active_node_default()):split(
        split_direction or "right",
        view
      )
    end
    core.root_view.root_node:update_layout()
  end
})

command.add(function()
  if core.active_view:extends(MarkdownView) and core.active_view:has_selection() then
    return true, core.active_view
  end
  return false
end, {
  ["markdown-view:copy"] = function(mv)
    mv:copy_selection()
  end
})

local function markdown_context_target_predicate(kind)
  return function()
    local mv = core.active_view
    local target = mv and mv.markdown_context_target
    local url = target and target[kind .. "_url"]
    if mv and mv:extends(MarkdownView) and url then
      return true, mv, target
    end
    return false
  end
end

command.add(markdown_context_target_predicate("link"), {
  ["markdown-view:copy-link"] = function(_, target)
    system.set_clipboard(target.link_url)
  end
})

command.add(markdown_context_target_predicate("image"), {
  ["markdown-view:copy-image-link"] = function(_, target)
    system.set_clipboard(target.image_url)
  end
})

command.add(function()
  if not core.active_view:extends(MarkdownView) then
    return false
  end
  local mv = core.active_view
  local path = mv.path
  return type(path) == "string" and path ~= "" and MarkdownView.is_supported(path), mv
end, {
  ["markdown-view:view-raw"] = function(mv)
    local raw_view = get_raw_doc_view(mv.path)
    if raw_view then
      local node = core.root_view.root_node:get_node_for_view(raw_view)
      if node then
        node:set_active_view(raw_view)
      end
    else
      raw_view = open_raw_doc_view(mv.path, mv)
    end
    bind_preview_to_raw_view(mv, raw_view)
  end
})

-- mod-version:3
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local Doc = require "core.doc"
local DirWatch = require "core.dirwatch"

config.plugins.autoreload = common.merge({
  always_show_nagview = true,
  config_spec = {
    name = "Autoreload",
    {
      label = "Always Show Nagview",
      description = "Alerts you if an opened file changes "
        .. "externally even if you haven't modified it.",
      path = "always_show_nagview",
      type = "toggle",
      default = true
    }
  }
}, config.plugins.autoreload)

local watch = DirWatch()
local times = setmetatable({}, { __mode = "k" })
local changed = setmetatable({}, { __mode = "k" })

local function update_time(doc)
  if doc.abs_filename then
    local info = system.get_file_info(doc.abs_filename)
    times[doc] = info and { modified = info.modified, size = info.size }
  end
end

local function reload_doc(doc)
  doc:reload()
  update_time(doc)
  core.redraw = true
  core.log_quiet("Auto-reloaded doc \"%s\"", doc.filename)
end

local function check_prompt_reload(doc)
  if doc and doc.deferred_reload then
    core.nag_view:show(
      "File Changed",
      doc.filename .. " has changed. Reload this file?",
      {
        { font = style.font, text = "Yes", default_yes = true },
        { font = style.font, text = "No" , default_no = true }
      }, function(item)
      if item.text == "Yes" then reload_doc(doc) end
      doc.deferred_reload = false
    end)
  end
end

local function autoreload_doc(doc)
  if changed[doc] then changed[doc] = nil end
  if
    not doc:is_dirty()
    and
    not config.plugins.autoreload.always_show_nagview
  then
    reload_doc(doc)
  elseif not doc.deferred_reload then
    doc.deferred_reload = true
    check_prompt_reload(doc)
  end
end

local core_set_active_view = core.set_active_view
function core.set_active_view(view)
  core_set_active_view(view)
  if core.active_view.doc and changed[core.active_view.doc] then
    local doc = core.active_view.doc
    core.add_thread(function()
      -- validate doc in case the active view rapidly changed
      if doc == core.active_view.doc then
        autoreload_doc(doc)
      end
    end)
  end
end

core.add_thread(function()
  local close_docs_time = system.get_time() + 5
  while true do
    watch:check(function(file)
      for _, doc in ipairs(core.docs) do
        if doc.abs_filename == file then
          local info = system.get_file_info(doc.abs_filename or "")
          if
            info and info.type == "file" and times[doc]
            and
            (
              times[doc].modified ~= info.modified
              or
              times[doc].size ~= info.size
            )
          then
            if
              core.active_view
              and
              core.active_view.doc
              and
              core.active_view.doc == doc
            then
              autoreload_doc(doc)
            elseif not doc.deferred_reload then
              changed[doc] = true
            end
          end
        end
      end
    end)
    -- unwatch closed docs every 5 secs
    if close_docs_time < system.get_time() then
      for doc, _ in pairs(times) do
        if #core.get_views_referencing_doc(doc) == 0 then
          watch:unwatch(doc.abs_filename)
          times[doc] = nil
          if changed[doc] then changed[doc] = nil end
        end
      end
      close_docs_time = system.get_time() + 5
    end
    coroutine.yield(1)
  end
end)

-- patch `Doc.save|load` to store modified time
local load = Doc.load
local save = Doc.save

Doc.load = function(self, ...)
  local res = load(self, ...)
  if not times[self] then watch:watch(self.abs_filename, true) end
  update_time(self)
  return res
end

Doc.save = function(self, ...)
  local res = save(self, ...)
  -- if starting with an unsaved document with a filename.
  if not times[self] then watch:watch(self.abs_filename, true) end
  update_time(self)
  return res
end

-- mod-version:3
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"

config.plugins.scale = common.merge({
  -- Toggle auto detection of system scale.
  autodetect = true,
  -- Default scale applied at startup.
  default_scale = DEFAULT_SCALE,
  -- Allow using CTRL + MouseWheel for changing the scale.
  use_mousewheel = true
}, config.plugins.scale)

local scale_steps = 0.05

local current_scale = SCALE
local current_code_scale = SCALE
local user_scale = tonumber(os.getenv("PRAGTICAL_SCALE"))
local default_scale = DEFAULT_SCALE

local function set_scale(scale)
  if current_scale == scale then return end

  scale = common.clamp(scale, 0.2, 6)

  -- save scroll positions
  local v_scrolls = {}
  local h_scrolls = {}
  for _, view in ipairs(core.root_view.root_node:get_children()) do
    local n = view:get_scrollable_size()
    if n ~= math.huge and n > view.size.y then
      v_scrolls[view] = view.scroll.y / (n - view.size.y)
    end
    local hn = view:get_h_scrollable_size()
    if hn ~= math.huge and hn > view.size.x then
      h_scrolls[view] = view.scroll.x / (hn - view.size.x)
    end
  end

  local s = scale / current_scale
  current_scale = scale

  SCALE = scale

  style.padding.x               = style.padding.x               * s
  style.padding.y               = style.padding.y               * s
  style.divider_size            = style.divider_size            * s
  style.scrollbar_size          = style.scrollbar_size          * s
  style.expanded_scrollbar_size = style.expanded_scrollbar_size * s
  style.caret_width             = style.caret_width             * s
  style.tab_width               = style.tab_width               * s

  for _, name in ipairs {"font", "big_font", "icon_font", "icon_big_font"} do
    style[name]:set_size(s * style[name]:get_size())
  end

  -- restore scroll positions
  for view, n in pairs(v_scrolls) do
    view.scroll.y = n * (view:get_scrollable_size() - view.size.y)
    view.scroll.to.y = view.scroll.y
  end
  for view, hn in pairs(h_scrolls) do
    view.scroll.x = hn * (view:get_h_scrollable_size() - view.size.x)
    view.scroll.to.x = view.scroll.x
  end

  core.redraw = true
end

local function set_scale_code(scale)
  if current_code_scale == scale then return end

  scale = common.clamp(scale, 0.2, 6)

  local s = scale / current_code_scale
  current_code_scale = scale

  style.code_font:set_size(s * style.code_font:get_size())
  for name, font in pairs(style.syntax_fonts) do
    style.syntax_fonts[name]:set_size(s * font:get_size())
  end

  core.redraw = true
end

local function get_scale()
  return current_scale
end

local function res_scale()
  set_scale(default_scale)
  if current_scale == current_code_scale then
    set_scale_code(default_scale)
  end
end

local function inc_scale()
  set_scale(current_scale + scale_steps)
  set_scale_code(current_code_scale + scale_steps)
end

local function dec_scale()
  set_scale(current_scale - scale_steps)
  set_scale_code(current_code_scale - scale_steps)
end

local function get_scale_code()
  return current_code_scale
end

local function res_scale_code()
  set_scale_code(default_scale)
end

local function inc_scale_code()
  set_scale_code(current_code_scale + scale_steps)
end

local function dec_scale_code()
  set_scale_code(current_code_scale - scale_steps)
end

if default_scale ~= config.plugins.scale.default_scale then
  if type(config.plugins.scale.default_scale) == "number" then
    set_scale(config.plugins.scale.default_scale)
  end
end

local scale_set_by_user = 0
local first_on_apply_scale = user_scale and true or false

-- The config specification used by gui generators
config.plugins.scale.config_spec = {
  name = "Scale",
  {
    label = "Autodetect Scale",
    description = "Keeps the scale equal to display, ignored on startup if PRAGTICAL_SCALE is set.",
    path = "autodetect",
    type = "toggle",
    default = true,
    on_apply = function(enabled)
      if not first_on_apply_scale then
        if not enabled then
          set_scale(config.plugins.scale.default_scale)
          set_scale_code(config.plugins.scale.default_scale)
        else
          set_scale(default_scale)
          set_scale_code(default_scale)
        end
      end
    end
  },
  {
    label = "Default Scale",
    description = "The scaling factor applied to pragtical when autodetect is not enabled.",
    path = "default_scale",
    type = "number",
    default = DEFAULT_SCALE,
    step = 0.05,
    min = 0.80,
    max = 3.00,
    set_value = function(value)
      scale_set_by_user = value
      return value
    end,
    on_apply = function(value)
      -- Perevents overwriting the scale set by user in PRAGTICAL_SCALE
      if first_on_apply_scale then
        first_on_apply_scale = false
        if scale_set_by_user == 0 then return end
      end
      if config.plugins.scale.autodetect then return end
      if value ~= current_scale then
        set_scale(value)
        set_scale_code(value)
      end
    end
  },
  {
    label = "Use MouseWheel",
    description = "Allow using CTRL [+ SHIFT] + MouseWheel for changing the scale.",
    path = "use_mousewheel",
    type = "toggle",
    default = true,
    on_apply = function(enabled)
      if enabled then
        keymap.add {
          ["ctrl+wheelup"] = "scale:increase",
          ["ctrl+wheeldown"] = "scale:decrease",
          ["ctrl+shift+wheelup"] = "scale:increase-code",
          ["ctrl+shift+wheeldown"] = "scale:decrease-code"
        }
      else
        keymap.unbind("ctrl+wheelup", "scale:increase")
        keymap.unbind("ctrl+wheeldown", "scale:decrease")
        keymap.unbind("ctrl+shift+wheelup", "scale:increase-code")
        keymap.unbind("ctrl+shift+wheeldown", "scale:decrease-code")
      end
    end
  }
}


command.add(nil, {
  ["scale:reset"] = function() res_scale() end,
  ["scale:decrease"] = function() dec_scale() end,
  ["scale:increase"] = function() inc_scale() end
})

command.add("core.docview", {
  ["scale:reset-code"] = function() res_scale_code() end,
  ["scale:decrease-code"] = function() dec_scale_code() end,
  ["scale:increase-code"] = function() inc_scale_code() end,
})

keymap.add {
  ["ctrl+0"] = "scale:reset",
  ["ctrl+-"] = "scale:decrease",
  ["ctrl+="] = "scale:increase",
  ["ctrl+shift+0"] = "scale:reset-code",
  ["ctrl+shift+-"] = "scale:decrease-code",
  ["ctrl+shift+="] = "scale:increase-code"
}

if config.plugins.scale.use_mousewheel then
  keymap.add {
    ["ctrl+wheelup"] = "scale:increase",
    ["ctrl+wheeldown"] = "scale:decrease",
    ["ctrl+shift+wheelup"] = "scale:increase-code",
    ["ctrl+shift+wheeldown"] = "scale:decrease-code"
  }
end

-- Apply custom PRAGTICAL_SCALE if set by user
if user_scale then
  set_scale(user_scale)
  set_scale_code(user_scale)
end

return {
  ["set"] = set_scale,
  ["get"] = get_scale,
  ["increase"] = inc_scale,
  ["decrease"] = dec_scale,
  ["reset"] = res_scale,
  ["set_code"] = set_scale_code,
  ["get_code"] = get_scale_code,
  ["increase_code"] = inc_scale_code,
  ["decrease_code"] = dec_scale_code,
  ["reset_code"] = res_scale_code
}

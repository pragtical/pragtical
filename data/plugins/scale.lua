-- mod-version:3
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local DocView = require "core.docview"

---Configuration options for `scale` plugin.
---@class config.plugins.scale
---Toggle auto detection of system scale.
---@field autodetect boolean
---Default scale applied at startup.
---@field default_scale number
---Allow using CTRL + MouseWheel for changing the scale.
---@field use_mousewheel boolean
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

local wheel_bindings = {
  ["ctrl+wheelup"] = "scale:increase",
  ["ctrl+wheeldown"] = "scale:decrease",
  ["ctrl+shift+wheelup"] = "scale:increase-code",
  ["ctrl+shift+wheeldown"] = "scale:decrease-code"
}

---@class plugins.scale
local scale = {}

---Save scroll positions anchored to visual rows (DocView) or
---scroll fraction (other views).
local function save_scroll_positions()
  local positions = {}
  for _, view in ipairs(core.root_view.root_node:get_children()) do
    if view:is(DocView) then
      local lh = view:get_line_height()
      positions[view] = {
        row = view.scroll.y / lh, -- fractional visual row at top
      }
    else
      local n = view:get_scrollable_size()
      local hn = view:get_h_scrollable_size()
      positions[view] = {
        v_fraction = (n ~= math.huge and n > view.size.y)
          and view.scroll.y / (n - view.size.y) or nil,
        h_fraction = (hn ~= math.huge and hn > view.size.x)
          and view.scroll.x / (hn - view.size.x) or nil,
      }
    end
  end
  return positions
end

local function restore_scroll_positions(positions)
  for view, pos in pairs(positions) do
    if pos.row then
      -- anchor the same visual row to the top of the view
      view.scroll.y = pos.row * view:get_line_height()
      view.scroll.to.y = view.scroll.y
    else
      if pos.v_fraction then
        view.scroll.y = pos.v_fraction
          * (view:get_scrollable_size() - view.size.y)
        view.scroll.to.y = view.scroll.y
      end
      if pos.h_fraction then
        view.scroll.x = pos.h_fraction
          * (view:get_h_scrollable_size() - view.size.x)
        view.scroll.to.x = view.scroll.x
      end
    end
  end
end

function scale.set(scale)
  if current_scale == scale then return end
  system.setenv("PRAGTICAL_SCALE", scale)

  scale = common.clamp(scale, 0.2, 6)

  local positions = save_scroll_positions()

  local s = scale / current_scale
  current_scale = scale

  SCALE = scale

  style.divider_size                = style.divider_size                * s
  style.outline_size                = style.outline_size                * s
  style.scrollbar_size              = style.scrollbar_size              * s
  style.expanded_scrollbar_size     = style.expanded_scrollbar_size     * s
  style.minimum_thumb_size          = style.minimum_thumb_size          * s
  style.contracted_scrollbar_margin = style.contracted_scrollbar_margin * s
  style.expanded_scrollbar_margin   = style.expanded_scrollbar_margin   * s
  style.caret_width                 = style.caret_width                 * s
  style.tab_width                   = style.tab_width                   * s
  style.padding.x                   = style.padding.x                   * s
  style.padding.y                   = style.padding.y                   * s
  style.margin.tab.top              = style.margin.tab.top              * s
  config.mouse_wheel_scroll         = config.mouse_wheel_scroll         * s

  for _, name in ipairs {"font", "big_font", "icon_font", "icon_big_font"} do
    style[name]:set_size(s * style[name]:get_size())
  end

  restore_scroll_positions(positions)

  core.redraw = true
end

function scale.set_code(value)
  if current_code_scale == value then return end
  system.setenv("PRAGTICAL_SCALE_CODE", value)

  value = common.clamp(value, 0.2, 6)

  local positions = save_scroll_positions()

  local s = value / current_code_scale
  current_code_scale = value

  style.code_font:set_size(s * style.code_font:get_size())
  for name, font in pairs(style.syntax_fonts) do
    style.syntax_fonts[name]:set_size(s * font:get_size())
  end

  restore_scroll_positions(positions)

  core.redraw = true
end

function scale.set_all(value)
  scale.set(value)
  scale.set_code(value)
end

function scale.get()
  return current_scale
end

function scale.reset()
  scale.set(DEFAULT_SCALE)
  if current_scale == current_code_scale then
    scale.set_code(DEFAULT_SCALE)
  end
end

function scale.increase()
  scale.set(current_scale + scale_steps)
  scale.set_code(current_code_scale + scale_steps)
end

function scale.decrease()
  scale.set(current_scale - scale_steps)
  scale.set_code(current_code_scale - scale_steps)
end

function scale.get_code()
  return current_code_scale
end

function scale.reset_code()
  scale.set_code(DEFAULT_SCALE)
end

function scale.increase_code()
  scale.set_code(current_code_scale + scale_steps)
end

function scale.decrease_code()
  scale.set_code(current_code_scale - scale_steps)
end

if DEFAULT_SCALE ~= config.plugins.scale.default_scale then
  if type(config.plugins.scale.default_scale) == "number" then
    scale.set(config.plugins.scale.default_scale)
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
          scale.set_all(config.plugins.scale.default_scale)
        else
          scale.set_all(DEFAULT_SCALE)
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
        scale.set_all(value)
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
        keymap.add(wheel_bindings)
      else
        for key, cmd in pairs(wheel_bindings) do
          keymap.unbind(key, cmd)
        end
      end
    end
  }
}


command.add(nil, {
  ["scale:reset"] = scale.reset,
  ["scale:decrease"] = scale.decrease,
  ["scale:increase"] = scale.increase,
})

command.add("core.docview", {
  ["scale:reset-code"] = scale.reset_code,
  ["scale:decrease-code"] = scale.decrease_code,
  ["scale:increase-code"] = scale.increase_code,
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
  keymap.add(wheel_bindings)
end

-- Apply previous scale on restart set on PRAGTICAL_SCALE and PRAGTICAL_SCALE_CODE.
if user_scale then
  -- to prevent issues on restart we defer it
  core.add_thread(function()
    scale.set(user_scale)
    scale.set_code(
      tonumber(os.getenv("PRAGTICAL_SCALE_CODE")) or user_scale
    )
  end)
end


core.menu_view:register({ "view" }, {
  {
    id = "zoom", text = "Zoom",
    items = {
      { id = "in", text = "Zoom In", command = "scale:increase" },
      { id = "out", text = "Zoom Out", command = "scale:decrease" },
      { id = "reset", text = "Reset Zoom", command = "scale:reset" },
      core.menu_view.DIVIDER,
      { id = "code-in", text = "Increase Code Font Size", command = "scale:increase-code" },
      { id = "code-out", text = "Decrease Code Font Size", command = "scale:decrease-code" },
      { id = "code-reset", text = "Reset Code Font Size", command = "scale:reset-code" }
    }
  }
}, "scale")

return scale

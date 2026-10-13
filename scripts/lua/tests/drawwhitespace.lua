local test = require "core.test"
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
local MenuView = require "core.menuview"

local path = debug.getinfo(1, "S").source:gsub("^@", "")
local root = common.dirname(common.dirname(common.dirname(common.dirname(path))))
local block = string.char(0xe2, 0x96, 0x88)

local function clear_options()
  local options = config.plugins.drawwhitespace
  if type(options) == "table" then
    for key in pairs(options) do options[key] = nil end
  end
end

local function set_error(enabled)
  local options = config.plugins.drawwhitespace
  options.show_trailing_error = enabled
  for _, option in ipairs(options.config_spec) do
    if option.path == "show_trailing_error" and option.on_apply then
      option.on_apply(enabled)
    end
  end
end

local function make_view(context, text)
  local doc = Doc(nil, nil, true)
  doc.lines = { text }
  doc.highlighter:reset()
  context.docs[#context.docs + 1] = doc
  local view = DocView(doc)
  view.size.x, view.size.y = 640, 200
  core.active_view = view
  return view
end

local function draw(context, view)
  context.calls = {}
  view:draw_line_text(1, 0, 0)
  return context.calls
end

test.describe("drawwhitespace", function()
  test.before_each(function(c)
    c.options = common.merge(config.plugins.drawwhitespace)
    c.active_view = core.active_view
    c.menu_view = core.menu_view
    core.menu_view = MenuView()
    c.update, c.draw_line_text = DocView.update, DocView.draw_line_text
    c.draw_text = renderer.draw_text
    c.docs, c.calls = {}, {}
    clear_options()
    DocView.update, DocView.draw_line_text = function() end, function() end
    dofile(root .. "/data/plugins/drawwhitespace.lua")
    local options = config.plugins.drawwhitespace
    options.enabled = true
    options.show_leading, options.show_middle = false, false
    options.show_trailing, options.show_selected_only = true, false
    renderer.draw_text = function(font, text, x, y, color)
      c.calls[#c.calls + 1] = { text = text, color = color, x = x }
      return x + font:get_width(text)
    end
  end)

  test.after_each(function(c)
    clear_options()
    config.plugins.drawwhitespace, core.active_view = c.options, c.active_view
    core.menu_view = c.menu_view
    DocView.update, DocView.draw_line_text = c.update, c.draw_line_text
    renderer.draw_text = c.draw_text
    for _, doc in ipairs(c.docs) do doc:on_close() end
  end)

  test.test("trailing errors replace space dots rather than overlap them", function(c)
    set_error(true)
    local calls = draw(c, make_view(c, "end   \n"))
    test.equal(#calls, 1)
    test.equal(calls[1].text, block:rep(3))
    test.same(calls[1].color, style.error)
  end)

  test.test("error markers honor the trailing visibility setting", function(c)
    set_error(true)
    config.plugins.drawwhitespace.show_trailing = false
    test.equal(#draw(c, make_view(c, "end   \n")), 0)
  end)

  test.test("Lua configuration enables errors without a settings callback", function(c)
    config.plugins.drawwhitespace.show_trailing_error = true
    local calls = draw(c, make_view(c, "end \n"))
    test.equal(#calls, 1)
    test.equal(calls[1].text, block)
    test.same(calls[1].color, style.error)
  end)

  test.test("toggling errors restores the configured marker and color", function(c)
    local options = config.plugins.drawwhitespace
    options.substitutions[1].sub = "s"
    options.trailing_color = { 10, 20, 30, 255 }
    local count = #options.substitutions
    local view = make_view(c, "end  \n")
    for _ = 1, 3 do
      set_error(true)
      local calls = draw(c, view)
      test.equal(#calls, 1)
      test.equal(calls[1].text, block:rep(2))
      test.equal(#options.substitutions, count)
      set_error(false)
      calls = draw(c, view)
      test.equal(#calls, 1)
      test.equal(calls[1].text, "ss")
      test.same(calls[1].color, options.trailing_color)
    end
  end)

  test.test("error rendering leaves leading, middle and tab markers unchanged", function(c)
    local options = config.plugins.drawwhitespace
    options.show_leading, options.show_middle = true, true
    local marker, tab = options.substitutions[1].sub, options.substitutions[2].sub
    set_error(true)
    local calls = draw(c, make_view(c, "  end body  \n"))
    test.equal(#calls, 3)
    test.equal(calls[1].text, marker:rep(2))
    test.equal(calls[2].text, marker)
    test.equal(calls[3].text, block:rep(2))
    calls = draw(c, make_view(c, "end\t\n"))
    test.equal(#calls, 1)
    test.equal(calls[1].text, tab)
    test.same(calls[1].color, options.color)
  end)

  test.test("selected-only errors are drawn only within the selection", function(c)
    config.plugins.drawwhitespace.show_selected_only = true
    set_error(true)
    local view = make_view(c, "end   \n")
    view.doc:set_selection(1, 5, 1, 7)
    view:update()
    local calls = draw(c, view)
    test.equal(#calls, 1)
    test.equal(calls[1].text, block:rep(2))
    test.same(calls[1].color, style.error)
  end)

  test.test("whitespace-only lines use error blocks without leading dots", function(c)
    set_error(true)
    local calls = draw(c, make_view(c, "   \n"))
    test.equal(#calls, 1)
    test.equal(calls[1].text, block:rep(3))
  end)
end)

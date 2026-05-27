local test = require "core.test"
local Doc = require "core.doc"
local DocView = require "core.docview"
local LineWrapping = require "plugins.linewrapping"

local function make_view(text)
  local doc = Doc(nil, nil, true)
  doc.lines = { text }
  doc.cache.col_x = {}
  doc.cache.ulen = {}
  doc.highlighter:reset()

  local view = DocView(doc)
  view.position.x = 0
  view.position.y = 0
  view.size.x = 320
  view.size.y = 200
  view.indentguide_indents = {}
  view.indentguide_indent_active = {}
  return view
end

local function with_draw_text(fn)
  local original = renderer.draw_text
  local calls = {}
  renderer.draw_text = function(font, text, x, y, color, options)
    calls[#calls + 1] = {
      text = text,
      x = x,
      y = y,
      color = color,
      options = options
    }
    return x + font:get_width(text, options)
  end

  local ok, err = pcall(fn, calls)
  renderer.draw_text = original
  if not ok then error(err, 0) end
end

test.describe("linewrapping", function()
  test.test("draw_line_text keeps final wrapped segment", function()
    local view = make_view("abcdef")
    local font = view:get_font()
    LineWrapping.reconstruct_breaks(view, font, font:get_width("abc"))
    local x, y = view:get_line_screen_position(1)

    with_draw_text(function(calls)
      view:draw_line_text(1, x, y)

      local text = {}
      for _, call in ipairs(calls) do
        text[#text + 1] = call.text
        test.type(call.options, "table")
        test.type(call.options.tab_offset, "number")
      end
      test.equal(table.concat(text), "abcdef")
    end)
  end)
end)

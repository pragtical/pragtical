local core = require "core"
local config = require "core.config"
local View = require "core.view"
local RootView = require "core.rootview"
local test = require "core.test"
local Doc = require "core.doc"
local DocView = require "core.docview"
local MarkdownView = require "core.markdownview"
local autocomplete = require "plugins.autocomplete"

test.describe("autocomplete floating popups", function()
  test.before_each(function(context)
    context.root, context.active, context.last, context.next = core.root_view, core.active_view, core.last_active_view, core.next_active_view
    context.transitions = config.transitions
    config.transitions = false
    autocomplete.close()
    core.root_view = RootView(); core.root_view.root_node.is_primary_node = true
    core.root_view.size.x, core.root_view.size.y = 700, 500
    context.view = DocView(Doc())
    core.root_view:get_primary_node():add_view(context.view)
    core.root_view:update(); core.root_view:update()
  end)
  test.after_each(function(context)
    autocomplete.close()
    core.root_view, core.active_view, core.last_active_view, core.next_active_view = context.root, context.active, context.last, context.next
    config.transitions = context.transitions
  end)

  test.test("completion and markdown use shared ownership and pointer capture", function(context)
    autocomplete.complete({ name = "floating-test", files = ".*", items = {
      sample = { desc = ("Documentation paragraph.\n\n"):rep(80) }
    } })
    core.root_view:update(); core.root_view:update()
    test.equal(#core.root_view.floating_views, 2)
    local doc
    for _, view in ipairs(core.root_view.floating_views) do
      if view:is(MarkdownView) then doc = view end
    end
    test.not_nil(doc)
    core.on_event("mousemoved", doc.position.x + 10, doc.position.y + 10, 0, 0)
    core.on_event("mousewheel", -1, 0)
    test.ok(doc.scroll.to.y > 0)
    test.equal(core.active_view, context.view)
    core.on_event("mousepressed", "left", doc.position.x + 10, doc.position.y + 10, 1)
    core.on_event("mousereleased", "left", -10, -10)
    test.is_nil(core.root_view.grab)
    core.set_active_view(View())
    core.root_view:update()
    test.equal(#core.root_view.floating_views, 0)
  end)
  test.test("wheel reveals later results and click uses the selected completion callback", function(context)
    local items, selected = {}, nil
    for i = 1, 30 do
      local text = string.format("item%02d", i)
      items[text] = { onselect = function(_, item) selected = item.text; return true end }
    end
    autocomplete.complete({ name = "pointer-test", files = ".*", items = items })
    core.root_view:update(); core.root_view:update()
    local popup = core.root_view.floating_views[1]
    local x, y, w = popup:get_floating_bounds()
    local py = y + require("core.style").padding.y / 2 + context.view:get_font():get_height() / 2
    core.on_event("mousemoved", x + w / 2, py, 0, 0)
    core.on_event("mousewheel", -2, 0)
    core.root_view:update()
    core.on_event("mousepressed", "left", x + w / 2, py, 1)
    core.on_event("mousereleased", "left", x + w / 2, py)
    test.equal(selected, "item03")
    test.not_ok(autocomplete.is_open())
    test.equal(core.active_view, context.view)
    test.equal(context.view.doc.lines[1], "\n")
  end)

  test.test("outside release cancels mouse acceptance", function(context)
    autocomplete.complete({ name = "pointer-test", files = ".*", items = { sample = false } })
    core.root_view:update(); core.root_view:update()
    local popup = core.root_view.floating_views[1]
    local x, y, w = popup:get_floating_bounds()
    core.on_event("mousepressed", "left", x + w / 2, y + 15, 1)
    core.on_event("mousereleased", "left", -10, -10)
    test.ok(autocomplete.is_open())
    test.equal(context.view.doc.lines[1], "\n")
  end)

  test.test("documentation selection stops on window focus loss", function()
    autocomplete.complete({ name = "pointer-test", files = ".*", items = {
      sample = { desc = "Selectable documentation." }
    } })
    core.root_view:update(); core.root_view:update()
    local popup
    for _, view in ipairs(core.root_view.floating_views) do
      if view:is(MarkdownView) then popup = view end
    end
    test.not_nil(popup)
    core.on_event("mousepressed", "left", popup.position.x + 12, popup.position.y + 12, 1)
    test.ok(popup.selecting)
    core.on_event("focuslost")
    test.not_ok(popup.selecting)
    test.is_nil(core.root_view.grab)
  end)

  test.test("switching document tabs clears completion predicates", function(context)
    autocomplete.complete({ name = "pointer-test", files = ".*", items = { sample = false } })
    core.root_view:update()
    local other = DocView(Doc())
    core.root_view:get_primary_node():add_view(other)
    core.root_view:update()
    test.not_ok(autocomplete.is_open())
    test.not_ok(require("core.command").is_valid("autocomplete:complete"))
    test.equal(#core.root_view.floating_views, 0)
    test.equal(other.doc.lines[1], "\n")
  end)

end)

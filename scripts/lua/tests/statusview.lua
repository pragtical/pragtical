local test = require "core.test"
local StatusView = require "core.statusview"
local style = require "core.style"

local function make_status_view()
  local view = StatusView()
  view.position.x = 0
  view.position.y = 0
  view.size.x = 320
  view.size.y = style.font:get_height() + style.padding.y * 2
  view.items = {}
  view.active_items = {}
  return view
end

test.describe("statusview", function()
  test.it("skips hidden item rebuilds while a message is visible", function()
    local view = make_status_view()
    local calls = 0

    view:add_item({
      name = "test:item",
      get_item = function()
        calls = calls + 1
        return { "visible" }
      end
    })

    view:update()
    test.equal(calls, 1)

    view:show_message("i", style.text, "Saved")
    view:update()
    test.equal(calls, 1)

    view.message_timeout = 0
    view:update()
    test.equal(calls, 2)
  end)
end)

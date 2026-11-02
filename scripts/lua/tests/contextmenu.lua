local command = require "core.command"
local common = require "core.common"
local core = require "core"
local ContextMenu = require "core.contextmenu"
local style = require "core.style"
local test = require "core.test"

local visible_command = "contextmenu-test:visible"
local filtered_command = "contextmenu-test:filtered"
local previous_commands
local menus = {}

local function new_menu(items)
  local menu = ContextMenu()
  table.insert(menus, menu)
  menu:register(nil, items)
  test.equal(menu:show(0, 0), true)
  return menu
end

test.describe("contextmenu", function()
  test.before_each(function(context)
    context.draw_poly, context.draw_text = renderer.draw_poly, common.draw_text
    previous_commands = {
      visible = command.map[visible_command],
      filtered = command.map[filtered_command]
    }
    command.add(nil, {
      [visible_command] = function() end
    })
    command.add(function() return false end, {
      [filtered_command] = function() end
    })
  end)

  test.after_each(function(context)
    renderer.draw_poly, common.draw_text = context.draw_poly, context.draw_text
    for _, menu in ipairs(menus) do menu:hide() end
    menus = {}
    command.map[visible_command] = previous_commands.visible
    command.map[filtered_command] = previous_commands.filtered
  end)

  test.test("removes a leading divider after command filtering", function()
    local menu = new_menu {
      { text = "A filtered item that is much wider", command = filtered_command },
      ContextMenu.DIVIDER,
      { text = "Visible", command = visible_command }
    }

    test.equal(#menu.items, 1)
    test.equal(menu.items[1].text, "Visible")
    test.equal(
      menu.items.width,
      style.font:get_width("Visible") + style.padding.x * 2
    )
    test.equal(
      menu.items.height,
      style.font:get_height() + style.padding.y
    )
  end)

  test.test("removes a trailing divider after command filtering", function()
    local menu = new_menu {
      { text = "Visible", command = visible_command },
      ContextMenu.DIVIDER,
      { text = "Filtered", command = filtered_command }
    }

    test.equal(#menu.items, 1)
    test.equal(menu.items[1].text, "Visible")
  end)

  test.test("collapses consecutive dividers after command filtering", function()
    local menu = new_menu {
      { text = "First", command = visible_command },
      ContextMenu.DIVIDER,
      { text = "Filtered", command = filtered_command },
      ContextMenu.DIVIDER,
      { text = "Last", command = visible_command }
    }

    test.equal(#menu.items, 3)
    test.equal(menu.items[1].text, "First")
    test.equal(menu.items[2], ContextMenu.DIVIDER)
    test.equal(menu.items[3].text, "Last")
  end)

  test.test("draws checked and unchecked icons with cached toggle states", function()
    local checked = false
    local menu = new_menu {
      { text = "Checked", command = visible_command, checked = true },
      { text = "Toggle", command = visible_command, checked = function() return checked end }
    }
    local marks, labels = {}, {}
    renderer.draw_poly = function()
      test.fail("checkboxes should use the bundled icon font")
    end
    common.draw_text = function(font, color, text, _, x)
      if text == "☑" or text == "☐" then
        marks[#marks + 1] = text
        test.equal(font, style.icon_font)
        test.equal(color, style.text)
      else
        labels[#labels + 1] = x
      end
    end
    local function draw()
      renderer.begin_frame(core.window)
      local ok, err = pcall(menu.draw, menu)
      renderer.end_frame()
      test.ok(ok, err)
    end
    menu:update()
    draw()
    test.same(marks, { "☑", "☐" })
    test.equal(labels[1], labels[2])
    checked = true
    marks = {}
    draw()
    test.same(marks, { "☑", "☐" })
    menu:hide()
    test.ok(menu:show(0, 0))
    marks = {}
    draw()
    test.same(marks, { "☑", "☑" })
  end)

  for _, application in ipairs { false, true } do
    test.test((application and "application" or "context") .. " entries are not rebuilt each frame", function()
      local checks, visibility, checked, performed, enabled = 0, 0, 0, 0, true
      command.add(function() checks = checks + 1; return enabled end, {
        [visible_command] = function() performed = performed + 1 end
      })
      local menu = ContextMenu()
      menus[#menus + 1] = menu
      menu:show_items({ { text = "Run", command = visible_command,
        visible = function() visibility = visibility + 1; return true end,
        checked = function() checked = checked + 1; return true end
      } }, 0, 0, { disabled = application })
      local items, count, visible_count, checked_count = menu.items, checks, visibility, checked
      enabled = false
      renderer.begin_frame(core.window)
      local ok, err = pcall(function()
        for _ = 1, 30 do menu:update(); menu:draw() end
      end)
      renderer.end_frame()
      test.ok(ok, err)
      test.equal(checks, count)
      test.equal(visibility, visible_count)
      test.equal(checked, checked_count)
      test.equal(menu.items, items)
      test.equal(#menu.items, 1)
      menu.selected = 1
      menu:call_selected_item()
      test.ok(checks > count)
      test.equal(performed, 0)
    end)
  end
end)

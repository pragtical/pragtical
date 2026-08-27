local command = require "core.command"
local ContextMenu = require "core.contextmenu"
local style = require "core.style"
local test = require "core.test"

local visible_command = "contextmenu-test:visible"
local filtered_command = "contextmenu-test:filtered"
local previous_commands

local function new_menu(items)
  local menu = ContextMenu()
  menu:register(nil, items)
  test.equal(menu:show(0, 0), true)
  return menu
end

test.describe("contextmenu", function()
  test.before_each(function()
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

  test.after_each(function()
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
end)

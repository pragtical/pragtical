local common = require "core.common"
local core = require "core"
local command = require "core.command"
local config = require "core.config"
local http = require "core.http"
local keymap = require "core.keymap"
local style = require "core.style"
local test = require "core.test"
local DocView = require "core.docview"
local MarkdownView = require "core.markdownview"

local temp_root
local project_temp_root

local function write_file(path, content)
  local file, err = io.open(path, "wb")
  test.not_nil(file, err)
  file:write(content)
  file:close()
end

local function path_belongs_to_root(path, root)
  if not (path and root) then
    return false
  end
  path = common.normalize_path(path)
  root = common.normalize_path(root)
  return path == root or common.path_belongs_to(path, root)
end

local function path_is_in_test_roots(context, path)
  return path and (
    path_belongs_to_root(path, context.temp_root)
    or path_belongs_to_root(path, context.project_temp_root)
  )
end

local function close_test_views_and_docs(context)
  local views = core.root_view.root_node:get_children()
  for i = #views, 1, -1 do
    local view = views[i]
    local path = view.path or (view.doc and view.doc.abs_filename)
    if path_is_in_test_roots(context, path) then
      local node = core.root_view.root_node:get_node_for_view(view)
      if node then
        if view:extends(DocView) and view.doc:is_dirty() then
          view.doc:clean()
        end
        node:remove_view(core.root_view.root_node, view)
      end
    end
  end

  for i = #core.docs, 1, -1 do
    local doc = core.docs[i]
    if path_is_in_test_roots(context, doc.abs_filename) then
      table.remove(core.docs, i)
      doc:on_close()
    end
  end
end

local function remove_test_path(path)
  local ok, err
  for _ = 1, 20 do
    if not system.get_file_info(path) then
      return true
    end
    collectgarbage("collect")
    ok, err = common.rm(path, true)
    if ok or not system.get_file_info(path) then
      return true
    end
    system.sleep(0.05)
  end
  return false, err
end

test.describe("markdownview", function()
  test.before_each(function(context)
    temp_root = USERDIR
      .. PATHSEP .. "markdownview-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    local ok, err = common.mkdirp(temp_root)
    test.ok(ok, err)
    context.temp_root = temp_root

    project_temp_root = core.root_project().path
      .. PATHSEP .. "markdownview-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    ok, err = common.mkdirp(project_temp_root)
    test.ok(ok, err)
    context.project_temp_root = project_temp_root
  end)

  test.after_each(function(context)
    close_test_views_and_docs(context)
    if PLATFORM ~= "Windows" then
      if context.temp_root and system.get_file_info(context.temp_root) then
        local ok, err = remove_test_path(context.temp_root)
        test.ok(ok, err)
      end
      if context.project_temp_root and system.get_file_info(context.project_temp_root) then
        local ok, err = remove_test_path(context.project_temp_root)
        test.ok(ok, err)
      end
    end
  end)

  test.test("parses the supported markdown blocks", function()
    test.ok(MarkdownView.is_supported("README.md"))
    test.ok(MarkdownView.is_supported("README.markdown"))
    test.not_ok(MarkdownView.is_supported("README.txt"))

    local blocks = MarkdownView.parse_blocks([[
# Heading

Paragraph with **bold**, *italic*, [link](https://example.com) and `code`.

- first item
- second item

> quoted text

---

```lua
print("hello")
```
]])

    test.equal(#blocks, 6)
    test.equal(blocks[1].type, "heading")
    test.equal(blocks[1].level, 1)
    test.equal(blocks[2].type, "paragraph")
    test.equal(blocks[3].type, "unordered_list")
    test.equal(#blocks[3].items, 2)
    test.equal(blocks[4].type, "quote")
    test.equal(blocks[5].type, "rule")
    test.equal(blocks[6].type, "code")
    test.equal(blocks[6].info, "lua")
    test.equal(blocks[6].lines[1], 'print("hello")')
  end)

  test.test("parses task list items", function()
    local blocks = MarkdownView.parse_blocks([[
- [ ] Open task
- [x] Done task
]])

    test.equal(#blocks, 1)
    test.equal(blocks[1].type, "unordered_list")
    test.equal(#blocks[1].items, 2)
    test.equal(blocks[1].items[1].checked, false)
    test.equal(blocks[1].items[1].text, "Open task")
    test.equal(blocks[1].items[2].checked, true)
    test.equal(blocks[1].items[2].text, "Done task")
  end)

  test.test("parses document frontmatter as a block", function()
    local blocks = MarkdownView.parse_blocks([[
---
slug: pragtical-v3101-release
title: Pragtical v3.10.1 Release
authors: jgmdev
---

# Release Notes
]])

    test.equal(#blocks, 2)
    test.equal(blocks[1].type, "frontmatter")
    test.equal(blocks[1].info, "yaml")
    test.same(blocks[1].lines, {
      "slug: pragtical-v3101-release",
      "title: Pragtical v3.10.1 Release",
      "authors: jgmdev"
    })
    test.equal(blocks[2].type, "heading")
    test.equal(blocks[2].text, "Release Notes")
  end)

  test.test("parses toml frontmatter as a block", function()
    local blocks = MarkdownView.parse_blocks([[
+++
title = "My Article Title"
date = 2024-01-15
author = "John Doe"
tags = ["markdown", "tutorial", "web"]
+++

# Article
]])

    test.equal(#blocks, 2)
    test.equal(blocks[1].type, "frontmatter")
    test.equal(blocks[1].info, "toml")
    test.same(blocks[1].lines, {
      'title = "My Article Title"',
      "date = 2024-01-15",
      'author = "John Doe"',
      'tags = ["markdown", "tutorial", "web"]'
    })
    test.equal(blocks[2].type, "heading")
  end)

  test.test("parses json frontmatter as a block", function()
    local blocks = MarkdownView.parse_blocks([[
;;;
{
  "title": "My Article Title",
  "date": "2024-01-15",
  "author": "John Doe",
  "tags": ["markdown", "tutorial", "web"]
}
;;;

# Article
]])

    test.equal(#blocks, 2)
    test.equal(blocks[1].type, "frontmatter")
    test.equal(blocks[1].info, "json")
    test.same(blocks[1].lines, {
      "{",
      '  "title": "My Article Title",',
      '  "date": "2024-01-15",',
      '  "author": "John Doe",',
      '  "tags": ["markdown", "tutorial", "web"]',
      "}"
    })
    test.equal(blocks[2].type, "heading")
  end)

  test.test("does not parse mismatched frontmatter delimiters", function()
    local blocks = MarkdownView.parse_blocks([[
+++
title = "My Article Title"
---

# Article
]])

    test.not_equal(blocks[1].type, "frontmatter")
  end)

  test.test("renders frontmatter lines without collapsing them", function()
    local view = MarkdownView([[
+++
title = "My Article Title"
date = 2024-01-15
author = "John Doe"
tags = ["markdown", "tutorial", "web"]
+++

# Release Notes
]])
    view.size.x = 640
    view.size.y = 360

    local text_lines = {}
    for _, command in ipairs(view:ensure_layout().commands) do
      if command.type == "text" then
        local fragments = {}
        for _, fragment in ipairs(command.fragments or {}) do
          fragments[#fragments + 1] = fragment.text or ""
        end
        text_lines[#text_lines + 1] = table.concat(fragments)
      end
    end

    test.equal(text_lines[1], 'title = "My Article Title"')
    test.equal(text_lines[2], "date = 2024-01-15")
    test.equal(text_lines[3], 'author = "John Doe"')
    test.equal(text_lines[4], 'tags = ["markdown", "tutorial", "web"]')
    test.equal(text_lines[5], "Release Notes")
  end)

  test.test("appends markdown incrementally at block boundaries", function()
    local view = MarkdownView("# One\n\nFirst paragraph.\n\n")
    local before_blocks = view.blocks
    local before_first_block = view.blocks[1]

    local incremental = view:append_markdown("## Two\n\nSecond paragraph with **bold**.\n")

    test.equal(incremental, true)
    test.equal(view.text, "# One\n\nFirst paragraph.\n\n## Two\n\nSecond paragraph with **bold**.\n")
    test.equal(view.blocks, before_blocks)
    test.equal(view.blocks[1], before_first_block)
    test.equal(#view.blocks, 4)
    test.equal(view.blocks[3].type, "heading")
    test.equal(view.blocks[3].text, "Two")
    test.equal(view.blocks[4].type, "paragraph")
    test.equal(view.blocks[4].text, "Second paragraph with **bold**.")
  end)

  test.test("falls back to full parse when append continues a block", function()
    local view = MarkdownView("First")
    local before_blocks = view.blocks

    local incremental = view:append_markdown(" paragraph")

    test.equal(incremental, false)
    test.equal(view.text, "First paragraph")
    test.not_equal(view.blocks, before_blocks)
    test.equal(#view.blocks, 1)
    test.equal(view.blocks[1].type, "paragraph")
    test.equal(view.blocks[1].text, "First paragraph")
  end)

  test.test("renders partial text without mutating parsed markdown", function()
    local view = MarkdownView("# Session\n\n## User\n\nHello")
    view.size.x = 400
    local before_blocks = view.blocks
    local before_text = view.text
    local before_height = view:get_scrollable_size()

    view:set_partial_text("streaming **literal** text")

    test.equal(view.text, before_text)
    test.equal(view.blocks, before_blocks)
    test.equal(view.partial_text, "streaming **literal** text")
    test.ok(view:get_scrollable_size() > before_height)
  end)

  test.test("clears partial text without changing markdown", function()
    local view = MarkdownView("# Session\n\n## Assistant\n\nHello")
    local before_text = view.text

    view:set_partial_text("temporary")
    view:clear_partial_text()

    test.equal(view.partial_text, nil)
    test.equal(view.text, before_text)
  end)

  test.test("commits partial text as final markdown", function()
    local view = MarkdownView("# Session\n\n## User\n\nHello")
    view:set_partial_text("temporary **literal**")

    local incremental = view:commit_partial_text("\n\n## Assistant\n\nHello **world**.")

    test.equal(incremental, true)
    test.equal(view.partial_text, nil)
    test.equal(view.text:find("temporary", 1, true), nil)
    test.equal(view.text:find("Hello **world**.", 1, true) ~= nil, true)
    test.equal(view.blocks[#view.blocks].type, "paragraph")
    test.equal(view.blocks[#view.blocks].text, "Hello **world**.")
  end)

  test.test("appends to existing layout when no footnotes need rebuilding", function()
    local view = MarkdownView("# One\n\nFirst paragraph.\n\n")
    view.size.x = 400
    local layout = view:ensure_layout()
    local before_commands = #layout.commands

    local incremental = view:append_markdown("## Two\n\nSecond paragraph.\n")

    test.equal(incremental, true)
    test.equal(view.layout, layout)
    test.ok(#view.layout.commands > before_commands)
    test.equal(#view.blocks, 4)
  end)

  test.test("renders horizontal lines using the caret color", function()
    local view = MarkdownView([[
# Heading

---

Paragraph with a footnote.[^note]

[^note]: Footnote body.
]])
    view.size.x = 420
    view.size.y = 240

    local layout = view:ensure_layout()
    local rule_height = math.max(style.divider_size, 1)
    local caret_lines = 0

    for _, command in ipairs(layout.commands) do
      if command.type == "rect"
        and command.height == rule_height
        and MarkdownView.resolve_color(command.color) == style.caret
      then
        caret_lines = caret_lines + 1
      end
    end

    test.equal(caret_lines, 3)
  end)

  test.test("selects rendered text with the mouse", function()
    local view = MarkdownView("# Title\n\nParagraph one")
    view.position.x = 0
    view.position.y = 0
    view.size.x = 400
    view.size.y = 300
    local layout = view:ensure_layout()
    local paragraph_command
    for _, command in ipairs(layout.commands) do
      if command.type == "text" then
        local text = {}
        for _, fragment in ipairs(command.fragments) do
          text[#text + 1] = fragment.text or ""
        end
        if table.concat(text) == "Paragraph one" then
          paragraph_command = command
          break
        end
      end
    end

    test.not_nil(paragraph_command)
    local y = style.padding.y + paragraph_command.y + paragraph_command.height / 2
    view:on_mouse_pressed("left", style.padding.x + paragraph_command.x, y, 1)
    view:on_mouse_moved(style.padding.x + paragraph_command.x + 1000, y, 1000, 0)
    view:on_mouse_released("left", style.padding.x + paragraph_command.x + 1000, y)

    test.equal(view:get_selected_text(), "Paragraph one")
  end)

  test.test("shows selected text in code blocks", function()
    local view = MarkdownView("```lua\nlocal x = 1\n```")
    view.position.x = 0
    view.position.y = 0
    view.size.x = 400
    view.size.y = 300
    local layout = view:ensure_layout()
    local code_command

    for _, command in ipairs(layout.commands) do
      if command.type == "text" and command.tabbed then
        code_command = command
        break
      end
    end

    test.not_nil(code_command)
    local y = style.padding.y + code_command.y + code_command.height / 2
    view:on_mouse_pressed("left", style.padding.x + code_command.x, y, 1)
    view:on_mouse_moved(style.padding.x + code_command.x + 1000, y, 1000, 0)
    view:on_mouse_released("left", style.padding.x + code_command.x + 1000, y)
    test.equal(view:get_selected_text(), "local x = 1")

    local events = {}
    local original_draw_text = renderer.draw_text
    local original_draw_rect = renderer.draw_rect
    local original_push_clip_rect = core.push_clip_rect
    local original_pop_clip_rect = core.pop_clip_rect

    view.draw_background = function() end
    view.draw_scrollbar = function() end
    core.push_clip_rect = function() end
    core.pop_clip_rect = function() end
    renderer.draw_rect = function(_, _, _, _, color)
      if color == style.background2 then
        events[#events + 1] = "code-background"
      elseif color == style.selection then
        events[#events + 1] = "selection"
      end
    end
    renderer.draw_text = function(font, text, x, y, color, opts)
      if text ~= "" then
        events[#events + 1] = "text"
      end
      return x + font:get_width(text, opts)
    end

    view:draw()

    renderer.draw_text = original_draw_text
    renderer.draw_rect = original_draw_rect
    core.push_clip_rect = original_push_clip_rect
    core.pop_clip_rect = original_pop_clip_rect

    local code_background_index
    local selection_index
    local text_index
    for index, event in ipairs(events) do
      if event == "code-background" and not code_background_index then
        code_background_index = index
      elseif event == "selection" and not selection_index then
        selection_index = index
      elseif event == "text" and selection_index and not text_index then
        text_index = index
      end
    end

    test.not_nil(code_background_index)
    test.not_nil(selection_index)
    test.not_nil(text_index)
    test.ok(code_background_index < selection_index)
    test.ok(selection_index < text_index)
  end)

  test.test("shows selected text in inline code spans", function()
    local view = MarkdownView("Paragraph with `inline code` text")
    view.position.x = 0
    view.position.y = 0
    view.size.x = 400
    view.size.y = 300
    local layout = view:ensure_layout()
    local code_command
    local code_fragment
    local code_x = 0

    for _, command in ipairs(layout.commands) do
      if command.type == "text" then
        local fragment_x = 0
        for _, fragment in ipairs(command.fragments) do
          if fragment.background then
            code_command = command
            code_fragment = fragment
            code_x = fragment_x
            break
          end
          fragment_x = fragment_x + (fragment.width or 0)
        end
      end
      if code_command then
        break
      end
    end

    test.not_nil(code_command)
    test.not_nil(code_fragment)
    local start_x = style.padding.x + code_command.x + code_x
    local y = style.padding.y + code_command.y + code_command.height / 2
    view:on_mouse_pressed("left", start_x, y, 1)
    view:on_mouse_moved(start_x + code_fragment.width + 1, y, code_fragment.width + 1, 0)
    view:on_mouse_released("left", start_x + code_fragment.width + 1, y)
    test.equal(view:get_selected_text(), "inline code")

    local events = {}
    local original_draw_text = renderer.draw_text
    local original_draw_rect = renderer.draw_rect
    local original_push_clip_rect = core.push_clip_rect
    local original_pop_clip_rect = core.pop_clip_rect

    view.draw_background = function() end
    view.draw_scrollbar = function() end
    core.push_clip_rect = function() end
    core.pop_clip_rect = function() end
    renderer.draw_rect = function(_, _, _, _, color)
      if color == style.background2 then
        events[#events + 1] = "inline-code-background"
      elseif color == style.selection then
        events[#events + 1] = "selection"
      end
    end
    renderer.draw_text = function(font, text, x, y, color, opts)
      if text ~= "" then
        events[#events + 1] = "text"
      end
      return x + font:get_width(text, opts)
    end

    view:draw()

    renderer.draw_text = original_draw_text
    renderer.draw_rect = original_draw_rect
    core.push_clip_rect = original_push_clip_rect
    core.pop_clip_rect = original_pop_clip_rect

    local code_background_index
    local selection_index
    local text_index
    for index, event in ipairs(events) do
      if event == "inline-code-background" and not code_background_index then
        code_background_index = index
      elseif event == "selection" and not selection_index then
        selection_index = index
      elseif event == "text" and selection_index and not text_index then
        text_index = index
      end
    end

    test.not_nil(code_background_index)
    test.not_nil(selection_index)
    test.not_nil(text_index)
    test.ok(code_background_index < selection_index)
    test.ok(selection_index < text_index)
  end)

  test.test("copies selected rendered text", function()
    local view = MarkdownView("# Title\n\nParagraph one")
    view.size.x = 400
    view.selection_anchor = 1
    view.selection_cursor = 6

    test.equal(view:copy_selection(), true)
    test.equal(system.get_clipboard(), "Title")

    local node = core.root_view:get_active_node_default()
    node:add_view(view)
    node:set_active_view(view)
    system.set_clipboard("")
    test.equal(command.perform("markdown-view:copy"), true)
    test.equal(system.get_clipboard(), "Title")
    local copy_shortcut = PLATFORM == "Mac OS X" and "cmd+c" or "ctrl+c"
    test.equal(keymap.map[copy_shortcut][1], "markdown-view:copy")
    test.equal(keymap.map[copy_shortcut][2], "doc:copy")
    node:remove_view(core.root_view.root_node, view)
  end)

  test.test("shows context copy entry when markdown text is selected", function()
    local contextmenu = require "plugins.contextmenu"
    local view = MarkdownView("# Title\n\nParagraph one")
    view.position.x = 0
    view.position.y = 0
    view.size.x = 420
    view.size.y = 240
    core.set_active_view(view)

    local function has_menu_item(text)
      for _, item in ipairs(contextmenu.items or {}) do
        if item.text == text then
          return true
        end
      end
      return false
    end

    view.selection_anchor = 1
    view.selection_cursor = 6
    test.equal(contextmenu:show(style.padding.x + 1, style.padding.y + 1), true)
    test.equal(has_menu_item("Copy"), true)
    contextmenu:hide()

    view:clear_selection()
    test.equal(contextmenu:show(style.padding.x + 1, style.padding.y + 1), false)
    test.equal(has_menu_item("Copy"), false)
    contextmenu:hide()
  end)

  test.test("keeps arrow cursor over the scrollbar", function()
    local lines = {}
    for i = 1, 40 do
      lines[i] = "Line " .. i
    end
    local view = MarkdownView(table.concat(lines, "\n\n"))
    view.position.x = 0
    view.position.y = 0
    view.size.x = 300
    view.size.y = 80
    view:ensure_layout()
    view:update_scrollbar()

    local x, y, w, h = view.v_scrollbar:get_thumb_rect()
    view.cursor = "ibeam"
    test.equal(view:on_mouse_moved(x + w / 2, y + h / 2, 0, 0), true)
    test.equal(view.cursor, "arrow")
  end)

  test.test("shows context copy entries for markdown targets", function(context)
    local contextmenu = require "plugins.contextmenu"
    local link_view = MarkdownView("[inline](https://example.com)")
    link_view.position.x = 0
    link_view.position.y = 0
    link_view.size.x = 420
    link_view.size.y = 240
    core.set_active_view(link_view)

    local link
    for _, command_item in ipairs(link_view:ensure_layout().commands) do
      if command_item.links then
        link = command_item.links[1]
        break
      end
    end
    test.not_nil(link)

    local function has_menu_item(text)
      for _, item in ipairs(contextmenu.items or {}) do
        if item.text == text then
          return true
        end
      end
      return false
    end

    local x = style.padding.x + link.x + 1
    local y = style.padding.y + link.y + 1
    test.equal(contextmenu:show(x, y), true)
    test.equal(has_menu_item("Copy Link"), true)
    test.equal(has_menu_item("Copy Image Link"), false)
    contextmenu:hide()

    local image_path = context.project_temp_root .. PATHSEP .. "diagram.png"
    local source_path = context.project_temp_root .. PATHSEP .. "source.md"
    write_file(image_path, "not-a-real-png")
    write_file(source_path, "[![Diagram](diagram.png)](https://example.com/diagram)\n")

    local original_load_image = canvas.load_image
    canvas.load_image = function()
      return {
        get_size = function()
          return 80, 40
        end,
        scaled = function(_, width, height)
          return {
            get_size = function()
              return width, height
            end
          }
        end
      }
    end

    local image_view = MarkdownView(source_path)
    image_view.position.x = 0
    image_view.position.y = 0
    image_view.size.x = 420
    image_view.size.y = 240
    local image = image_view:ensure_layout().commands[1]
    canvas.load_image = original_load_image
    core.set_active_view(image_view)

    x = style.padding.x + image.x + 1
    y = style.padding.y + image.y + 1
    test.equal(contextmenu:show(x, y), true)
    test.equal(has_menu_item("Copy Link"), true)
    test.equal(has_menu_item("Copy Image Link"), true)
    test.equal(image_view.markdown_context_target.link_url, "https://example.com/diagram")
    test.equal(image_view.markdown_context_target.image_url, "diagram.png")
    contextmenu:hide()

    write_file(source_path, "![Diagram](diagram.png)\n")
    image_view = MarkdownView(source_path)
    image_view.position.x = 0
    image_view.position.y = 0
    image_view.size.x = 420
    image_view.size.y = 240
    canvas.load_image = function()
      return {
        get_size = function()
          return 80, 40
        end,
        scaled = function(_, width, height)
          return {
            get_size = function()
              return width, height
            end
          }
        end
      }
    end
    image = image_view:ensure_layout().commands[1]
    canvas.load_image = original_load_image
    core.set_active_view(image_view)
    x = style.padding.x + image.x + 1
    y = style.padding.y + image.y + 1
    test.equal(contextmenu:show(x, y), true)
    test.equal(has_menu_item("Copy Link"), false)
    test.equal(has_menu_item("Copy Image Link"), true)
    contextmenu:hide()

    local plain_view = MarkdownView("plain text")
    plain_view.position.x = 0
    plain_view.position.y = 0
    plain_view.size.x = 420
    plain_view.size.y = 240
    core.set_active_view(plain_view)
    contextmenu:show(style.padding.x + 1, style.padding.y + 1)
    test.equal(has_menu_item("Copy Link"), false)
    test.equal(has_menu_item("Copy Image Link"), false)
    contextmenu:hide()
  end)

  test.test("parses nested list indentation", function()
    local blocks = MarkdownView.parse_blocks([[
- Parent
  - Child
    - Grandchild
- Sibling
]])

    test.equal(#blocks, 1)
    test.equal(blocks[1].type, "unordered_list")
    test.equal(blocks[1].items[1].nesting, 0)
    test.equal(blocks[1].items[2].nesting, 0)
    test.equal(blocks[1].items[1].blocks[2].type, "unordered_list")
    test.equal(blocks[1].items[1].blocks[2].items[1].text, "Child")
    test.equal(blocks[1].items[1].blocks[2].items[1].blocks[2].type, "unordered_list")
    test.equal(blocks[1].items[1].blocks[2].items[1].blocks[2].items[1].text, "Grandchild")
  end)

  test.test("parses nested list items after marker-aligned continuation indent", function()
    local blocks = MarkdownView.parse_blocks([[
*   Parent

    *   Child
    *   Sibling
]])

    test.equal(#blocks, 1)
    test.equal(blocks[1].type, "unordered_list")
    test.equal(blocks[1].items[1].blocks[2].type, "unordered_list")
    test.equal(blocks[1].items[1].blocks[2].items[1].text, "Child")
    test.equal(blocks[1].items[1].blocks[2].items[2].text, "Sibling")
  end)

  test.test("parses indented code blocks", function()
    local blocks = MarkdownView.parse_blocks([[
Paragraph

    local x = 1
    print(x)
]])

    test.equal(#blocks, 2)
    test.equal(blocks[1].type, "paragraph")
    test.equal(blocks[2].type, "code")
    test.equal(blocks[2].lines[1], "local x = 1")
    test.equal(blocks[2].lines[2], "print(x)")
  end)

  test.test("parses definition lists", function()
    local blocks = MarkdownView.parse_blocks([[
Term
: first line
  second line
]])

    test.equal(#blocks, 1)
    test.equal(blocks[1].type, "definition_list")
    test.equal(#blocks[1].items, 1)
    test.equal(blocks[1].items[1].term, "Term")
    test.equal(blocks[1].items[1].definitions[1].blocks[1].type, "paragraph")
    test.equal(blocks[1].items[1].definitions[1].blocks[1].text, "first line second line")
  end)

  test.test("parses nested blockquotes", function()
    local blocks = MarkdownView.parse_blocks([[
> Parent
> > Child
]])

    test.equal(#blocks, 1)
    test.equal(blocks[1].type, "quote")
    test.equal(blocks[1].blocks[1].type, "paragraph")
    test.equal(blocks[1].blocks[1].text, "Parent")
    test.equal(blocks[1].blocks[2].type, "quote")
    test.equal(blocks[1].blocks[2].blocks[1].text, "Child")
  end)

  test.test("parses setext headings", function()
    local blocks = MarkdownView.parse_blocks([[
Heading One
===================

Heading Two
-------------
]])

    test.equal(#blocks, 2)
    test.equal(blocks[1].type, "heading")
    test.equal(blocks[1].level, 1)
    test.equal(blocks[1].text, "Heading One")
    test.equal(blocks[2].type, "heading")
    test.equal(blocks[2].level, 2)
    test.equal(blocks[2].text, "Heading Two")
  end)

  test.test("skips html comments", function()
    local blocks = MarkdownView.parse_blocks([[
<!--                DO NOT EDIT THIS FILE MANUALLY                -->
# Heading
<!--
multi-line
comment
-->
Paragraph text.
]])

    test.equal(#blocks, 2)
    test.equal(blocks[1].type, "heading")
    test.equal(blocks[1].text, "Heading")
    test.equal(blocks[2].type, "paragraph")
    test.equal(blocks[2].text, "Paragraph text.")
  end)

  test.test("renders layout and restores file-backed state", function(context)
    local path = context.temp_root .. PATHSEP .. "sample.md"
    write_file(path, "# Title\n\nParagraph with `inline code`.\n")

    local view = MarkdownView(path)
    view.size.x = 420
    view.size.y = 240

    test.equal(view:get_name(), "sample.md Preview")
    test.ok(view:get_scrollable_size() > 0)
    test.ok(view:get_h_scrollable_size() > 0)

    local state = view:get_state()
    test.not_nil(state)
    test.equal(state.path, path)

    local restored = MarkdownView.from_state(state)
    test.not_nil(restored)
    restored.size.x = 420
    restored.size.y = 240
    test.equal(restored:get_name(), "sample.md Preview")
    test.ok(restored:get_scrollable_size() > 0)
  end)

  test.test("syntax-colors fenced code blocks", function()
    local view = MarkdownView([[
```lua
local lua_var = 1
```
]])
    view.size.x = 420
    view.size.y = 240

    local layout = view:ensure_layout()
    local code_line
    for _, command in ipairs(layout.commands) do
      if command.type == "text" and command.tabbed then
        code_line = command
        break
      end
    end

    test.not_nil(code_line)
    local colors_by_text = {}
    for _, fragment in ipairs(code_line.fragments) do
      local text = fragment.text:match("^%s*(.-)%s*$")
      if text ~= "" then
        colors_by_text[text] = fragment.color
      end
    end

    test.equal(MarkdownView.resolve_color(colors_by_text["local"]), style.syntax["keyword"])
    test.equal(MarkdownView.resolve_color(colors_by_text["lua_var"]), style.syntax["normal"])
    test.equal(MarkdownView.resolve_color(colors_by_text["="]), style.syntax["operator"])
    test.equal(MarkdownView.resolve_color(colors_by_text["1"]), style.syntax["number"])
  end)

  test.test("uses a fixed font object for all markdown font roles when configured", function()
    local fixed_font = style.code_font:copy(12 * SCALE)
    local view = MarkdownView({
      text = [[
# Heading

Paragraph with `inline`.

```lua
local lua_var = 1
```
]],
      font = fixed_font
    })
    view.size.x = 420
    view.size.y = 240

    local fonts = view:get_font_cache()

    test.equal(fonts.body.normal, fixed_font)
    test.equal(fonts.body.bold, fixed_font)
    test.equal(fonts.body.italic, fixed_font)
    test.equal(fonts.body.strikethrough, fixed_font)
    test.equal(fonts.body.code, fixed_font)
    test.equal(fonts.code, fixed_font)
    test.equal(fonts.heading[1].normal, fixed_font)
    test.equal(fonts.heading[1].bold, fixed_font)

    for _, command in ipairs(view:ensure_layout().commands) do
      if command.type == "text" then
        for _, fragment in ipairs(command.fragments) do
          if fragment.font then
            test.equal(fragment.font, fixed_font)
          end
        end
      end
    end

    local default_view = MarkdownView("# Heading\n\nParagraph")
    test.ok(
      default_view:get_font_cache().heading[1].normal:get_size()
      > default_view:get_font_cache().body.normal:get_size()
    )
  end)

  test.test("uses updated style colors without rebuilding layout", function()
    local view = MarkdownView("plain `code` [link](https://example.com)")
    view.size.x = 420
    view.size.y = 240
    view.position.x = 0
    view.position.y = 0
    view:ensure_layout()

    local original_text = style.text
    local original_background2 = style.background2
    local original_link = style.syntax["function"]
    local new_text = { 10, 20, 30, 255 }
    local new_background2 = { 40, 50, 60, 255 }
    local new_link = { 70, 80, 90, 255 }
    local captured_text_colors = {}
    local captured_rect_colors = {}
    local original_draw_text = renderer.draw_text
    local original_draw_rect = renderer.draw_rect
    local original_push_clip_rect = core.push_clip_rect
    local original_pop_clip_rect = core.pop_clip_rect

    style.text = new_text
    style.background2 = new_background2
    style.syntax["function"] = new_link
    view.draw_background = function() end
    view.draw_scrollbar = function() end
    core.push_clip_rect = function() end
    core.pop_clip_rect = function() end
    renderer.draw_rect = function(_, _, _, _, color)
      captured_rect_colors[#captured_rect_colors + 1] = color
    end
    renderer.draw_text = function(font, text, x, y, color, opts)
      captured_text_colors[text] = color
      return x + font:get_width(text, opts)
    end

    view:draw()

    renderer.draw_text = original_draw_text
    renderer.draw_rect = original_draw_rect
    core.push_clip_rect = original_push_clip_rect
    core.pop_clip_rect = original_pop_clip_rect
    style.text = original_text
    style.background2 = original_background2
    style.syntax["function"] = original_link

    test.equal(captured_text_colors["plain"], new_text)
    test.equal(captured_text_colors["code"], new_text)
    test.equal(captured_text_colors["link"], new_link)
    test.ok(#captured_rect_colors > 0)
    test.equal(captured_rect_colors[1], new_background2)
  end)

  test.test("renders strikethrough text", function()
    local view = MarkdownView("~~gone~~ and ~~[linked](https://example.com)~~")
    view.size.x = 420
    view.size.y = 240

    local layout = view:ensure_layout()
    local plain_fragment
    local linked_fragment
    for _, command in ipairs(layout.commands) do
      if command.type == "text" then
        for _, fragment in ipairs(command.fragments) do
          if fragment.text == "gone" then
            plain_fragment = fragment
          elseif fragment.url == "https://example.com" then
            linked_fragment = fragment
          end
        end
      end
    end

    test.not_nil(plain_fragment)
    test.not_nil(linked_fragment)
    test.equal(plain_fragment.font, view:get_font_cache().body.strikethrough)
    test.equal(linked_fragment.font, view:get_font_cache().body.strikethrough)
  end)

  test.test("treats single tilde as plain text", function()
    local view = MarkdownView("single ~ tilde")
    view.size.x = 420
    view.size.y = 240

    local layout = view:ensure_layout()
    local found_tilde
    for _, command in ipairs(layout.commands) do
      if command.type == "text" then
        for _, fragment in ipairs(command.fragments) do
          if fragment.text:find("~", 1, true) then
            found_tilde = true
          end
        end
      end
    end

    test.ok(found_tilde)
  end)

  test.test("treats lone exclamation as plain text", function()
    local view = MarkdownView("Install and profit!")
    view.size.x = 420
    view.size.y = 240

    local layout = view:ensure_layout()
    local found_exclamation
    for _, command in ipairs(layout.commands) do
      if command.type == "text" then
        for _, fragment in ipairs(command.fragments) do
          if fragment.text:find("!", 1, true) then
            found_exclamation = true
          end
        end
      end
    end

    test.ok(found_exclamation)
  end)

  test.test("treats trailing backslash as plain text", function()
    local view = MarkdownView("ends with slash\\")
    view.size.x = 420
    view.size.y = 240

    local layout = view:ensure_layout()
    local found_backslash
    for _, command in ipairs(layout.commands) do
      if command.type == "text" then
        for _, fragment in ipairs(command.fragments) do
          if fragment.text:find("\\", 1, true) then
            found_backslash = true
          end
        end
      end
    end

    test.ok(found_backslash)
  end)

  test.test("parses markdown tables", function()
    local blocks = MarkdownView.parse_blocks([[
| Plugin | Description |
| --- | --- |
| [`ppm`](plugins/ppm.lua?raw=1) | Plugin manager. |
| [`linter`](plugins/linter.lua?raw=1) | Reports diagnostics in the editor. |
]])

    test.equal(#blocks, 1)
    test.equal(blocks[1].type, "table")
    test.equal(#blocks[1].headers, 2)
    test.equal(#blocks[1].rows, 2)
    test.equal(blocks[1].headers[1].text, "Plugin")
    test.equal(blocks[1].rows[1][1].text, "[`ppm`](plugins/ppm.lua?raw=1)")
  end)

  test.test("renders markdown tables with cell links", function()
    local view = MarkdownView([[
| Plugin | Description |
| --- | --- |
| [`ppm`](plugins/ppm.lua?raw=1) | Plugin manager with [docs](https://example.com/docs). |
| [`linter`](plugins/linter.lua?raw=1) | Reports diagnostics in the editor. |
]])
    view.size.x = 640
    view.size.y = 240

    local layout = view:ensure_layout()
    local urls = {}
    for _, command in ipairs(layout.commands) do
      if command.links then
        for _, link in ipairs(command.links) do
          urls[#urls + 1] = link.url
        end
      end
    end

    test.same(urls, {
      "plugins/ppm.lua?raw=1",
      "https://example.com/docs",
      "plugins/linter.lua?raw=1"
    })
    test.ok(layout.content_width > 0)
    test.ok(view:get_scrollable_size() > 0)
  end)

  test.test("renders task list markers as checkboxes", function()
    local view = MarkdownView([[
- [ ] Open task
- [x] Done task
]])
    view.size.x = 420
    view.size.y = 240

    local layout = view:ensure_layout()
    local markers = {}
    for _, command in ipairs(layout.commands) do
      if command.type == "checkbox" then
        markers[#markers + 1] = {
          checked = command.checked,
          width = command.width,
          height = command.height
        }
      end
    end

    test.equal(#markers, 2)
    test.equal(markers[1].checked, false)
    test.equal(markers[2].checked, true)
    test.equal(markers[1].width, markers[2].width)
    test.equal(markers[1].height, markers[2].height)
  end)

  test.test("renders nested list items with increasing indent", function()
    local view = MarkdownView([[
- [ ] Parent
  - [x] Child
    - [ ] Grandchild
]])
    view.size.x = 420
    view.size.y = 240

    local layout = view:ensure_layout()
    local xs = {}
    for _, command in ipairs(layout.commands) do
      if command.type == "checkbox" then
        xs[#xs + 1] = command.x
      end
    end

    table.sort(xs)
    test.equal(#xs, 3)
    test.ok(xs[2] > xs[1])
    test.ok(xs[3] > xs[2])
  end)

  test.test("renders nested bullets instead of indented code for marker-aligned children", function()
    local view = MarkdownView([[
*   Parent

    *   Linux path
    *   Windows path
]])
    view.size.x = 420
    view.size.y = 240

    local bullets = {}
    local code_lines = 0
    for _, command in ipairs(view:ensure_layout().commands) do
      if command.type == "text" and command.fragments[1] then
        if command.fragments[1].text == "\226\128\162" then
          bullets[#bullets + 1] = command.x
        end
        if command.tabbed then
          code_lines = code_lines + 1
        end
      end
    end

    table.sort(bullets)
    test.equal(#bullets, 3)
    test.ok(bullets[2] > bullets[1])
    test.equal(code_lines, 0)
  end)

  test.test("renders hard line breaks as separate lines", function()
    local view = MarkdownView([[
First line  
Second line
]])
    view.size.x = 420
    view.size.y = 240

    local layout = view:ensure_layout()
    local text_commands = {}
    for _, command in ipairs(layout.commands) do
      if command.type == "text" then
        text_commands[#text_commands + 1] = command
      end
    end

    test.ok(#text_commands >= 2)
    test.ok(text_commands[2].y > text_commands[1].y)
  end)

  test.test("renders inline images inside paragraphs", function(context)
    local image_path = context.project_temp_root .. PATHSEP .. "icon.png"
    local source_path = context.project_temp_root .. PATHSEP .. "inline-image.md"
    write_file(image_path, "not-a-real-png")
    write_file(source_path, "Start ![Icon](icon.png) end\n")

    local original_load_image = canvas.load_image
    local loaded_path
    canvas.load_image = function(path)
      loaded_path = path
      return {
        get_size = function()
          return 64, 32
        end,
        scaled = function(_, width, height)
          return {
            get_size = function()
              return width, height
            end
          }
        end
      }
    end

    local view = MarkdownView(source_path)
    view.size.x = 420
    view.size.y = 240
    local layout = view:ensure_layout()
    canvas.load_image = original_load_image

    local inline_image
    for _, command in ipairs(layout.commands) do
      if command.type == "text" then
        for _, fragment in ipairs(command.fragments) do
          if fragment.type == "image" then
            inline_image = fragment
          end
        end
      end
    end

    test.equal(loaded_path, image_path)
    test.not_nil(inline_image)
    test.ok(inline_image.width > 0)
    test.ok(inline_image.height > 0)
  end)

  test.test("supports multi-backtick code spans and link titles", function()
    local view = MarkdownView("``code ` span`` and [link](https://example.com/a_(b) \"Title\")")
    view.size.x = 420
    view.size.y = 240

    local layout = view:ensure_layout()
    local code_texts = {}
    local link_fragment
    for _, command in ipairs(layout.commands) do
      if command.type == "text" then
        for _, fragment in ipairs(command.fragments) do
          if fragment.font == view:get_font_cache().body.code then
            code_texts[#code_texts + 1] = fragment.text
          elseif fragment.url == "https://example.com/a_(b)" then
            link_fragment = fragment
          end
        end
      end
    end

    test.same(code_texts, { "code ` span" })
    test.not_nil(link_fragment)
  end)

  test.test("keeps inline code spans as a single wrapped fragment", function()
    local view = MarkdownView('* 32 bit: `cmake -G "Visual Studio 12 2013" -DCMAKE_BUILD_TYPE=Release ..`')
    view.size.x = 420
    view.size.y = 240

    local code_fragments = {}
    for _, command in ipairs(view:ensure_layout().commands) do
      if command.type == "text" then
        for _, fragment in ipairs(command.fragments) do
          if fragment.font == view:get_font_cache().body.code then
            code_fragments[#code_fragments + 1] = fragment.text
          end
        end
      end
    end

    test.same(code_fragments, {
      'cmake -G "Visual Studio 12 2013" -DCMAKE_BUILD_TYPE=Release ..'
    })
  end)

  test.test("resolves inline links split across soft line breaks", function()
    local view = MarkdownView([[
- the [Mbed TLS mailing-list
  archives](https://lists.trustedfirmware.org/archives/list/mbed-tls@lists.trustedfirmware.org/).
]])
    view.size.x = 640
    view.size.y = 240

    local layout = view:ensure_layout()
    local found
    for _, command in ipairs(layout.commands) do
      if command.links then
        for _, link in ipairs(command.links) do
          if link.url == "https://lists.trustedfirmware.org/archives/list/mbed-tls@lists.trustedfirmware.org/" then
            found = true
          end
        end
      end
    end

    test.ok(found)
  end)

  test.test("resolves bare URLs after intraword underscores", function()
    local view = MarkdownView("The API can be found in SDL_net.h and online at https://wiki.libsdl.org/SDL3_net")
    view.size.x = 640
    view.size.y = 240

    local layout = view:ensure_layout()
    local found
    local saw_filename
    for _, command in ipairs(layout.commands) do
      if command.type == "text" then
        for _, fragment in ipairs(command.fragments) do
          if fragment.text:find("SDL_net%.h") then
            saw_filename = true
          end
        end
      end
      if command.links then
        for _, link in ipairs(command.links) do
          if link.url == "https://wiki.libsdl.org/SDL3_net" then
            found = true
          end
        end
      end
    end

    test.ok(saw_filename)
    test.ok(found)
  end)

  test.test("renders table alignment markers", function()
    local view = MarkdownView([[
| Left | Right |
| :--- | ---: |
| a | b |
]])
    view.size.x = 420
    view.size.y = 240

    local layout = view:ensure_layout()
    local positions = {}
    for _, command in ipairs(layout.commands) do
      if command.type == "text" then
        local text = command.fragments[1] and command.fragments[1].text
        if text == "a" or text == "b" then
          positions[text] = command.x
        end
      end
    end

    test.not_nil(positions["a"])
    test.not_nil(positions["b"])
    test.ok(positions["b"] > positions["a"])
  end)

  test.test("renders footnote references and anchors", function()
    local view = MarkdownView([[
Text with a footnote.[^note]

[^note]: Footnote body
]])
    view.size.x = 420
    view.size.y = 240

    local layout = view:ensure_layout()
    local found_ref
    for _, command in ipairs(layout.commands) do
      if command.links then
        for _, link in ipairs(command.links) do
          if link.url == "#footnote-note" then
            found_ref = link
          end
        end
      end
    end

    test.not_nil(found_ref)
    test.not_nil(layout.anchors["footnote-note"])
    view:open_link("#footnote-note")
    test.equal(view.scroll.to.y, layout.anchors["footnote-note"])
  end)

  test.test("renders images inside markdown tables", function(context)
    local preview_dir = context.project_temp_root .. PATHSEP .. "previews"
    local source_path = context.project_temp_root .. PATHSEP .. "colors.md"
    local preview_path = preview_dir .. PATHSEP .. "abyss.svg"
    local ok, err = common.mkdirp(preview_dir)
    test.ok(ok, err)
    write_file(preview_path, "<svg></svg>")
    write_file(source_path, [[
| Theme | Preview |
| --- | --- |
| [abyss](colors/abyss.lua?raw=1) | ![abyss_preview](previews/abyss.svg) |
]])

    local original_load_image = canvas.load_image
    local loaded_path
    canvas.load_image = function(path)
      loaded_path = path
      return {
        get_size = function()
          return 96, 48
        end,
        scaled = function(_, width, height)
          return {
            get_size = function()
              return width, height
            end
          }
        end
      }
    end

    local view = MarkdownView(source_path)
    view.size.x = 640
    view.size.y = 240

    local layout = view:ensure_layout()
    canvas.load_image = original_load_image

    local image_command
    for _, command in ipairs(layout.commands) do
      if command.type == "image" then
        image_command = command
        break
      end
    end

    test.equal(loaded_path, preview_path)
    test.not_nil(image_command)
    test.equal(image_command.width, 96)
    test.equal(image_command.height, 48)
  end)

  test.test("renders project-local markdown images", function(context)
    local image_path = context.project_temp_root .. PATHSEP .. "diagram.png"
    local source_path = context.project_temp_root .. PATHSEP .. "source.md"
    write_file(image_path, "not-a-real-png")
    write_file(source_path, "![Diagram](diagram.png)\n")

    local original_load_image = canvas.load_image
    local loaded_path
    canvas.load_image = function(path)
      loaded_path = path
      return {
        get_size = function()
          return 800, 400
        end,
        scaled = function(_, width, height)
          return {
            get_size = function()
              return width, height
            end
          }
        end
      }
    end

    local view = MarkdownView(source_path)
    view.size.x = 420
    view.size.y = 240

    local layout = view:ensure_layout()
    canvas.load_image = original_load_image

    test.equal(loaded_path, image_path)
    test.equal(layout.commands[1].type, "image")
    test.equal(layout.commands[1].x, 0)
    test.equal(layout.commands[1].width, layout.width)
    test.equal(layout.commands[1].height, math.floor(400 * (layout.width / 800)))
    test.equal(layout.commands[1].image_url, "diagram.png")
  end)

  test.test("downloads remote markdown images to the cache", function()
    local original_download = http.download
    local original_load_image = canvas.load_image
    local download_opts
    local loaded_path

    http.download = function(url, options)
      download_opts = {
        url = url,
        directory = options.directory,
        filename = options.filename
      }
      if not system.get_file_info(options.directory) then
        local ok, err = common.mkdirp(options.directory)
        test.ok(ok, err)
      end
      local path = options.directory .. PATHSEP .. options.filename
      write_file(path, "downloaded-image")
      options.on_done(true, nil, path, {
        status = 200,
        headers = {},
        url = url
      })
    end

    canvas.load_image = function(path)
      loaded_path = path
      return {
        get_size = function()
          return 320, 160
        end,
        scaled = function(_, width, height)
          return {
            get_size = function()
              return width, height
            end
          }
        end
      }
    end

    local view = MarkdownView("![Remote](https://example.com/assets/diagram.png)")
    view.size.x = 420
    view.size.y = 240

    local layout = view:ensure_layout()

    http.download = original_download
    canvas.load_image = original_load_image

    test.not_nil(download_opts)
    test.equal(download_opts.url, "https://example.com/assets/diagram.png")
    test.equal(download_opts.directory, USERDIR .. PATHSEP .. "cache")
    test.equal(loaded_path, download_opts.directory .. PATHSEP .. download_opts.filename)
    test.equal(layout.commands[1].type, "image")

    if loaded_path and system.get_file_info(loaded_path) then
      local ok, err = common.rm(loaded_path)
      test.ok(ok, err)
    end
  end)

  test.test("renders linked image reference rows and opens their target link", function()
    local original_download = http.download
    local original_load_image = canvas.load_image
    local download_opts = {}
    local opened

    http.download = function(url, options)
      download_opts[#download_opts + 1] = {
        url = url,
        directory = options.directory,
        filename = options.filename
      }
      if not system.get_file_info(options.directory) then
        local ok, err = common.mkdirp(options.directory)
        test.ok(ok, err)
      end
      local path = options.directory .. PATHSEP .. options.filename
      write_file(path, "downloaded-image")
      options.on_done(true, nil, path, {
        status = 200,
        headers = {},
        url = url
      })
    end

    canvas.load_image = function()
      return {
        get_size = function()
          return 140, 40
        end,
        scaled = function(_, width, height)
          return {
            get_size = function()
              return width, height
            end
          }
        end
      }
    end

    local view = MarkdownView([=[
[![Build Rolling]](https://github.com/pragtical/pragtical/actions/workflows/rolling.yml)
[![Discord]](https://discord.gg/8V2yJtn3Fc)

[Build Rolling]: https://github.com/pragtical/pragtical/actions/workflows/rolling.yml/badge.svg
[Discord]: https://discord.com/api/guilds/1285023036071743542/widget.png?style=shield
]=])
    view.size.x = 420
    view.size.y = 240

    local layout = view:ensure_layout()
    local first_image = layout.commands[1]
    local second_image = layout.commands[2]
    test.equal(first_image.type, "image")
    test.equal(second_image.type, "image")
    test.equal(first_image.x, 0)
    test.ok(first_image.y > 0)
    test.ok(second_image.x > first_image.x)
    test.equal(second_image.y, first_image.y)
    test.equal(first_image.link_url, "https://github.com/pragtical/pragtical/actions/workflows/rolling.yml")
    test.equal(second_image.link_url, "https://discord.gg/8V2yJtn3Fc")
    test.equal(first_image.image_url, "https://github.com/pragtical/pragtical/actions/workflows/rolling.yml/badge.svg")
    test.equal(second_image.image_url, "https://discord.com/api/guilds/1285023036071743542/widget.png?style=shield")
    test.equal(#download_opts, 2)
    test.equal(download_opts[1].url, "https://github.com/pragtical/pragtical/actions/workflows/rolling.yml/badge.svg")
    test.equal(download_opts[2].url, "https://discord.com/api/guilds/1285023036071743542/widget.png?style=shield")

    local original_open_in_system = common.open_in_system
    common.open_in_system = function(url)
      opened = url
      return true
    end

    local x = view.position.x + style.padding.x + second_image.x + 1
    local y = view.position.y + style.padding.y + second_image.y + 1
    local target = view:get_context_target_at(x, y)
    test.equal(target.link_url, "https://discord.gg/8V2yJtn3Fc")
    test.equal(target.image_url, "https://discord.com/api/guilds/1285023036071743542/widget.png?style=shield")
    view.markdown_context_target = target
    core.set_active_view(view)
    system.set_clipboard("")
    test.equal(command.perform("markdown-view:copy-link"), true)
    test.equal(system.get_clipboard(), target.link_url)
    system.set_clipboard("")
    test.equal(command.perform("markdown-view:copy-image-link"), true)
    test.equal(system.get_clipboard(), target.image_url)

    view:on_mouse_moved(x, y, 0, 0)
    test.equal(view.cursor, "hand")
    view:on_mouse_pressed("left", x, y, 1)

    common.open_in_system = original_open_in_system
    http.download = original_download
    canvas.load_image = original_load_image

    test.equal(opened, "https://discord.gg/8V2yJtn3Fc")

    for _, item in ipairs(download_opts) do
      local cache_path = item.directory .. PATHSEP .. item.filename
      if system.get_file_info(cache_path) then
        local ok, err = common.rm(cache_path)
        test.ok(ok, err)
      end
    end
  end)

  test.test("resolves inline and reference links", function()
    local view = MarkdownView([[
[inline](https://example.com) and [docs][ref]
For more detailed instructions visit: https://pragtical.dev/docs/setup/building

[ref]: https://example.org
]])
    view.size.x = 420
    view.size.y = 240

    local layout = view:ensure_layout()
    local urls = {}
    for _, command in ipairs(layout.commands) do
      if command.links then
        for _, link in ipairs(command.links) do
          urls[#urls + 1] = link.url
        end
      end
    end

    test.same(urls, {
      "https://example.com",
      "https://example.org",
      "https://pragtical.dev/docs/setup/building"
    })

    local first_link_fragment
    for _, command in ipairs(layout.commands) do
      if command.type == "text" then
        for _, fragment in ipairs(command.fragments) do
          if fragment.url == "https://example.com" then
            first_link_fragment = fragment
            break
          end
        end
      end
    end

    test.not_nil(first_link_fragment)
    test.equal(MarkdownView.resolve_color(first_link_fragment.color), style.syntax["function"])
  end)

  test.test("resolves bold reference links", function()
    local view = MarkdownView([[
**[Get Pragtical]**

[Get Pragtical]: https://github.com/pragtical/pragtical/releases
]])
    view.size.x = 420
    view.size.y = 240

    local layout = view:ensure_layout()
    local target
    for _, command in ipairs(layout.commands) do
      if command.links and command.links[1] then
        target = command.links[1]
        break
      end
    end

    test.not_nil(target)
    test.equal(target.url, "https://github.com/pragtical/pragtical/releases")

    local link_fragment
    for _, command in ipairs(layout.commands) do
      if command.type == "text" then
        for _, fragment in ipairs(command.fragments) do
          if fragment.url == target.url then
            link_fragment = fragment
            break
          end
        end
      end
    end

    test.not_nil(link_fragment)
    test.equal(link_fragment.font, view:get_font_cache().body.bold)
  end)

  test.test("opens clicked links in the system browser", function()
    local view = MarkdownView("[inline](https://example.com)")
    view.size.x = 420
    view.size.y = 240

    local layout = view:ensure_layout()
    local target
    for _, command in ipairs(layout.commands) do
      if command.links and command.links[1] then
        target = command.links[1]
        break
      end
    end

    test.not_nil(target)

    local opened
    local original = common.open_in_system
    local original_show_tooltip = core.status_view.show_tooltip
    local original_remove_tooltip = core.status_view.remove_tooltip
    local tooltip
    local tooltip_removed = 0
    common.open_in_system = function(url)
      opened = url
      return true
    end
    core.status_view.show_tooltip = function(_, text)
      tooltip = text
    end
    core.status_view.remove_tooltip = function()
      tooltip_removed = tooltip_removed + 1
      tooltip = nil
    end

    local x = view.position.x + style.padding.x + target.x + 1
    local y = view.position.y + style.padding.y + target.y + 1
    local context_target = view:get_context_target_at(x, y)
    test.equal(context_target.link_url, "https://example.com")
    test.equal(context_target.image_url, nil)
    view.markdown_context_target = context_target
    core.set_active_view(view)
    system.set_clipboard("")
    test.equal(command.perform("markdown-view:copy-link"), true)
    test.equal(system.get_clipboard(), "https://example.com")

    view:on_mouse_moved(x, y, 0, 0)
    test.equal(view.cursor, "hand")
    test.equal(tooltip, "Open https://example.com")
    view:on_mouse_pressed("left", x, y, 1)
    test.equal(opened, "https://example.com")
    view:on_mouse_left()
    test.equal(tooltip_removed, 1)

    common.open_in_system = original
    core.status_view.show_tooltip = original_show_tooltip
    core.status_view.remove_tooltip = original_remove_tooltip
  end)

  test.test("opens project markdown links in a new preview", function(context)
    local target_path = context.project_temp_root .. PATHSEP .. "target.md"
    local source_path = context.project_temp_root .. PATHSEP .. "source.md"
    write_file(target_path, "# Target\n")
    write_file(source_path, "[Preview][doc]\n\n[doc]: target.md\n")

    local view = MarkdownView(source_path)
    view.size.x = 420
    view.size.y = 240

    local layout = view:ensure_layout()
    local target = layout.commands[1].links[1]
    test.not_nil(target)

    local opened_markdown
    local opened_file
    local opened_external
    local original_open_markdown = core.open_markdown
    local original_open_file = core.open_file
    local original_open_in_system = common.open_in_system

    core.open_markdown = function(path)
      opened_markdown = path
    end
    core.open_file = function(path)
      opened_file = path
    end
    common.open_in_system = function(url)
      opened_external = url
    end

    local x = view.position.x + style.padding.x + target.x + 1
    local y = view.position.y + style.padding.y + target.y + 1
    view:on_mouse_pressed("left", x, y, 1)

    core.open_markdown = original_open_markdown
    core.open_file = original_open_file
    common.open_in_system = original_open_in_system

    test.equal(opened_markdown, target_path)
    test.is_nil(opened_file)
    test.is_nil(opened_external)
  end)

  test.test("opens project file links in the editor", function(context)
    local target_path = context.project_temp_root .. PATHSEP .. "notes.txt"
    local source_path = context.project_temp_root .. PATHSEP .. "source.md"
    write_file(target_path, "notes\n")
    write_file(source_path, "[Notes](notes.txt)\n")

    local view = MarkdownView(source_path)
    view.size.x = 420
    view.size.y = 240

    local layout = view:ensure_layout()
    local target = layout.commands[1].links[1]
    test.not_nil(target)

    local opened_markdown
    local opened_file
    local opened_external
    local original_open_markdown = core.open_markdown
    local original_open_file = core.open_file
    local original_open_in_system = common.open_in_system

    core.open_markdown = function(path)
      opened_markdown = path
    end
    core.open_file = function(path)
      opened_file = path
    end
    common.open_in_system = function(url)
      opened_external = url
    end

    local x = view.position.x + style.padding.x + target.x + 1
    local y = view.position.y + style.padding.y + target.y + 1
    view:on_mouse_pressed("left", x, y, 1)

    core.open_markdown = original_open_markdown
    core.open_file = original_open_file
    common.open_in_system = original_open_in_system

    test.equal(opened_file, target_path)
    test.is_nil(opened_markdown)
    test.is_nil(opened_external)
  end)

  test.test("opens markdown files as text docs", function(context)
    local path = context.temp_root .. PATHSEP .. "opened.md"
    write_file(path, "# Opened\n\nFrom core.open_file.\n")

    local node = core.root_view:get_active_node_default()
    local view = core.open_file(path)
    test.ok(view:extends(DocView))
    node:close_view(core.root_view.root_node, view)
  end)

  test.test("previews the active markdown doc", function(context)
    local path = context.temp_root .. PATHSEP .. "preview.md"
    write_file(path, "# Preview\n\nInitial text.\n")

    local doc_view = core.open_file(path)
    test.ok(doc_view:extends(DocView))
    test.ok(command.is_valid("markdown-view:preview"))

    doc_view.doc:insert(3, 1, "Unsaved change.\n")
    command.perform("markdown-view:preview")

    local preview
    for _, view in ipairs(core.root_view.root_node:get_children()) do
      if view:extends(MarkdownView) and view.linked_doc == doc_view.doc then
        preview = view
        break
      end
    end

    test.not_nil(preview)
    test.equal(preview:get_name(), "preview.md Preview")
    preview:update()
    test.match(preview.text, "Unsaved change")

    local preview_node = core.root_view.root_node:get_node_for_view(preview)
    local doc_node = core.root_view.root_node:get_node_for_view(doc_view)
    preview_node:close_view(core.root_view.root_node, preview)
    doc_node:close_view(core.root_view.root_node, doc_view)
  end)

  test.test("places markdown previews according to config.markdown_preview_mode", function(context)
    local path = context.temp_root .. PATHSEP .. "preview-placement.md"
    write_file(path, "# Preview\n")

    local original_mode = config.markdown_preview_mode
    local modes = {
      right = "right",
      left = "left",
      top = "up",
      bottom = "down",
      newtab = "newtab"
    }

    for mode, direction in pairs(modes) do
      config.markdown_preview_mode = mode
      local doc_view = core.open_file(path)
      local doc_node = core.root_view.root_node:get_node_for_view(doc_view)

      command.perform("markdown-view:preview")

      local preview
      for _, view in ipairs(core.root_view.root_node:get_children()) do
        if view:extends(MarkdownView) and view.linked_doc == doc_view.doc then
          preview = view
          break
        end
      end

      test.not_nil(preview, mode)
      local preview_node = core.root_view.root_node:get_node_for_view(preview)
      if direction == "newtab" then
        test.equal(preview_node, doc_node)
      else
        local parent = preview_node:get_parent_node(core.root_view.root_node)
        test.not_nil(parent, mode)
        local split_type = (direction == "left" or direction == "right") and "hsplit" or "vsplit"
        local split_child = (direction == "left" or direction == "up") and parent.a or parent.b
        test.equal(parent.type, split_type)
        test.equal(split_child, preview_node)
      end

      preview_node:close_view(core.root_view.root_node, preview)
      doc_node = core.root_view.root_node:get_node_for_view(doc_view)
      doc_node:close_view(core.root_view.root_node, doc_view)
    end

    config.markdown_preview_mode = original_mode
  end)

  test.test("view raw opens the markdown doc and links standalone previews", function(context)
    local path = context.temp_root .. PATHSEP .. "raw-link.md"
    write_file(path, "# Preview\n\nInitial text.\n")

    local preview = core.open_markdown(path)
    test.not_nil(preview)
    test.is_nil(preview.linked_doc)

    local preview_node = core.root_view.root_node:get_node_for_view(preview)
    preview_node:set_active_view(preview)

    test.ok(command.is_valid("markdown-view:view-raw"))
    command.perform("markdown-view:view-raw")

    local raw_view = core.root_view.root_node:get_node_for_view(core.active_view).active_view
    test.ok(raw_view:extends(DocView))
    test.equal(common.normalize_path(raw_view.doc.abs_filename), common.normalize_path(path))
    test.equal(common.normalize_path(preview.linked_doc.abs_filename), common.normalize_path(path))

    raw_view.doc:insert(3, 1, "Linked text.\n")
    preview:update()
    test.match(preview.text, "Linked text")
  end)

  test.test("view raw focuses an already open markdown doc", function(context)
    local path = context.temp_root .. PATHSEP .. "raw-existing.md"
    write_file(path, "# Preview\n\nInitial text.\n")

    local raw_view = core.open_file(path)
    test.ok(raw_view:extends(DocView))
    local doc_node = core.root_view.root_node:get_node_for_view(raw_view)
    local preview = doc_node:split("right", MarkdownView(path)).active_view
    test.ok(preview:extends(MarkdownView))
    test.is_nil(preview.linked_doc)

    local preview_node = core.root_view.root_node:get_node_for_view(preview)
    preview_node:set_active_view(preview)
    command.perform("markdown-view:view-raw")

    test.ok(core.active_view:extends(DocView))
    test.equal(core.active_view.doc, raw_view.doc)
    test.equal(preview.linked_doc, core.active_view.doc)
  end)

  test.test("view raw re-establishes the preview doc link", function(context)
    local path = context.temp_root .. PATHSEP .. "raw-relink.md"
    write_file(path, "# Preview\n\nInitial text.\n")

    local raw_view = core.open_file(path)
    local original_doc = raw_view.doc
    local doc_node = core.root_view.root_node:get_node_for_view(raw_view)
    local preview = doc_node:split("right", MarkdownView({
      linked_doc = raw_view.doc,
      path = path,
      title = raw_view.doc:get_name()
    })).active_view
    local preview_node = core.root_view.root_node:get_node_for_view(preview)

    preview_node:set_active_view(preview)
    core.root_view.root_node:get_node_for_view(raw_view):close_view(core.root_view.root_node, raw_view)

    command.perform("markdown-view:view-raw")

    test.ok(core.active_view:extends(DocView))
    test.equal(common.normalize_path(preview.linked_doc.abs_filename), common.normalize_path(path))
    test.equal(common.normalize_path(core.active_view.doc.abs_filename), common.normalize_path(path))
  end)

  test.test("view raw is invalid for markdown previews without a path", function()
    local preview = MarkdownView("# Preview\n\nText only.\n")
    local node = core.root_view:get_active_node_default()
    node:add_view(preview)

    test.equal(core.active_view, preview)
    test.not_ok(command.is_valid("markdown-view:view-raw"))

    core.root_view.root_node:get_node_for_view(preview):close_view(core.root_view.root_node, preview)
  end)

  test.test("view raw places doc views according to config.markdown_preview_mode", function(context)
    local path = context.temp_root .. PATHSEP .. "raw-placement.md"
    write_file(path, "# Preview\n")

    local original_mode = config.markdown_preview_mode
    local modes = {
      right = "left",
      left = "right",
      top = "down",
      bottom = "up",
      newtab = "newtab"
    }

    for mode, direction in pairs(modes) do
      config.markdown_preview_mode = mode
      local node = core.root_view:get_active_node_default()
      local preview = MarkdownView(path)
      node:add_view(preview)
      node = core.root_view.root_node:get_node_for_view(preview)
      node:set_active_view(preview)

      command.perform("markdown-view:view-raw")

      local raw_view = core.active_view
      test.ok(raw_view:extends(DocView), mode)
      local raw_node = core.root_view.root_node:get_node_for_view(raw_view)
      if direction == "newtab" then
        test.equal(raw_node, node)
      else
        local parent = raw_node:get_parent_node(core.root_view.root_node)
        test.not_nil(parent, mode)
        local split_type = (direction == "left" or direction == "right") and "hsplit" or "vsplit"
        local split_child = (direction == "left" or direction == "up") and parent.a or parent.b
        test.equal(parent.type, split_type)
        test.equal(split_child, raw_node)
      end

      raw_node:close_view(core.root_view.root_node, raw_view)
      node = core.root_view.root_node:get_node_for_view(preview)
      node:close_view(core.root_view.root_node, preview)
    end

    config.markdown_preview_mode = original_mode
  end)
end)

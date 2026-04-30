local common = require "core.common"
local test = require "core.test"

local temp_root

local function assert_callable(value, name)
  local value_type = type(value)
  test.ok(value_type == "function" or value_type == "cdata",
    "missing or non-callable " .. name)
end

test.describe("system", function()
  test.before_each(function(context)
    temp_root = USERDIR
      .. PATHSEP .. "system-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    local ok, err = common.mkdirp(temp_root)
    test.ok(ok, err)
    context.temp_root = temp_root
  end)

  test.after_each(function(context)
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  test.test("exports the documented functions", function()
    for _, name in ipairs({
      "poll_event", "wait_event", "has_pending_events", "set_cursor",
      "get_scale", "set_window_title", "set_window_mode",
      "get_window_mode", "set_window_bordered", "set_window_hit_test",
      "get_window_size", "set_window_size", "window_has_focus",
      "text_input", "set_text_input_rect", "clear_ime", "raise_window",
      "show_fatal_error", "rmdir", "chdir", "getcwd", "ftruncate",
      "mkdir", "list_dir", "absolute_path", "get_file_info", "get_fs_type",
      "get_clipboard", "set_clipboard", "get_primary_selection",
      "set_primary_selection", "get_process_id", "get_time", "sleep",
      "exec", "fuzzy_match", "set_window_opacity", "load_native_plugin",
      "path_compare", "setenv", "get_display_info", "open_file_dialog",
      "open_directory_dialog", "save_file_dialog", "get_sandbox"
    }) do
      assert_callable(system[name], "system." .. name)
    end
  end)

  test.test("handles filesystem utilities", function(context)
    local cwd = system.getcwd()
    local absolute = system.absolute_path(context.temp_root)
    test.not_nil(absolute)

    local info = system.get_file_info(absolute)
    test.not_nil(info)
    test.equal(info.type, "dir")

    local nested = absolute .. PATHSEP .. "nested"
    local created, err = system.mkdir(nested)
    test.ok(created, err)

    local file = io.open(nested .. PATHSEP .. "sample.txt", "wb")
    test.not_nil(file)
    file:write("hello")
    file:close()

    local entries, list_err = system.list_dir(nested)
    test.not_nil(entries, list_err)
    test.contains(entries, "sample.txt")

    local removed, remove_err = os.remove(nested .. PATHSEP .. "sample.txt")
    test.ok(removed, remove_err)

    system.chdir(nested)
    test.equal(system.getcwd():gsub("[/\\]+$", ""), nested:gsub("[/\\]+$", ""))
    system.chdir(cwd)
    test.equal(system.getcwd():gsub("[/\\]+$", ""), cwd:gsub("[/\\]+$", ""))

    if PLATFORM == "Linux" then
      test.type(system.get_fs_type(nested), "string")
    end
  end)

  test.test("provides process, time and environment helpers", function()
    local pid = system.get_process_id()
    test.ok(pid > 0)

    local start_time = system.get_time()
    system.sleep(0.01)
    local end_time = system.get_time()
    test.ok(end_time >= start_time)

    local key = "PRAGTICAL_SYSTEM_TEST_ENV_" .. pid
    test.ok(system.setenv(key, "ok"))
    test.equal(os.getenv(key), "ok")

    local score = system.fuzzy_match("alphabet", "alphabet")
    test.type(score, "number")
    test.ok(score > 0)
    test.type(system.path_compare("a.lua", "file", "b.lua", "file"), "boolean")

    local current_scale, refresh_rate, width, height, default_scale =
      system.get_display_info()
    test.ok(current_scale > 0)
    test.ok(refresh_rate >= 0)
    test.ok(width > 0)
    test.ok(height > 0)
    test.ok(default_scale > 0)

    local sandbox = system.get_sandbox()
    test.ok(sandbox == "none"
      or sandbox == "unknown"
      or sandbox == "flatpak"
      or sandbox == "snap"
      or sandbox == "macos")
  end)

  test.test("supports basic window helpers on a temporary window", function()
    local window = renwindow.create("system-test-window", 96, 72)
    test.not_nil(window)

    test.no_error(function() system.set_cursor("arrow") end)
    test.type(system.has_pending_events(), "boolean")
    test.type(system.wait_event(0), "boolean")

    local width, height, x, y = system.get_window_size(window)
    test.ok(width > 0)
    test.ok(height > 0)
    test.type(x, "number")
    test.type(y, "number")

    test.no_error(function() system.set_window_title(window, "system-test-window-2") end)
    test.no_error(function() system.set_window_mode(window, "normal") end)
    test.equal(system.get_window_mode(window), "normal")
    test.no_error(function() system.set_window_bordered(window, true) end)
    test.no_error(function() system.set_window_hit_test(window) end)
    test.no_error(function() system.text_input(window, false) end)
    test.no_error(function() system.set_text_input_rect(window, 0, 0, 1, 1) end)
    test.no_error(function() system.clear_ime(window) end)
    test.no_error(function() system.raise_window(window) end)

    test.ok(system.get_scale(window) > 0)
    test.type(system.window_has_focus(window), "boolean")
    test.type(system.set_window_opacity(window, 1.0), "boolean")

    system.set_window_size(window, 80, 60, x, y)
    local resized_width, resized_height = renwindow.get_size(window)
    test.ok(resized_width > 0)
    test.ok(resized_height > 0)
  end)
end)

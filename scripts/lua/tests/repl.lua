local common = require "core.common"
local test = require "core.test"
local REPL = require "core.repl"
local native_repl = require "repl"

local temp_root

test.describe("repl", function()
  test.before_each(function(context)
    temp_root = USERDIR
      .. PATHSEP .. "repl-tests-"
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

  test.test("exports the documented native repl functions", function()
    for _, name in ipairs({
      "input", "add_history", "set_history_max_len", "save_history",
      "load_history", "clear_screen", "set_completion",
      "add_completion", "set_multiline", "print_keycodes"
    }) do
      test.type(native_repl[name], "function", "missing repl." .. name)
    end
  end)

  test.test("supports history and completion configuration", function(context)
    local history_file = context.temp_root .. PATHSEP .. "history.txt"

    native_repl.set_history_max_len(10)
    native_repl.add_history("print('hello')")
    native_repl.set_multiline(false)
    native_repl.set_completion(function(completion, line)
      native_repl.add_completion(completion, line .. "-done")
    end)
    native_repl.save_history(history_file)
    native_repl.load_history(history_file)

    local info = system.get_file_info(history_file)
    test.not_nil(info)
    test.equal(info.type, "file")

    local removed, remove_err = os.remove(history_file)
    test.ok(removed, remove_err)
  end)

  test.test("core repl registers commands and completions", function()
    local repl_instance = REPL()
    test.ok(#repl_instance.commands > 0)
    test.ok(#repl_instance.completions > 0)

    local ok, err = repl_instance:register_command {
      name = "sample",
      description = "sample",
      execute = function() end
    }
    test.ok(ok, err)

    local dup_ok, dup_err = repl_instance:register_command {
      name = "sample",
      description = "duplicate",
      execute = function() end
    }
    test["nil"](dup_ok)
    test.not_nil(dup_err)
  end)
end)

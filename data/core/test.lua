local core = require "core"
local common = require "core.common"

---@alias core.test.status
---| '"passed"'
---| '"failed"'
---| '"skipped"'

---Represents the execution context passed to hooks and test callbacks.
---@class core.test.context
---@field file string Absolute path of the loaded test file.
---@field relative_file string Path relative to the root passed to `test.run()`.

---Represents a single reported test result.
---@class core.test.item_result
---@field path string Absolute path of the loaded test file.
---@field relative_path string Path relative to the root passed to `test.run()`.
---@field name string Test case name without parent suite names.
---@field full_name string Fully qualified test name including parent suites.
---@field duration number Test execution time in seconds.
---@field status core.test.status
---@field message? string Failure or skip message.

---Represents the aggregated results for a single test file.
---@class core.test.file_result
---@field path string Absolute path of the loaded test file.
---@field relative_path string Path relative to the root passed to `test.run()`.
---@field total integer
---@field passed integer
---@field failed integer
---@field skipped integer
---@field items core.test.item_result[]

---Represents the aggregated results for a test run.
---@class core.test.results
---@field root string Root path that was discovered.
---@field files core.test.file_result[]
---@field items core.test.item_result[]
---@field total integer
---@field passed integer
---@field failed integer
---@field skipped integer
---@field duration number Total execution time in seconds.

---Represents an async test run started with `test.run()`.
---@class core.test.runner
---@field path string
---@field status '"running"' | '"passed"' | '"failed"' | '"error"'
---@field results? core.test.results
---@field error? string
---@field thread thread

---Options used when running a test suite.
---@class core.test.run_options
---@field on_result? fun(item: core.test.item_result, file_results: core.test.file_result)
---@field on_complete? fun(results: core.test.results|nil, err: string|nil, runner: core.test.runner)

---Options used when reporting test results.
---@class core.test.report_options
---@field colorize? fun(text: string, color: string): string
---@field write? fun(message: string)
---@field show_items? boolean
---@field quit_on_finish? boolean
---@field force_quit? boolean
---@field quit? fun(force: boolean, exit_code?: integer)

---Utility helpers for declaring, running and reporting tests.
---@class core.test
local test = {}

local builder_root
local builder_stack

local function identity(value)
  return value
end

local function yield_to_ui(wait)
  if coroutine.isyieldable() then
    core.redraw = true
    coroutine.yield(wait)
  end
end

local function is_node(value, kind)
  return type(value) == "table" and value.kind == kind
end

local function new_suite(name, source)
  return {
    kind = "suite",
    name = name,
    source = source,
    children = {},
    before_each = {},
    after_each = {}
  }
end

local function new_case(name, fn, options)
  options = options or {}
  return {
    kind = "test",
    name = name,
    fn = fn,
    source = options.source,
    skip_reason = options.skip_reason
  }
end

local function pretty(value)
  local kind = type(value)
  if kind == "string" or kind == "number" or kind == "boolean"
    or kind == "nil" or kind == "table"
  then
    local ok, serialized = pcall(common.serialize, value, {
      pretty = kind == "table",
      sort = true,
      limit = 3
    })
    if ok then
      return serialized
    end
  end
  return tostring(value)
end

local function current_suite()
  assert(builder_stack and #builder_stack > 0,
    "test definitions must be declared while loading a test file")
  return builder_stack[#builder_stack]
end

local function add_child(node)
  local suite = current_suite()
  node.parent = suite
  table.insert(suite.children, node)
  return node
end

local function deep_equal(actual, expected, seen)
  if actual == expected then return true end
  if type(actual) ~= type(expected) then return false end
  if type(actual) ~= "table" then return false end

  seen = seen or {}
  seen[actual] = seen[actual] or {}
  if seen[actual][expected] then return true end
  seen[actual][expected] = true

  for key, value in pairs(actual) do
    if not deep_equal(value, expected[key], seen) then
      return false
    end
  end
  for key in pairs(expected) do
    if actual[key] == nil and expected[key] ~= nil then
      return false
    end
  end
  return true
end

local function join_names(parts)
  local names = {}
  for _, part in ipairs(parts) do
    if part and part ~= "" then
      table.insert(names, part)
    end
  end
  return table.concat(names, " > ")
end

local function normalize_path(path)
  return PATHSEP == "\\" and path:gsub("\\", "/") or path
end

local function relative_to(root, path)
  local normalized_root = normalize_path(root)
  local normalized_path = normalize_path(path)
  if normalized_path:find(normalized_root, 1, true) == 1 then
    local relative = normalized_path:sub(#normalized_root + 1)
    if relative:sub(1, 1) == "/" then
      relative = relative:sub(2)
    end
    if relative ~= "" then
      return relative
    end
  end
  return normalized_path
end

local function join_path(path, item)
  if path:sub(-1) == PATHSEP then
    return path .. item
  end
  return path .. PATHSEP .. item
end

local function scan_lua_files(path, files)
  local info, errmsg = system.get_file_info(path)
  if not info then
    return nil, errmsg or ("path not found: " .. path)
  end

  if info.type == "file" then
    if path:match("%.lua$") then
      table.insert(files, path)
    end
    return true
  end

  local list, list_err = system.list_dir(path)
  if not list then
    return nil, list_err or ("unable to list directory: " .. path)
  end

  table.sort(list, function(a, b) return a < b end)
  for _, item in ipairs(list) do
    local item_path = join_path(path, item)
    local item_info = system.get_file_info(item_path)
    if item_info then
      if item_info.type == "dir" then
        local ok, err = scan_lua_files(item_path, files)
        if not ok then
          return nil, err
        end
      elseif item_info.type == "file" and item_path:match("%.lua$") then
        table.insert(files, item_path)
      end
    end
  end

  return true
end

local function normalize_loaded_result(root, result)
  if result == nil then return end
  if type(result) == "function" then
    return normalize_loaded_result(root, result(test))
  end
  if is_node(result, "suite") or is_node(result, "test") then
    if result.parent == nil then
      add_child(result)
    end
    return
  end
  if type(result) == "table" then
    for _, item in ipairs(result) do
      normalize_loaded_result(root, item)
    end
    return
  end
  error("unsupported test file result of type '" .. type(result) .. "'", 0)
end

local function load_error_handler(err)
  return debug.traceback(tostring(err), 2):gsub("\t", "")
end

local function is_skip_error(err)
  return type(err) == "table" and err.__pragtical_test_skip
end

local function run_error_handler(err)
  if is_skip_error(err) then
    return err
  end
  return debug.traceback(tostring(err), 2):gsub("\t", "")
end

local function format_routine_error(cr, err)
  if is_skip_error(err) then
    return err
  end
  return debug.traceback(cr, tostring(err)):gsub("\t", "")
end

local function run_routine(fn, ...)
  local args = table.pack(...)
  local cr = coroutine.create(function()
    return xpcall(function()
      return fn(table.unpack(args, 1, args.n))
    end, run_error_handler)
  end)

  while true do
    local ok, value, extra = coroutine.resume(cr)
    if not ok then
      return false, format_routine_error(cr, value)
    end
    if coroutine.status(cr) == "dead" then
      if not value then
        return false, extra
      end
      return true, extra
    end
    yield_to_ui(value)
  end
end

local function add_result(results, result, on_result)
  table.insert(results.items, result)
  results.total = results.total + 1
  results[result.status] = results[result.status] + 1
  if on_result then
    on_result(result, results)
  end
end

local function run_hooks(hooks, context)
  for _, hook in ipairs(hooks) do
    local ok, err = run_routine(hook, context)
    if not ok then
      return false, err
    end
  end
  return true
end

local function run_after_hooks(hooks, context)
  local messages = {}
  for i = #hooks, 1, -1 do
    local ok, err = run_routine(hooks[i], context)
    if not ok then
      table.insert(messages, is_skip_error(err) and (err.reason or "skipped") or err)
    end
  end
  if #messages > 0 then
    return false, table.concat(messages, "\n\n")
  end
  return true
end

local function run_case(node, file_result, names, before_hooks, after_hooks, on_result)
  local started_at = system.get_time()
  local context = {
    file = file_result.path,
    relative_file = file_result.relative_path
  }
  local result = {
    path = file_result.path,
    relative_path = file_result.relative_path,
    name = node.name,
    full_name = join_names(names),
    duration = 0,
    status = "passed"
  }

  if node.skip_reason then
    result.status = "skipped"
    result.message = node.skip_reason
    result.duration = system.get_time() - started_at
    add_result(file_result, result, on_result)
    return
  end

  local ok, err = run_hooks(before_hooks, context)
  if ok then
    ok, err = run_routine(node.fn, context)
  end
  local after_ok, after_err = run_after_hooks(after_hooks, context)

  if not ok then
    if is_skip_error(err) then
      result.status = "skipped"
      result.message = err.reason or "skipped"
    else
      result.status = "failed"
      result.message = err
    end
  elseif not after_ok then
    result.status = "failed"
    result.message = after_err
  end

  result.duration = system.get_time() - started_at
  add_result(file_result, result, on_result)
  yield_to_ui()
end

local function run_suite_node(node, file_result, names, before_hooks, after_hooks, on_result)
  if node.kind == "suite" then
    local suite_names = table.pack(table.unpack(names))
    if node.name and node.name ~= "" then
      table.insert(suite_names, node.name)
    end

    local suite_before = table.pack(table.unpack(before_hooks))
    for _, hook in ipairs(node.before_each) do
      table.insert(suite_before, hook)
    end

    local suite_after = table.pack(table.unpack(after_hooks))
    for _, hook in ipairs(node.after_each) do
      table.insert(suite_after, hook)
    end

    for _, child in ipairs(node.children) do
      run_suite_node(child, file_result, suite_names, suite_before, suite_after, on_result)
    end
  else
    local case_names = table.pack(table.unpack(names))
    table.insert(case_names, node.name)
    run_case(node, file_result, case_names, before_hooks, after_hooks, on_result)
  end
end

---Create a named suite and register all tests declared within its callback.
---
---Nested suites inherit `before_each()` and `after_each()` hooks from their
---ancestors and contribute to the reported full test name.
---@param name string
---@param fn fun()
---@return table suite
function test.describe(name, fn)
  assert(type(name) == "string", "invalid suite name")
  assert(type(fn) == "function", "invalid suite callback")
  local suite = add_child(new_suite(name))
  table.insert(builder_stack, suite)
  local ok, err = xpcall(fn, load_error_handler)
  table.remove(builder_stack)
  if not ok then
    error(err, 0)
  end
  return suite
end

---Register a hook executed before every test in the current suite.
---@param fn fun(context: core.test.context)
function test.before_each(fn)
  assert(type(fn) == "function", "before_each expects a function")
  table.insert(current_suite().before_each, fn)
end

---Register a hook executed after every test in the current suite.
---
---After hooks execute in reverse registration order.
---@param fn fun(context: core.test.context)
function test.after_each(fn)
  assert(type(fn) == "function", "after_each expects a function")
  table.insert(current_suite().after_each, fn)
end

---Register a test case in the current suite.
---@param name string
---@param fn fun(context: core.test.context)
---@return table case
function test.test(name, fn)
  assert(type(name) == "string", "invalid test name")
  assert(type(fn) == "function", "invalid test callback")
  return add_child(new_case(name, fn))
end

test.it = test.test

---Register a skipped test case in the current suite.
---@param name string
---@param reason? string
---@return table case
function test.skip(name, reason)
  assert(type(name) == "string", "invalid test name")
  return add_child(new_case(name, function() end, {
    skip_reason = reason or "skipped"
  }))
end

---Skip the current test immediately.
---@param reason? string
function test.skip_now(reason)
  error({
    __pragtical_test_skip = true,
    reason = reason or "skipped"
  }, 0)
end

---Skip the current test when the given condition is truthy.
---@param condition any
---@param reason? string
function test.skip_if(condition, reason)
  if condition then
    test.skip_now(reason)
  end
end

---Fail the current test.
---@param message? string
---@param level? integer
function test.fail(message, level)
  error(message or "test assertion failed", (level or 1) + 1)
end

---Assert that a value is truthy.
---@generic T
---@param value T
---@param message? string
---@return T
function test.ok(value, message)
  if not value then
    test.fail(message or ("expected truthy value, got " .. pretty(value)), 2)
  end
  return value
end

---Assert that a value is falsy.
---@param value any
---@param message? string
function test.not_ok(value, message)
  if value then
    test.fail(message or ("expected falsy value, got " .. pretty(value)), 2)
  end
end

---Assert that two values are equal using Lua's `==` operator.
---@generic T
---@param actual T
---@param expected T
---@param message? string
---@return T
function test.equal(actual, expected, message)
  if actual ~= expected then
    test.fail(message or string.format(
      "expected %s but got %s",
      pretty(expected), pretty(actual)
    ), 2)
  end
  return actual
end

---Assert that two values are not equal using Lua's `==` operator.
---@param actual any
---@param expected any
---@param message? string
function test.not_equal(actual, expected, message)
  if actual == expected then
    test.fail(message or ("did not expect " .. pretty(actual)), 2)
  end
end

---Assert that two values are deeply equal.
---@generic T
---@param actual T
---@param expected T
---@param message? string
---@return T
function test.same(actual, expected, message)
  if not deep_equal(actual, expected) then
    test.fail(message or string.format(
      "expected %s but got %s",
      pretty(expected), pretty(actual)
    ), 2)
  end
  return actual
end

---Assert that a value is not `nil`.
---@generic T
---@param value T
---@param message? string
---@return T
function test.not_nil(value, message)
  if value == nil then
    test.fail(message or "expected non-nil value", 2)
  end
  return value
end

---Assert that a value is `nil`.
---@param value any
---@param message? string
function test.is_nil(value, message)
  if value ~= nil then
    test.fail(message or ("expected nil but got " .. pretty(value)), 2)
  end
end

---Assert that a string matches a pattern.
---@param value string
---@param pattern string
---@param message? string
---@param plain? boolean Treat `pattern` as a plain substring.
---@return string
function test.match(value, pattern, message, plain)
  test.equal(type(value), "string", "test.match expected a string value")
  if not value:find(pattern, 1, plain) then
    test.fail(message or string.format(
      "expected %s to match %s",
      pretty(value), pretty(pattern)
    ), 2)
  end
  return value
end

---Assert that a string or table contains a value.
---@param container string|table
---@param value any
---@param message? string
function test.contains(container, value, message)
  local container_type = type(container)
  if container_type == "string" then
    if not container:find(value, 1, true) then
      test.fail(message or string.format(
        "expected %s to contain %s",
        pretty(container), pretty(value)
      ), 2)
    end
    return
  end
  if container_type == "table" then
    for _, item in pairs(container) do
      if item == value then
        return
      end
    end
  end
  test.fail(message or string.format(
    "expected %s to contain %s",
    pretty(container), pretty(value)
  ), 2)
end

---Assert that a value has the expected Lua type.
---@param value any
---@param expected_type string
---@param message? string
---@return string
function test.type(value, expected_type, message)
  return test.equal(type(value), expected_type, message)
end

---Assert that two numbers are within a given delta.
---@param actual number
---@param expected number
---@param delta? number
---@param message? string
---@return number
function test.near(actual, expected, delta, message)
  delta = delta or 1e-6
  if math.abs(actual - expected) > delta then
    test.fail(message or string.format(
      "expected %s to be within %s of %s",
      pretty(actual), pretty(delta), pretty(expected)
    ), 2)
  end
  return actual
end

---Assert that a function raises an error.
---
---When `expected` is a string it must be contained in the error text. When it
---is a function it is called with the raised error and must return truthy.
---@param fn fun()
---@param expected? string|fun(err: any): boolean
---@param message? string
---@return any err
function test.error(fn, expected, message)
  assert(type(fn) == "function", "test.error expects a function")
  local ok, err = xpcall(fn, run_error_handler)
  if ok then
    test.fail(message or "expected function to raise an error", 2)
  end
  if type(expected) == "string" then
    local errtext = is_skip_error(err) and (err.reason or "") or tostring(err)
    if not errtext:find(expected, 1, true) then
      test.fail(message or string.format(
        "expected error containing %s but got %s",
        pretty(expected), pretty(errtext)
      ), 2)
    end
  elseif type(expected) == "function" then
    test.ok(expected(err), message or "error predicate returned false")
  end
  return err
end

---Assert that a function completes without raising an error.
---@generic T
---@param fn fun(): T
---@param message? string
---@return T
function test.no_error(fn, message)
  assert(type(fn) == "function", "test.no_error expects a function")
  local ok, result = xpcall(fn, run_error_handler)
  if not ok then
    test.fail(message or ("expected function to succeed, got " .. tostring(result)), 2)
  end
  return result
end

---Load a Lua test file and return its registered root suite.
---@param path string
---@return table|nil root
---@return string? errmsg
function test.load_file(path)
  local root = new_suite(common.basename(path), path)
  local chunk, errmsg = loadfile(path)
  if not chunk then
    return nil, errmsg
  end

  local previous_root, previous_stack = builder_root, builder_stack
  builder_root = root
  builder_stack = { root }

  local ok, result = xpcall(chunk, load_error_handler)
  if ok then
    ok, result = xpcall(function()
      normalize_loaded_result(root, result)
      if #root.children == 0 then
        error("test file did not register any tests", 0)
      end
    end, load_error_handler)
  end

  builder_root, builder_stack = previous_root, previous_stack

  if not ok then
    return nil, result
  end
  return root
end

---Discover Lua test files inside the given path.
---
---If `path` points to a file, it is returned when it has a `.lua` extension.
---Directories are walked recursively and sorted lexicographically.
---@param path string
---@return string[]|nil files
---@return string? errmsg
function test.discover(path)
  local files = {}
  local ok, err = scan_lua_files(path, files)
  if not ok then
    return nil, err
  end
  table.sort(files, function(a, b) return a < b end)
  return files
end

local function run_sync(path, options)
  options = options or {}
  local files, errmsg = test.discover(path)
  if not files then
    return nil, errmsg
  end

  local started_at = system.get_time()
  local results = {
    root = path,
    files = {},
    items = {},
    total = 0,
    passed = 0,
    failed = 0,
    skipped = 0,
    duration = 0
  }

  for _, file in ipairs(files) do
    local file_result = {
      path = file,
      relative_path = relative_to(path, file),
      total = 0,
      passed = 0,
      failed = 0,
      skipped = 0,
      items = {}
    }
    table.insert(results.files, file_result)

    local suite, load_err = test.load_file(file)
    if not suite then
      add_result(file_result, {
        path = file,
        relative_path = file_result.relative_path,
        name = "<load>",
        full_name = file_result.relative_path,
        status = "failed",
        message = load_err,
        duration = 0
      }, options.on_result)
    else
      run_suite_node(suite, file_result, {}, {}, {}, options.on_result)
    end
    yield_to_ui()

    for _, item in ipairs(file_result.items) do
      table.insert(results.items, item)
      results.total = results.total + 1
      results[item.status] = results[item.status] + 1
    end
  end

  results.duration = system.get_time() - started_at
  return results
end

---Run the given test file or directory asynchronously.
---
---The returned runner is updated as the background thread advances and the
---optional callbacks in `options` are invoked as items complete.
---@param path string
---@param options? core.test.run_options
---@return core.test.runner|nil runner
---@return string? errmsg
function test.run(path, options)
  options = options or {}
  local info, errmsg = system.get_file_info(path)
  if not info then
    return nil, errmsg or ("path not found: " .. tostring(path))
  end

  local runner = {
    path = path,
    status = "running",
    results = nil,
    error = nil
  }

  runner.thread = core.add_background_thread(function()
    local coroutine_yield = coroutine.yield
    coroutine.yield = function(...)
      core.redraw = true
      return coroutine_yield(...)
    end

    local results, run_err = run_sync(path, options)

    coroutine.yield = coroutine_yield

    runner.results = results
    runner.error = run_err
    if results then
      runner.status = results.failed > 0 and "failed" or "passed"
    else
      runner.status = "error"
    end

    if options.on_complete then
      options.on_complete(results, run_err, runner)
    end
  end)

  return runner
end

---Write a formatted report for a full test run.
---@param results core.test.results
---@param options? core.test.report_options
---@return boolean success
function test.report(results, options)
  options = options or {}
  local colorize = options.colorize or identity
  local write = options.write or print

  local function status_text(status)
    if status == "passed" then
      return "PASS"
    elseif status == "failed" then
      return "FAIL"
    end
    return "SKIP"
  end

  local function status_label(status)
    local label = status_text(status)
    if status == "passed" then
      return colorize(label, "green")
    elseif status == "failed" then
      return colorize(label, "red")
    end
    return colorize(label, "yellow")
  end

  local function write_item(item)
    local line = string.format("%s %s", status_label(item.status), item.full_name)
    write(line)
    core.log("%s %s", status_text(item.status), item.full_name)
    if item.message and item.message ~= "" then
      write(item.message:gsub("^", "  "))
      core.log("%s", item.message)
    end
  end

  if options.show_items ~= false then
    for _, item in ipairs(results.items) do
      write_item(item)
    end
  end

  local summary_color = results.failed > 0 and "red" or "green"
  local summary = string.format(
    "Ran %d tests in %d files: %d passed, %d failed, %d skipped (%.3fs)",
    results.total, #results.files, results.passed, results.failed,
    results.skipped, results.duration
  )
  write("")
  write(colorize(summary, summary_color))
  core.log("%s", summary)

  local success = results.failed == 0
  if options.quit_on_finish then
    local quit = options.quit or core.quit
    quit(
      type(options.force_quit) == "nil" and true or options.force_quit,
      success and 0 or 1
    )
  end

  return success
end

---Write a formatted line for a single test result item.
---@param item core.test.item_result
---@param options? core.test.report_options
function test.report_item(item, options)
  options = options or {}
  local colorize = options.colorize or identity
  local write = options.write or print
  local text = item.status == "passed" and "PASS"
    or item.status == "failed" and "FAIL"
    or "SKIP"
  local label = item.status == "passed" and colorize(text, "green")
    or item.status == "failed" and colorize(text, "red")
    or colorize(text, "yellow")

  write(string.format("%s %s", label, item.full_name))
  core.log("%s %s", text, item.full_name)
  if item.message and item.message ~= "" then
    write(item.message:gsub("^", "  "))
    core.log("%s", item.message)
  end
end

return test

local test = require "core.test"
local common = require "core.common"
local script = "plugins.transaction_test.apply"

test.describe("transactions", function()
  test.before_each(function(ctx)
    ctx.root = os.tmpname()
    os.remove(ctx.root)
    test.ok(common.mkdirp(ctx.root .. PATHSEP .. "plugins" .. PATHSEP .. "transaction_test"))
    local env = setmetatable({ USERDIR = ctx.root }, { __index = _G })
    ctx.tx = assert(loadfile(DATADIR .. "/core/transactions.lua", "t", env))()
    -- Replace the isolated runner's window factory so tests never open a window.
    local index = 1
    while assert(debug.getupvalue(ctx.tx.run, index), "missing open_report") ~= "open_report" do
      index = index + 1
    end
    debug.setupvalue(ctx.tx.run, index, function() return ctx.report end)
  end)

  test.after_each(function(ctx)
    common.rm(ctx.root, true)
  end)

  test.test("persists distinct requests and does not overwrite a filename collision", function(ctx)
    local tx = ctx.tx
    test.ok(tx.register(script, { phase = "startup", payload = { version = 1 } }))
    local snapshot = assert(tx.get(script))
    snapshot.payload.version = 99
    test.equal(tx.get(script).payload.version, 1)
    test.not_ok(tx.register(script))
    test.ok(tx.register(script, { id = "other" }))
    test.not_ok(tx.register(script .. ".other"))
    test.not_ok(tx.remove(script .. ".other"))
    test.equal(tx.get(script, { id = "other" }).state, "ready")
    test.ok(tx.remove(script))
    test.equal(tx.get(script), nil)
  end)

  test.test("does not write while another instance owns the queue guard", function(ctx)
    local tx = ctx.tx
    test.ok(tx.register(script))
    local guard = ctx.root .. "/transactions/startup/.writing"
    test.ok(system.mkdir(guard))
    local removed, err = tx.remove(script)
    test.not_ok(removed)
    test.equal(err, "busy")
    test.ok(system.rmdir(guard))
    test.equal(tx.get(script).state, "ready")
    test.ok(tx.remove(script))
    test.not_ok(system.get_file_info(guard))
  end)

  test.test("keeps the complete batch log until acknowledged, outside the queue guard", function(ctx)
    local file = assert(io.open(ctx.root .. "/plugins/transaction_test/apply.lua", "wb"))
    assert(file:write('return function(id, _, ctx) ctx:progress(id); ctx:yield(); return true end'))
    assert(file:close())
    local lines, reviews = {}, 0
    ctx.report = {
      log = function(_, line) lines[#lines + 1] = line end,
      frame = function(_, _, _, finished)
        if finished then
          reviews = reviews + 1
          test.is_nil(ctx.tx.get(script, { id = "second" }))
          return reviews < 2
        end
        return true
      end
    }
    for _, id in ipairs { "first", "second" } do test.ok(ctx.tx.register(script, { id = id })) end
    test.ok(ctx.tx.run())
    test.equal(reviews, 2)
    test.same(lines, { "Executing transaction: first", "first", "Completed: first",
      "Executing transaction: second", "second", "Completed: second" })
  end)

  test.test("updates transfer detail without repeating the activity in the log", function(ctx)
    local file = assert(io.open(ctx.root .. "/plugins/transaction_test/apply.lua", "wb"))
    file:write([[return function(_, _, ctx)
      ctx:progress("Known size", 0.25, "1 KiB / 4 KiB")
      ctx:progress("Known size", 0.5, "2 KiB / 4 KiB")
      ctx:progress("Unknown size", nil, "1 KiB")
      ctx:progress("Unknown size", nil, "2 KiB")
      return true
    end]])
    file:close()
    local lines, frames = {}, {}
    ctx.report = {
      log = function(_, line) lines[#lines + 1] = line end,
      frame = function(_, _, fraction, finished, detail)
        if not finished and detail then frames[#frames + 1] = { fraction or false, detail } end
        return not finished
      end,
    }
    test.ok(ctx.tx.register(script))
    test.ok(ctx.tx.run())
    test.same(lines, { "Executing transaction: " .. script, "Known size", "Unknown size", "Completed: " .. script })
    test.same(frames, { {0.25, "1 KiB / 4 KiB"}, {0.5, "2 KiB / 4 KiB"}, {false, "1 KiB"}, {false, "2 KiB"} })
  end)

  test.test("claims only the remaining requests from the initial batch", function(ctx)
    local file = assert(io.open(ctx.root .. "/plugins/transaction_test/apply.lua", "wb"))
    assert(file:write([[
return function(id, payload)
  if id == "first" then
    local env = setmetatable({ USERDIR = payload.root }, { __index = _G })
    local other = assert(loadfile(DATADIR .. "/core/transactions.lua", "t", env))()
    local ok, err = other.run()
    assert(not ok and err:find("in progress", 1, true))
    assert(other.remove(payload.script, { id = "skip" }))
    assert(other.register(payload.script, { id = "next_run" }))
  end
  return true
end
]]))
    assert(file:close())
    for _, id in ipairs { "skip", "last", "first" } do
      test.ok(ctx.tx.register(script, { id = id, payload = { root = ctx.root, script = script } }))
    end
    test.ok(ctx.tx.run())
    test.equal(ctx.tx.get(script, { id = "last" }), nil)
    test.equal(ctx.tx.get(script, { id = "next_run" }).state, "ready")
    test.ok(ctx.tx.run())
    test.equal(ctx.tx.get(script, { id = "next_run" }), nil)
  end)

  test.test("defers a retryable handler until the next launch without losing the batch", function(ctx)
    local release = ctx.root .. "/released"
    local file = assert(io.open(ctx.root .. "/plugins/transaction_test/apply.lua", "wb"))
    assert(file:write([[
return function(id, payload, ctx)
  if id == "first" and not system.get_file_info(payload) then
    return nil, { message = "Close the program using the file.", retry = true }
  end
  if id == "first" then assert(ctx.previous_failure.retry) end
  return true
end
]]))
    file:close()
    for _, id in ipairs { "first", "second" } do
      test.ok(ctx.tx.register(script, { id = id, payload = release }))
    end
    local lines, title = {}, nil
    ctx.report = {
      log = function(_, line) lines[#lines + 1] = line end,
      frame = function(_, text, _, finished) if finished then title = text end return not finished end,
    }
    for _ = 1, 2 do
      test.ok(ctx.tx.run())
      test.equal(title, "Startup transactions deferred")
      test.equal(lines[#lines], "Deferred: first\nClose the program using the file.")
      test.equal(ctx.tx.get(script, { id = "first" }).state, "ready")
      test.equal(ctx.tx.get(script, { id = "second" }).state, "ready")
    end
    assert(io.open(release, "wb")):close()
    test.ok(ctx.tx.run())
    test.equal(title, "Startup transactions complete")
    test.is_nil(ctx.tx.get(script, { id = "first" }))
    test.is_nil(ctx.tx.get(script, { id = "second" }))
  end)

  for _, case in ipairs {
    { source = "return true", state = nil },
    { source = 'return nil, { message = "locked", code = "in_use" }', state = "failed" },
    { source = 'error("interrupted")', state = "in_progress" },
    { source = 'return nil, { message = "rollback failed", retry = true, recovery_required = true }',
      state = "in_progress", label = "recovery takes precedence over retry" },
  } do
    test.test(case.label or ("runs a handler and leaves state " .. tostring(case.state)), function(ctx)
      local file = assert(io.open(ctx.root .. "/plugins/transaction_test/apply.lua", "wb"))
      assert(file:write([[
return function(id, payload, ctx)
  assert(id == "plugins.transaction_test.apply" and payload.value == 42)
  assert(ctx.phase == "startup")
  ctx:progress("Applying test update", 0.5)
  ctx:yield()
]], case.source, "\nend\n"))
      assert(file:close())
      test.ok(ctx.tx.register(script, { payload = { value = 42 } }))
      local ok = ctx.tx.run()
      local record = ctx.tx.get(script)
      test.equal(record and record.state, case.state)
      if case.state == "failed" then
        test.not_ok(ok)
        test.equal(record.last_failure.code, "in_use")
        test.ok(ctx.tx.run())
      elseif case.state == "in_progress" then
        test.not_ok(ok)
        local removed, err = ctx.tx.remove(script)
        test.not_ok(removed)
        test.equal(err, "busy")
        test.not_ok(ctx.tx.run())
      else
        test.ok(ok)
      end
    end)
  end
end)

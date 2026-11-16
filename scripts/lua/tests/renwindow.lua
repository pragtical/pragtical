local test = require "core.test"

test.describe("renwindow relative mouse mode", function()
  test.before_each(function(context)
    context.window = renwindow.create("relative-mouse-test", 320, 240)
  end)

  test.after_each(function(context)
    if context.window then context.window:set_relative_mouse_mode(false) end
  end)

  test.test("starts disabled and can be disabled repeatedly", function(context)
    local window = context.window
    test.equal(window:get_relative_mouse_mode(), false)
    for _ = 1, 2 do
      local ok, err = window:set_relative_mouse_mode(false)
      test.equal(ok, true)
      test.is_nil(err)
      test.equal(window:get_relative_mouse_mode(), false)
    end
  end)

  test.test("reports driver rejection or updates the requested window", function(context)
    local window = context.window
    local other = renwindow.create("relative-mouse-other", 320, 240)
    local ok, err = window:set_relative_mouse_mode(true)
    if ok then
      test.equal(ok, true)
      test.is_nil(err)
      test.equal(window:get_relative_mouse_mode(), true)
      test.equal(window:set_relative_mouse_mode(true), true)
    else
      test.is_nil(ok)
      test.type(err, "string")
      test.ok(#err > 0)
      test.equal(window:get_relative_mouse_mode(), false)
    end
    test.equal(other:get_relative_mouse_mode(), false)
    test.equal(window:set_relative_mouse_mode(false), true)
    test.equal(window:get_relative_mouse_mode(), false)
  end)

  test.test("validates the window and requires a boolean mode", function(context)
    test.error(function() renwindow.get_relative_mouse_mode({}) end)
    test.error(function() renwindow.set_relative_mouse_mode({}, true) end)
    test.error(function() context.window:set_relative_mouse_mode() end)
    for _, value in ipairs({0, 1, "true", {}}) do
      test.error(function() context.window:set_relative_mouse_mode(value) end)
    end
    test.equal(context.window:get_relative_mouse_mode(), false)
  end)
end)

local test = require "core.test"

local function shell_command(command)
  if PLATFORM == "Windows" then
    return {"cmd", "/C", command}
  end
  return {"sh", "-lc", command}
end

test.describe("process", function()
  test.test("exports the documented functions and constants", function()
    for _, name in ipairs({
      "start", "strerror", "STREAM_STDIN", "STREAM_STDOUT", "STREAM_STDERR",
      "WAIT_INFINITE", "WAIT_DEADLINE", "REDIRECT_DEFAULT",
      "REDIRECT_PARENT", "REDIRECT_DISCARD", "REDIRECT_STDOUT"
    }) do
      test.not_nil(process[name], "missing process." .. name)
    end
  end)

  test.test("can launch a subprocess and read stdout", function()
    local proc = process.start(shell_command("printf 'hello-from-process'"), {
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_PIPE
    })

    test.not_nil(proc)
    test.ok(proc:pid() > 0)

    local exit_code = proc:wait(process.WAIT_INFINITE, 0.1)
    test.type(exit_code, "number")
    test.equal(proc:returncode(), exit_code)

    local output = proc:read_stdout(128) or ""
    test.contains(output, "hello-from-process")
    test.not_ok(proc:running())
  end)

  test.test("supports stdin pipes and environment overrides", function()
    local command = PLATFORM == "Windows"
      and "set /p INPUT=& echo %PRAGTICAL_PROCESS_TEST_ENV%:%INPUT%"
      or "IFS= read -r INPUT; printf '%s:%s' \"$PRAGTICAL_PROCESS_TEST_ENV\" \"$INPUT\""
    local proc = process.start(shell_command(command), {
      stdin = process.REDIRECT_PIPE,
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_PIPE,
      env = {
        PRAGTICAL_PROCESS_TEST_ENV = "ok"
      }
    })

    test.not_nil(proc)
    test.ok(proc:write("hello\n") > 0)
    test.not_nil(proc:close_stream(process.STREAM_STDIN))

    local exit_code = proc:wait(process.WAIT_INFINITE, 0.1)
    test.type(exit_code, "number")
    test.equal(proc:returncode(), exit_code)

    local output = proc:read_stdout(256) or ""
    test.contains(output, "ok:hello")
    test.type(process.strerror(1), "string")
  end)
end)

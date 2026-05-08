local test = require "core.test"

local function shell_command(command)
  if PLATFORM == "Windows" then
    return {"cmd", "/V:ON", "/C", command}
  end
  return {"sh", "-lc", command}
end

test.describe("process", function()
  test.test("exports the documented functions and constants", function()
    for _, name in ipairs({
      "start", "strerror", "ERROR_PIPE", "ERROR_WOULDBLOCK", "ERROR_TIMEDOUT",
      "ERROR_INVAL", "ERROR_NOMEM", "STREAM_STDIN", "STREAM_STDOUT", "STREAM_STDERR",
      "WAIT_INFINITE", "WAIT_DEADLINE", "REDIRECT_DEFAULT", "REDIRECT_PIPE",
      "REDIRECT_PARENT", "REDIRECT_DISCARD", "REDIRECT_STDOUT"
    }) do
      test.not_nil(process[name], "missing process." .. name)
    end
  end)

  test.test("can launch a subprocess and read stdout", function()
    local command = PLATFORM == "Windows"
      and "echo hello-from-process"
      or "printf 'hello-from-process'"
    local proc = process.start(shell_command(command), {
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
      and "set /p INPUT=& echo %PRAGTICAL_PROCESS_TEST_ENV%:!INPUT!"
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

  test.test("does not mutate environment options", function()
    local command = PLATFORM == "Windows"
      and "echo %PRAGTICAL_PROCESS_TEST_ENV%"
      or "printf '%s' \"$PRAGTICAL_PROCESS_TEST_ENV\""
    local options = {
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_PIPE,
      env = {
        PRAGTICAL_PROCESS_TEST_ENV = "reused"
      }
    }

    for _ = 1, 2 do
      local proc = process.start(shell_command(command), options)
      test.not_nil(proc)
      test.type(proc:wait(process.WAIT_INFINITE, 0.01), "number")
      test.contains(proc:read_stdout(128) or "", "reused")
    end

    test.type(options.env, "table")
  end)

  test.test("supports environment callback options", function()
    local command = PLATFORM == "Windows"
      and "echo %PRAGTICAL_PROCESS_TEST_ENV%"
      or "printf '%s' \"$PRAGTICAL_PROCESS_TEST_ENV\""
    local proc = process.start(shell_command(command), {
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_PIPE,
      env = function(system_env)
        system_env.PRAGTICAL_PROCESS_TEST_ENV = "callback"
        local env = {}
        for key, value in pairs(system_env) do
          env[#env + 1] = key .. "=" .. value
        end
        return table.concat(env, "\0") .. "\0\0"
      end
    })

    test.not_nil(proc)
    test.type(proc:wait(process.WAIT_INFINITE, 0.01), "number")
    test.contains(proc:read_stdout(128) or "", "callback")
  end)

  test.test("stream wrappers return native errors", function()
    local command = PLATFORM == "Windows" and "echo done" or "printf done"
    local proc = process.start(shell_command(command), {
      stdin = process.REDIRECT_PIPE,
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_PIPE
    })

    test.not_nil(proc)
    test.not_nil(proc.stdin:close())
    local written, err, errcode = proc.stdin:write("data")
    test.equal(written, nil)
    test.type(err, "string")
    test.type(errcode, "number")
    test.type(proc:wait(process.WAIT_INFINITE, 0.01), "number")
  end)

  test.test("wait timeout uses milliseconds in the Lua wrapper", function()
    local command = PLATFORM == "Windows"
      and "ping -n 2 127.0.0.1 > nul"
      or "sleep 0.3"
    local proc = process.start(shell_command(command), {
      stdout = process.REDIRECT_DISCARD,
      stderr = process.REDIRECT_DISCARD
    })

    test.not_nil(proc)
    local start = system.get_time()
    local code = proc:wait(100, 0.01)
    local elapsed = system.get_time() - start
    test.equal(code, nil)
    test.ok(elapsed >= 0.05)
    test.ok(elapsed < 0.25)
    proc:kill()
  end)

  test.test("can wait before reading large piped output", function()
    local command = PLATFORM == "Windows"
      and "for /L %i in (1,1,4096) do @echo 0123456789012345678901234567890123456789"
      or "i=0; while [ \"$i\" -lt 4096 ]; do printf '0123456789012345678901234567890123456789\\n'; i=$((i+1)); done"
    local proc = process.start(shell_command(command), {
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_PIPE
    })

    test.not_nil(proc)
    test.type(proc:wait(process.WAIT_INFINITE, 0.1), "number")

    local chunks, total = {}, 0
    while true do
      local chunk = proc:read_stdout(4096)
      if not chunk then break end
      if #chunk > 0 then
        chunks[#chunks + 1] = chunk
        total = total + #chunk
      end
    end

    test.ok(total > 100000)
    test.contains(table.concat(chunks), "0123456789012345678901234567890123456789")
  end)

  test.test("garbage collecting running processes does not block on termination retries", function()
    test.skip_if(PLATFORM == "Windows", "TERM ignore setup is POSIX-specific")

    for _ = 1, 8 do
      local proc = process.start(shell_command("trap '' TERM; exec sleep 2"), {
        stdin = process.REDIRECT_DISCARD,
        stdout = process.REDIRECT_DISCARD,
        stderr = process.REDIRECT_DISCARD
      })
      test.not_nil(proc)
    end

    local start = system.get_time()
    collectgarbage("collect")
    test.ok(system.get_time() - start < 0.5)
  end)

  test.test("terminating a shell process also terminates its children", function()
    test.skip_if(PLATFORM == "Windows", "process groups are POSIX-specific")

    local proc = process.start(shell_command("sleep 30 & echo $!; wait"), {
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_DISCARD
    })
    test.not_nil(proc)

    local child_pid, output = nil, ""
    local start = system.get_time()
    while system.get_time() - start < 1 do
      output = output .. (proc:read_stdout(128) or "")
      child_pid = tonumber(output:match("(%d+)"))
      if child_pid then break end
    end
    test.type(child_pid, "number")

    test.not_nil(proc:terminate())
    proc:wait(1000, 0.01)

    local closed = false
    start = system.get_time()
    while system.get_time() - start < 1 do
      local check = process.start(shell_command("kill -0 " .. child_pid), {
        stdout = process.REDIRECT_DISCARD,
        stderr = process.REDIRECT_DISCARD
      })
      test.not_nil(check)
      if check:wait(process.WAIT_INFINITE, 0.01) ~= 0 then
        closed = true
        break
      end
    end
    test.ok(closed)
  end)
end)

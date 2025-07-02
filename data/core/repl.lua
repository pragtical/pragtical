local Object = require "core.object"
local linenoise_loaded, linenoise = pcall(require, "linenoise")

---@class core.repl.command
---Name of the command that user can inkove.
---@field name string
---List of params displayed on help, eg: "<param1> <param2>"
---@field params? string
---Short description of the command.
---@field description string
---Function executed when the command is requested.
---@field execute fun(cmd:string,args:table)

---@class core.repl.completion
---A lua pattern to match against the current user input.
---@field pattern string
---The function to execute if the completion pattern matches.
---@field execute fun(completions:linenoise.completion,str:string)

---An extensible REPL with multi-line and expressions evaluation.
---@class core.repl:core.object
---List of built-in commands.
---@field commands core.repl.command[]
---Set of rules to provide input completion.
---@field completions core.repl.completion[]
---Path to the file that will hold the input history.
---@field history_file string
---Maximum amount of entries on the history file.
---@field max_history integer
---@overload fun():core.repl
local REPL = Object:extend()

local register_default_commands
local register_default_completions

function REPL:new()
  self.commands = {}
  self.completions = {}
  self.history_file = USERDIR .. PATHSEP .. "repl_history"
  self.max_history = 1000
  register_default_commands(self)
  register_default_completions(self)
end

---Register a new command provider.
---@param command core.repl.command
---@return boolean? registered
---@return string? errmsg
function REPL:register_command(command)
  command.name =  "." .. command.name:gsub("^%.", "")
  for _, cmd in ipairs(self.commands) do
    if cmd.name == command.name then
      return nil, "command with same name already registered"
    end
  end
  table.insert(self.commands, command)
  return true
end

---Register a new completion provider.
---@param completion core.repl.completion
---@return boolean? registered
---@return string? errmsg
function REPL:register_completion(completion)
  for _, c in ipairs(self.completions) do
    if c.pattern == completion.pattern then
      return nil, "completion with same pattern already registered"
    end
  end
  table.insert(self.completions, completion)
  return true
end

---A basic REPL with multi-line and expression evaluation for the repl command.
function REPL:start()
  local global_mt = getmetatable(_G)
  setmetatable(_G, nil) -- disable strict global

  print("Pragtical REPL. Type 'exit' or Ctrl+D to quit.")
  print("Enter \".help\" for usage hints.")

  local buffer = ""

  -- Custom REPL commands
  local function handle_command(cmd)
    local args = {}
    for word in cmd:gmatch("%S+") do table.insert(args, word) end
    local command = args[1]
    for _, c in ipairs(self.commands) do
      if c.name == command then
        c.execute(cmd, args)
        return true
      end
    end
    return false
  end

  if linenoise_loaded then
    -- Completions handler
    linenoise.setcompletion(function(completion, str)
      for _, comp in ipairs(self.completions) do
        if str:ufind(comp.pattern) then
          comp.execute(completion, str)
          return
        end
      end
    end)

    -- linenoise.enableutf8()
    linenoise.historyload(self.history_file)
    linenoise.historysetmaxlen(self.max_history)
  end

  while true do
    local prompt = buffer == "" and "> " or ">> "
    local line
    if linenoise_loaded then
      line = linenoise.linenoise(prompt)
    else
      io.write(prompt) line = io.read()
    end
    if not line then
      print("\nBye!")
      break
    end
    if linenoise_loaded then
      linenoise.historyadd(line)
      linenoise.historysave(self.history_file)
    end
    if line:match("^%.") and buffer == "" then
      if handle_command(line) then
        buffer = ""
        goto continue
      end
    elseif line == "exit" and buffer == "" then
      break
    end

    buffer = buffer .. line .. "\n"

    local expr_chunk = load("return " .. buffer, "repl")
    if expr_chunk then
      local ok, result = pcall(expr_chunk)
      if ok and result ~= nil then
        print(result)
      elseif not ok then
        print("Error:", result)
      end
      buffer = ""
    else
      local chunk, err = load(buffer, "repl")
      if chunk then
        local ok, result = pcall(chunk)
        if ok and result ~= nil then
          print(result)
        elseif not ok then
          print("Error:", result)
        end
        buffer = ""
      elseif err and err:match("<eof>") then
        -- Waiting for more input
      else
        print("Syntax error:", err)
        buffer = ""
      end
    end
    ::continue::
  end

  setmetatable(_G, global_mt)
end

---Register a set of default commands.
---@param self core.repl
register_default_commands = function(self)
  self:register_command {
    name = "help",
    description = "Show this help message",
    execute = function()
      print "Available REPL commands:\n"
      for _, cmd in ipairs(self.commands) do
        print (
          "  " .. cmd.name
          .. (cmd.params and " " .. cmd.params or "")
          .. "  "
          .. cmd.description
        )
      end
    end
  }

  if linenoise_loaded then
    self:register_command {
      name = "clear",
      description = "Clean the screen",
      execute = function()
        linenoise.clearscreen()
      end
    }
  end

  self:register_command {
    name = "dump",
    description = "Print current global variables",
    execute = function()
      print("Current globals:")
      for k, v in pairs(_G) do
        if type(k) == "string" and not k:match("^_") and k ~= "_G" then
          local valtype = type(v)
          if valtype == "string" then
            print(k .. ' = "' .. v .. '"')
          elseif valtype == "number" or valtype == "boolean" then
            print(k .. " = " .. tostring(v))
          elseif valtype == "function" then
            print(k .. " = function(...) end")
          else
            print(k .. " = [" .. valtype .. "]")
          end
        end
      end
    end
  }

  self:register_command {
    name = "load",
    params = "<file>",
    description = "Run a Lua file in current REPL environment",
    execute = function(cmd, args)
      if args[2] then
        local path = cmd:match("^%.load%s+(.+)$")
        local chunk, err = loadfile(path)
        if chunk then
          local ok, result = pcall(chunk)
          if not ok then
            print("Error running file:", result)
          end
        else
          print("Failed to load file:", err)
        end
        return
      end
      print("Error: no file provided")
    end
  }

  self:register_command {
    name = "time",
    params = "<code>",
    description = "Time how long it takes to run a line of code",
    execute = function(cmd, args)
      if args[2] then
        local code = cmd:match("^%.time%s+(.+)$")
        local chunk = load("return " .. code, "repl")
        if not chunk then
          chunk = load(code, "repl")
        end
        if chunk then
          local start = os.clock()
          local ok, result = pcall(chunk)
          local finish = os.clock()
          if ok and result ~= nil then
            print(result)
          elseif not ok then
            print("Error:", result)
          end
          print(string.format("Time: %.6f seconds", finish - start))
        else
          print("Invalid code passed to .time")
        end
        return
      end
      print("Error: no code provided")
    end
  }

  self:register_command {
    name = "edit",
    description = "Open editor to write a Lua snippet interactively",
    execute = function()
      local core = require "core"
      local tempfile = core.temp_filename(".lua")

      local editor = "\""..EXEFILE.."\" edit"
      if PLATFORM == "Windows" then
        editor = "\""..(EXEFILE:gsub("%.com$", ".exe")).."\" edit"
      end

      local answer
      local prompt = "Use the editor on EDITOR envar? [y/N]: "
      if linenoise_loaded then
        answer = linenoise.linenoise(prompt)
      else
        io.write(prompt) answer = io.read()
      end
      if regex.match("(y|Y|yes)", answer or "") then
        local ed = os.getenv("EDITOR")
        if ed then
          editor = ed
        elseif PLATFORM == "Windows" then
          editor = "notepad"
        end
      end

      -- Create temporary file
      local file = io.open(tempfile, "w+")
      if file then
        file:write("")
        file:close()
      end

      -- Run editor
      os.execute(string.format('%s "%s"', editor, tempfile))

      -- Read edited contents
      file = io.open(tempfile, "r")
      if file then
        local code = file:read("*a")
        file:close()
        os.remove(tempfile)

        local chunk, err = load(code, "edited_snippet")
        if chunk then
          local ok, result = pcall(chunk)
          if ok and result ~= nil then
            print(result)
          elseif not ok then
            print("Error:", result)
          end
        else
          print("Syntax error in edited code:", err)
        end
      else
        print("Failed to read temporary file.")
      end
    end
  }

  self:register_command {
    name = "exit",
    description = "Exit the REPL",
    execute = function()
      os.exit()
    end
  }
end

---Register default completion providers.
---@param self core.repl
register_default_completions = function(self)
  -- built-in command
  self:register_completion {
    pattern = "^%.[%w]*",
    execute = function(completion, str)
      local cmd = str:umatch("^%.[%w]*")
      local cmds = {}
      for _, bc in ipairs(self.commands) do
        table.insert(cmds, bc.name)
      end
      for _, c in ipairs(cmds) do
        if c:ufind("^%"..cmd) then
          completion:add(c)
        end
      end
    end
  }

  -- unnamed field or member access
  self:register_completion {
    pattern = "^[%a_][%w_]*[%.:]$",
    execute = function(completion, str)
      local symbol, sep = str:umatch("([%a_][%w_]*)([%.:])")
      local sym = _G[symbol]
      if sym and (type(sym) == "table" or type(sym) == "string") then
        if type(sym) == "string" then sym = string end
        for k, _ in pairs(sym) do
          completion:add(symbol..sep..k)
        end
      end
    end
  }

  -- named field or member access
  self:register_completion {
    pattern = "^[%a_][%w_]*[%.:][%a_][%w_]*$",
    execute = function (completion, str)
      local symbol, sep, field = str:umatch("([%a_][%w_]*)([%.:])([%a_][%w_]*)")
      local sym = _G[symbol]
      if sym and (type(sym) == "table" or type(sym) == "string") then
        if type(sym) == "string" then sym = string end
        for k, _ in pairs(sym) do
          if k:ufind("^"..field) then
            completion:add(symbol..sep..k)
          end
        end
      end
    end
  }

  -- symbol with space, (, [ or { at start
  self:register_completion {
    pattern = "[%s%(%[%{][%a_][%w_]*$",
    execute = function(completion, str)
      local symbol = str:umatch("[%s%(%[%{]([%a_][%w_]*)$")
      str = str:sub(1, #str - #symbol)
      for k, _ in pairs(_G) do
        if k:ufind("^"..symbol) then
          completion:add(str .. k)
        end
      end
    end
  }

  -- no input or global symbol
  self:register_completion {
    pattern = "^[%a_]*[%w_]*$",
    execute = function(completion, str)
      local symbol = str:umatch("[%a_][%w_]*")
      for k, _ in pairs(_G) do
        if symbol then
          if k:ufind("^"..symbol) then
            completion:add(k)
          end
        else
          completion:add(k)
        end
      end
    end
  }
end


return REPL

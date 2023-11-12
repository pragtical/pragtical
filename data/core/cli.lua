local core = "core"

---@alias core.cli.flag_type
---|>'"empty"'   # Does not needs a value
---| '"number"'  # A numerical value
---| '"string"'  # Any string value
---| '"boolean"' # 0,1,false,true
---| '"list"'    # Comma separated values

---Representation of a command line flag.
---@class core.cli.flag
---Long name of the flag eg: my-flag for --my-flag
---@field name string
---Short name eg: m for -m
---@field short_name string
---Description used for the flag when running `app help mycommand`
---@field description string
---Data type of the flag if an argument/value can be given to it
---@field type? core.cli.flag_type
---Value assigned to the flag
---@field value? number|string|boolean|table

---Representation of a command line subcommand.
---@class core.cli.command
---Subcommand name invoked with `app mycommand`
---@field command string
---Description used for the command when running `app help`
---@field description string
---Optional more detailed description that shows how to use the command
---@field long_description? string
---Description of the arguments printed on command help.
---@field arguments? table<string,string>
---Single line brief of using the command, eg: [options] [<argument>]
---@field usage? string
---The minimum amount of arguments required for the command
---@field min_arguments? integer
---The maximum amount of arguments required for the command where -1 is any
---@field max_arguments? integer
---Flag true by default which causes the editor to not launch when command is executed
---@field exit_editor? boolean
---Optional list of flags that can be used as part of the command
---@field flags? core.cli.flag[]
---Optional list of subcommands that belong to the parent subcommand
---@field subcommands? core.cli.command[]
---Function called when the command is invoked by the user
---@field execute? fun(flags:core.cli.flag[], arguments:string[])

---Provides the CLI parser functionality.
---@class core.cli
---Application name
---@field app_name string
---Application version
---@field app_version string
---Application description
---@field app_description string
---List of registered commands
---@field commands table<string,core.cli.command>
local cli = {
  app_name = "Pragtical",
  app_version = VERSION,
  app_description = "The practical and pragmatic code editor.",
  commands = {},
  commands_count = 0
}

---Add a new command to the cli parser.
---@param command core.cli.command
---@param overwrite? boolean
function cli.register(command, overwrite)
  if not cli.commands[command.command] or overwrite then
    cli.commands[command.command] = command
    cli.commands_count = cli.commands_count + 1
  elseif core.error then
    core.error("CLI command '%s' already registered", command.command)
  else
    print(string.format("CLI command '%s' already registered", command.command))
    os.exit(1)
  end
end

---Removes an existing command from the cli parser.
---@param command string
function cli.unregister(command)
  if cli.commands[command] then
    cli.commands[command] = nil
    cli.commands_count = cli.commands_count - 1
  end
end

---Get the default command used by the CLI parser.
---@return core.cli.command?
function cli.get_default()
  return cli.commands.default
end

---Set the default command used by the CLI parser.
---@param command core.cli.command
function cli.set_default(command)
  command.command = "default"
  command.exit_editor = false
  cli.commands.default = command
end

---Adds color to given text on non windows systems.
---@param text string
---@param color "red" | "green" | "yellow" | "purple" | "blue" | "liteblue" | "gray"
---@return string colorized_text
function cli.colorize(text, color)
  if os.getenv("SHELL") or PLATFORM ~= "Windows" then
    if color == "green" then
      return "\27[92m"..text.."\27[0m"
    elseif color == "red" then
      return "\27[91m"..text.."\27[0m"
    elseif color == "yellow" then
      return "\27[93m"..text.."\27[0m"
    elseif color == "purple" then
      return "\27[90m"..text.."\27[0m"
    elseif color == "blue" then
      return "\27[94m"..text.."\27[0m"
    elseif color == "liteblue" then
      return "\27[96m"..text.."\27[0m"
    elseif color == "gray" then
      return "\27[97m"..text.."\27[0m"
    end
  end
  return text
end

---Print the help message for a given command name.
---@param command core.cli.command
local function print_command_help(command)
  if command.command ~= "default" then
    if command.description then
      print ""
      print(cli.colorize("Description:", "yellow"))
      print("  " .. command.description)
    end

    print ""
    print(cli.colorize("Usage:", "yellow"))
    if command.usage then
      print ("  " .. command.command .. " " .. command.usage)
    else
      print (
        "  " .. command.command .. " [options] "
        .. (
          (not command.max_arguments or command.max_arguments > 0)
          and
          "[<arguments>]" or ""
        )
      )
    end

    if command.arguments then
      print ""
      print(cli.colorize("Arguments:", "yellow"))
      for arg_name, arg_desc in pairs(command.arguments) do
        print("  " .. cli.colorize(arg_name, "green") .. " - " .. arg_desc)
      end
    end
  end

  if command.flags and #command.flags > 0 then
    print ""
    print(cli.colorize("Options:", "yellow"))
    for _, flag in ipairs(command.flags) do
      local text = cli.colorize(
          "  -" .. flag.short_name .. ", " .. "--" .. flag.name, "green"
        ) .. "  " .. (flag.description or "")
      print(text)
    end
    if command.command == "default" then
      print(
        cli.colorize("  --", "green")
        .. "  Always treat argument as command even if a file/dir"
      )
      print "      exists with the same name, eg: pragtical -- help"
    end
  end

  if command.subcommands then
    print ""
    print(cli.colorize("Available subcommands:", "yellow"))
    for _, subcommand in pairs(command.subcommands) do
      local text = cli.colorize("  " .. subcommand.command, "green")
        .. "  " .. (subcommand.description or "")
      print(text)
    end
  end

  if command.long_description then
    print ""
    print(cli.colorize("Help:", "yellow"))
    print("  " .. command.long_description:gsub("\n", "\n  "))
  end
end

---Display the generated application help or a specific command help.
---@param command core.cli.command?
function cli.print_help(command)
  if not command then
    -- ASCII Art generated with:
    -- https://patorjk.com/software/taag/#p=display&f=Big&t=Pragtical
    print [[ _____                 _   _           _ ]]
    print [[|  __ \               | | (_)         | |]]
    print [[| |__) | __ __ _  __ _| |_ _  ___ __ _| |]]
    print [[|  ___/ '__/ _` |/ _` | __| |/ __/ _` | |]]
    print [[| |   | | | (_| | (_| | |_| | (_| (_| | |]]
    print [[|_|   |_|  \__,_|\__, |\__|_|\___\__,_|_|]]
    print [[                  __/ |                  ]]
    print [[                 |___/   ]]
    print(
      cli.colorize(cli.app_name, "green")
      .. " "
      .. cli.colorize("v" .. cli.app_version, "yellow")
    )
    print(cli.colorize(cli.app_description, "blue"))
    print ""
    print(cli.colorize("Usage:", "yellow"))
    print("  " .. cli.app_name .. " [options] " .. "[arguments]")

    if cli.commands.default then
      print_command_help(cli.commands.default)

      if cli.commands_count > 0 then
        print ""
        print(cli.colorize("Available commands:", "yellow"))
        for cmdname, command_data in pairs(cli.commands) do
          if cmdname ~= "default" then
            local text = cli.colorize("  " .. cmdname, "green")
              .. "  " .. (command_data.description or "")
            print(text)
          end
        end
      end
    end
  else
    print_command_help(command)
  end

  os.exit()
end

---Execute the given command if registered.
---@param command core.cli.command
---@param flags core.cli.flag[]
---@param arguments string[]
local function execute_command(command, flags, arguments)
  if command then
    if command.min_arguments and command.min_arguments > #arguments then
      print(cli.colorize(
        string.format(
          "Given amount of arguments for '%s' is less than required.",
          command.command
        ),
        "red"
      ))
      os.exit(1)
    elseif command.max_arguments and command.max_arguments < #arguments then
      print(cli.colorize(
        string.format(
          "Given amount of arguments for '%s' is larger than required.",
          command.command
        ),
        "red"
      ))
      os.exit(1)
    end
    if command.execute then command.execute(flags, arguments) end
    if command.exit_editor or type(command.exit_editor) == "nil" then
      os.exit()
    end
    return true
  end
  return false
end

---Parse the command line arguments and execute the applicable commands.
---@param args string[]
function cli.parse(args)
  args = table.pack(table.unpack(args))

  -- on macOS we can get an argument like "-psn_0_52353" so we strip it.
  local args_removed = 0
  for i = 2, #args do
    if args[i-args_removed]:match("^-psn") then
      table.remove(args, i-args_removed)
      args_removed = args_removed + 1
    end
  end

  local cmd = cli.commands.default
  local in_subcommand = false
  local explicit_command = false

  ---@type core.cli.flag[]
  local flags_list = {}
  ---@type string[]
  local arguments_list = {}

  local skip_flags = 0;
  for i=2, #args do
    local argument = args[i+skip_flags]
    if not argument then break end
    -- parse flags
    local flag_type, flag = argument:match("^(%-%-?)(%w.*)")
    if flag_type then
      ---@type core.cli.flag?
      local flag_found, flag_value
      if cmd.flags then
        for _, flag_data in ipairs(cmd.flags) do
          if #flag_type == 1 and flag == flag_data.short_name then
            flag_found = flag_data
            break
          elseif #flag_type == 2 then
            if flag:match(".*=.*") then
              flag, flag_value = flag:match("(.*)=(.*)")
            end
            if flag == flag_data.name then
              flag_found = flag_data
              break
            end
          end
        end
      end
      if flag_found then
        local flag_error
        if flag_found.type ~= "empty" and flag_found.type then
          if not flag_value then
            flag_value = args[i+1]
            skip_flags = skip_flags + 1
          end
          if flag_found.type == "number" then
            flag_found.value = nil
            if flag_value:match("^%d[%.%d]*$") then
              flag_found.value = tonumber(flag_value) or 0
            end
            if not flag_found.value then
              flag_error = "Invalid number provided"
            end
          elseif flag_found.type == "boolean" then
            if flag_value:match("^[0-1]$") then
              flag_found.value = tonumber(flag_value) > 0 and true or false
            elseif flag_value:match("^true$") then
              flag_found.value = true
            elseif flag_value:match("^false$") then
              flag_found.value = false
            else
              flag_error = "Invalid boolean value provided\n"
                .. "Valid values are: 0, 1, false or true"
            end
          elseif flag_found.type == "list" then
            flag_found.value = {}
            for match in (flag_value..","):gmatch("(.-)"..",") do
              table.insert(flag_found.value, match);
            end
          else
            flag_found.value = tostring(flag_value)
          end
        end
        if flag_error then
          print(cli.colorize("Error when parsing flag '"..argument.."'", "red"))
          print(flag_error)
          os.exit(1)
        else
          table.insert(flags_list, flag_found)
        end
      else
        print(cli.colorize("Invalid flag '" .. argument .. "' given", "red"))
        os.exit(1)
      end
    -- Toggle explicit command treatment
    elseif argument == "--" then
      explicit_command = not explicit_command
    -- parse subcommands and arguments
    else
      local command_found = false
      local commands = in_subcommand and cmd.subcommands or cli.commands
      local argument_skip = false
      if commands and (cmd.command == "default" or in_subcommand) then
        for _, command in pairs(commands) do
          if argument == command.command and cmd.command ~= command.command then
            local abs_path = system.absolute_path(command.command)
            if
              not explicit_command and abs_path
              and
              system.get_file_info(abs_path)
            then
              argument_skip = true
              break
            end
            if
              (#flags_list > 0 or #arguments_list > 0)
              and
              execute_command(cmd, flags_list, arguments_list)
            then
              flags_list = {}
              arguments_list = {}
            end
            cmd = command
            command_found = true
            break
          end
        end
      end

      if not command_found and not argument_skip then
        if cmd.subcommands then
          for _, command in pairs(cmd.subcommands) do
            if command.command == argument and cmd.command ~= command.command then
              cmd = command
              command_found = true
              in_subcommand = true
              break
            end
          end
        end
        if not command_found then
          table.insert(arguments_list, argument)
        end
      end
    end
  end

  execute_command(cmd, flags_list, arguments_list)
end

-- Register default command
cli.set_default {
  flags = {
    {
      name = "help",
      short_name = "h",
      description = "Display help text"
    },
    {
      name = "version",
      short_name = "v",
      description = "Display application version"
    }
  },
  execute = function(flags, arguments)
    for _, flag in ipairs(flags) do
      if flag.name == "help" then
        cli.print_help()
      elseif flag.name == "version" then
        print(cli.app_version)
        os.exit()
      end
    end
  end
}

-- Register help command
cli.register {
  command = "help",
  description = "Display the application or a command help.",
  usage = "[<command_name>]",
  long_description = "The help command displays help for a given command, eg:"
    .. "\n\n"
    .. cli.colorize("  pragtical help help", "green")
    .. "\n\n"
    .. "To view all commands use the `list` command:"
    .. "\n\n"
    .. cli.colorize("  pragtical list", "green"),
  arguments = {
    command_name = "Name of specific command to print its help"
  },
  execute = function(_, arguments)
    if #arguments > 0 then
      local cmd = cli.commands[arguments[1]]
      local command_name = arguments[1]
      for i=2, #arguments do
        command_name = command_name .. " " .. arguments[i]
        if cmd and cmd.subcommands then
          local subcommand_found = false
          for _, subcommand in pairs(cmd.subcommands) do
            if subcommand.command == arguments[i] then
              subcommand_found = true
              cmd = subcommand
            end
          end
          if not subcommand_found then
            cmd = nil
            break
          end
        else
          cmd = nil
          break
        end
      end
      local label = #arguments == 1 and "Command" or "Subcommand"
      if cmd then
        print(
          cli.colorize(label .. ":", "yellow")
          .. " "
          .. cli.colorize(command_name, "green")
        )
        cli.print_help(cmd)
      else
        print(
          cli.colorize(
            label .. " '" .. command_name .. "' is not defined.", "red"
          )
        )
        os.exit(1)
      end
    end
    cli.print_help()
  end
}

-- Register list command
cli.register {
  command = "list",
  description = "Display a list of available commands.",
  usage = "",
  max_arguments = 0,
  execute = function()
    print(cli.colorize("Available commands:", "yellow"))
    print ""
    for cmdname, command_data in pairs(cli.commands) do
      if cmdname ~= "default" then
        local text = cli.colorize(cmdname, "green")
          .. "  " .. (command_data.description or "")
        print(text)
      end
    end
  end
}


return cli

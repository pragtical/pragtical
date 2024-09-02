-- mod-version:3
--
-- Crossplatform file based IPC system.
-- @copyright Jefferson Gonzalez <jgmdev@gmail.com>
-- @license MIT
--
local core = require "core"
local config = require "core.config"
local common = require "core.common"
local command = require "core.command"
local Object = require "core.object"
local RootView = require "core.rootview"
local settings_found, settings = pcall(require, "plugins.settings")

---The maximum amount of seconds a message will be broadcasted.
---@type integer
local MESSAGE_EXPIRATION=3

---@class config.plugins.ipc
---@field single_instance boolean
---@field dirs_instance '"new"' | '"add"' | '"change"'
config.plugins.ipc = common.merge({
  single_instance = true,
  dirs_instance = "new",
  -- The config specification used by the settings gui
  config_spec = {
    name = "Inter-process communication",
    {
      label = "Single Instance",
      description = "Run a single instance of pragtical.",
      path = "single_instance",
      type = "toggle",
      default = true
    },
    {
      label = "Directories Instance",
      description = "Control how to open directories in single instance mode.",
      path = "dirs_instance",
      type = "selection",
      default = "new",
      values = {
        {"Create a New Instance", "new"},
        {"Add to Current Instance", "add"},
        {"Change Current Instance Project Directory", "change"}
      }
    }
  }
}, config.plugins.ipc)

---@alias plugins.ipc.onmessageread fun(message: plugins.ipc.message) | nil
---@alias plugins.ipc.onreplyread fun(reply: plugins.ipc.reply) | nil
---@alias plugins.ipc.onmessage fun(message: plugins.ipc.message, reply: plugins.ipc.reply) | nil
---@alias plugins.ipc.onreply fun(reply: plugins.ipc.reply) | nil
---@alias plugins.ipc.function fun(...)

---@alias plugins.ipc.messagetype
---| '"message"'
---| '"method"'
---| '"signal"'

---@class plugins.ipc.message
---Id of the message
---@field id string
---The id of process that sent the message
---@field sender string
---Name of the message
---@field name string
---Type of message.
---@field type plugins.ipc.messagetype | string
---List with id of the instance that should receive the message.
---@field destinations table<integer,string>
---A list of named values sent to receivers.
---@field data table<string,any>
---Time in seconds when the message was sent for automatic expiration purposes.
---@field timestamp number
---Optional callback executed by the receiver when the message is read.
---@field on_read plugins.ipc.onmessageread
---Optional callback executed when a reply to the message is received.
---@field on_reply plugins.ipc.onreply
---The received replies for the message.
---@field replies plugins.ipc.reply[]

---@class plugins.ipc.reply
---Id of the message
---@field id string
---The id of process that sent the message
---@field sender string
---The id of the replier
---@field replier string
---A list of named values sent back to sender.
---@field data table<string,any>
---Time in seconds when the reply was sent for automatic expiration purposes.
---@field timestamp number
---Optional callback executed by the sender when the reply is read.
---@field on_read plugins.ipc.onreplyread

---@class plugins.ipc.instance
---Process id of the instance.
---@field id string
---The position in which the instance was launched.
---@field position integer
---Flag that indicates if this instance was the first started.
---@field primary boolean
---Indicates the last time this instance updated its session file.
---@field last_update integer
---The messages been broadcasted.
---@field messages plugins.ipc.message[]
---The replies been broadcasted.
---@field replies plugins.ipc.reply[]
---Table of properties associated with the instance. (NOT IMPLEMENTED)
---@field properties table

---@class plugins.ipc : core.object
---@field protected id string
---@field protected user_dir string
---@field protected running boolean
---@field protected file string
---@field protected shmem shmem?
---@field protected primary boolean
---@field protected position integer
---@field protected messages plugins.ipc.message[]
---@field protected replies plugins.ipc.reply[]
---@field protected listeners table<string,table<integer,plugins.ipc.onmessage>>
---@field protected signals table<string,integer>
---@field protected methods table<string,integer>
---@field protected next_update integer
---@field protected last_output string
---@field protected signal_definitions table<integer,string>
---@field protected method_definitions table<integer,string>
local IPC = Object:extend()

---Constructor
---@param id? string Defaults to current pragtical process id.
function IPC:new(id)
  self.id = id or tostring(system.get_process_id())
  self.user_dir = USERDIR .. "/ipc"
  self.file = self.user_dir .. "/" .. self.id .. ".lua"
  self.shmem = package.loaded["shmem"] and shmem.open("pragtical-ipc", 100) or nil
  self.primary = false
  self.running = false
  self.messages = {}
  self.replies = {}
  self.listeners = {}
  self.signals = {}
  self.methods = {}
  self.signal_definitions = {}
  self.method_definitions = {}
  self.next_update = 0
  self.last_output = ""

  if not self.shmem then
    local ipc_dir_status = system.get_file_info(self.user_dir)

    if not ipc_dir_status then
      local created, errmsg = common.mkdirp(self.user_dir)
      if not created then
        core.error("Error initializing IPC system: %s", errmsg)
        return
      end
    end

    local file, errmsg = io.open(self.file, "w+")

    if not file then
      core.error("Error initializing IPC system: %s", errmsg)
      return
    else
      file:close()
      os.remove(self.file)
    end
  end

  -- Execute to set the instance position and primary attribute if no other running.
  local instances = self:get_instances()
  self.primary = #instances == 0 and true or false
  self.position = #instances + 1

  self:start()
end

---Updates the session status of an IPC object.
function IPC:update_status()
  local output = "-- Warning: Generated by IPC system do not edit manually!\n"
    .. "return " .. common.serialize(
    {
      id = self.id,
      primary = self.primary,
      position = self.position,
      last_update = os.time(),
      messages = self.messages,
      replies = self.replies,
      signals = self.signal_definitions,
      methods = self.method_definitions
    },
    {
      sort = true,
      pretty = true
    }
  )

  output = output:gsub("%s+%[\"on_reply\"%].-\n", "")

  if not self.shmem then
    local update = false
    local new_output = output:gsub("%s+%[\"last_update\"%].-\n", "")

    if self.last_output ~= new_output or self.next_update < os.time() then
      update = true
      self.next_update = os.time() + 4
      self.last_output = new_output
    end

    if update then
      local file, errmsg = io.open(self.file, "w+")
      if file then
        file:write(output)
        file:close()
      else
        core.error("IPC Error: failed updating status (%s)", errmsg)
      end
    end
  else
    self.shmem:set(self.id, output)
  end
end

---Starts and registers the ipc session and monitoring.
function IPC:start()
  if not self.running then
    self.running = true

    self:update_status()

    local wait_time = 0.25

    self.coroutine_key = core.add_background_thread(function()
      coroutine.yield(wait_time)
      while(self.running) do
        self:read_messages()
        self:read_replies()
        self:update_status()
        coroutine.yield(wait_time)
      end
    end)
  end
end

---Stop and unregister the ipc session and monitoring.
function IPC:stop()
  self.running = false
  if not self.shmem then
    os.remove(self.file)
  else
    self.shmem:remove(self.id)
  end
end

---Get a list of running pragtical instances.
---@return plugins.ipc.instance[]
function IPC:get_instances()
  ---@type plugins.ipc.instance[]
  local instances = {}

  if not self.shmem then
    local files, errmsg = system.list_dir(self.user_dir)

    if files then
      for _, file in ipairs(files) do
        if string.match(file, "^%d+%.lua$") then
          local path = self.user_dir .. "/" .. file
          local file_info = system.get_file_info(path)
          if file_info and file_info.type == "file" then
            ::read_instance_file::
            ---@type plugins.ipc.instance
            local instance = dofile(path)
            if instance and instance.id ~= self.id then
              if instance.last_update + 5 > os.time() then
                table.insert(instances, instance)
              else
                -- Delete expired instance session maybe result of a crash
                os.remove(path)
              end
            elseif not instance and path ~= self.file then
              --We retry reading the file since it was been modified
              --by its owner instance.
              goto read_instance_file
            end
          end
        end
      end
    else
      core.error("IPC Error: failed getting running instances (%s)", errmsg)
    end
  else
    for id, status in pairs(self.shmem) do
      local status_func = load(status)
      if status_func then
        ---@type plugins.ipc.instance
        local instance = status_func()
        if instance and instance.id ~= self.id then
          if instance.last_update + 2 > os.time() then
            table.insert(instances, instance)
          else
            -- Delete expired instance session maybe result of a crash
            self.shmem:remove(id)
          end
        end
      end
    end
  end

  local instances_count = #instances

  if instances_count > 0 then
    table.sort(instances, function(ia, ib)
      return ia.position < ib.position
    end)
  end

  if not self.primary and self.position then
    if instances_count == 0 or instances[1].position > self.position then
      self.primary = true
    end
  end

  return instances
end

---@class plugins.ipc.vardecl
---@field name string
---@field type string
---@field optional boolean

---Generate a string representation of a function
---@param name string
---@param params? plugins.ipc.vardecl[]
---@param returns? plugins.ipc.vardecl[]
---@return string function_definition
local function generate_definition(name, params, returns)
  local declaration = name .. "("

  if params and #params > 0 then
    local params_string = ""
    for _, param in ipairs(params) do
      params_string = params_string .. param.name
      if param.optional then
        params_string = params_string .. "?: "
      else
        params_string = params_string .. ": "
      end
      params_string = params_string .. param.type .. ", "
    end
    local params_stripped = params_string:gsub(", $", "")
    declaration = declaration .. params_stripped
  end

  declaration = declaration .. ")"

  if returns and #returns > 0 then
    declaration = declaration .. " -> "
    local returns_string = ""
    for _, ret in ipairs(returns) do
      if ret.name then
        returns_string = returns_string .. ret.name .. ": "
      end
      returns_string = returns_string .. ret.type
      if ret.optional then
        returns_string = returns_string .. "?, "
      else
        returns_string = returns_string .. ", "
      end
    end
    local returns_stripped = returns_string:gsub(", $", "")
    declaration = declaration .. returns_stripped
  end

  return declaration
end

---Retrieve the id of the primary instance if found.
---@return string | nil
function IPC:get_primary_instance()
  local instances = self:get_instances()
  for _, instance in ipairs(instances) do
    if instance.primary then
      return instance.id
    end
  end
  return nil
end

---Get a queued message.
---@param message_id string
---@return plugins.ipc.message | nil
function IPC:get_message(message_id)
  for _, message in ipairs(self.messages) do
    if message.id == message_id then
      return message
    end
  end
  return nil
end

---Remove a message from the queue.
---@param message_id string
function IPC:remove_message(message_id)
  for m, message in ipairs(self.messages) do
    if message.id == message_id then
      table.remove(self.messages, m)
      break
    end
  end
end

---Get the reply sent to a specific message.
---@param message_id string
---@return plugins.ipc.reply | nil
function IPC:get_reply(message_id)
  for _, reply in ipairs(self.replies) do
    if reply.id == message_id then
      return reply
    end
  end
  return nil
end

---Verify all the messages sent by running instances, read those directed
---to the currently running instance and reply to them.
function IPC:read_messages()
  local instances = self:get_instances()

  local awaiting_replies = {}

  for _, instance in ipairs(instances) do
    for _, message in ipairs(instance.messages) do
      for _, destination in ipairs(message.destinations) do
        if destination == self.id then
          local reply = self:get_reply(message.id)

          if not reply then
            if message.on_read then
              local on_read, errmsg = load(message.on_read)
              if on_read then
                local executed = core.try(function() on_read(message) end)
                if not executed then
                  core.error(
                    "IPC Error: could not run message on_read\n"
                      .. "Message: %s\n",
                    common.serialize(message, {pretty = true})
                  )
                end
              else
                core.error(
                  "IPC Error: could not run message on_read (%s)\n"
                    .. "Message: %s\n",
                  errmsg,
                  common.serialize(message, {pretty = true})
                )
              end
            end

            ---@type plugins.ipc.reply
            reply = {}
            reply.id = message.id
            reply.sender = message.sender
            reply.replier = self.id
            reply.data = {}
            reply.on_read = nil

            local type_name = message.type .. "." .. message.name

            -- Allow listeners to react to message and modify reply
            if self.listeners[type_name] and #self.listeners[type_name] > 0 then
              for _, on_message in ipairs(self.listeners[type_name]) do
                on_message(message, reply)
              end
            end

            if reply.on_read then
              reply.on_read = string.dump(reply.on_read)
            end

            reply.timestamp = os.time()
          end

          table.insert(awaiting_replies, reply)
          break
        end
      end
    end
  end

  self.replies = awaiting_replies
end

---Reads replies directed to messages sent by the currently running instance
---and if any returns them.
---@return plugins.ipc.reply[] | nil
function IPC:read_replies()
  if #self.messages == 0 then
    return
  end

  local instances = self:get_instances()

  local replies = {}

  local messages_removed = 0;
  for m=1, #self.messages do
    local message = self.messages[m-messages_removed]
    local message_removed = false

    local destinations_removed = 0
    for d=1, #message.destinations do
      local destination = message.destinations[d-destinations_removed]

      local found = false
      for _, instance in ipairs(instances) do
        if instance.id == destination then
          found = true
          for _, reply in ipairs(instance.replies) do
            if reply.id == message.id then
              local reply_registered = false
              for _, message_reply in ipairs(message.replies) do
                if message_reply.replier == instance.id then
                  reply_registered = true
                  break
                end
              end
              if not reply_registered then
                if message.on_reply then
                  message.on_reply(reply)
                end

                if reply.on_read then
                  local on_read, errmsg = load(reply.on_read)
                  if on_read then
                    local executed = core.try(function() on_read(reply) end)
                    if not executed then
                      core.error(
                        "IPC Error: could not run reply on_read\n"
                          .. "Message: %s\n"
                          .. "Reply: %s",
                        common.serialize(message, {pretty = true}),
                        common.serialize(reply, {pretty = true})
                      )
                    end
                  else
                    core.error(
                      "IPC Error: could not run reply on_read (%s)\n"
                        .. "Message: %s\n"
                        .. "Reply: %s",
                      errmsg,
                      common.serialize(message, {pretty = true}),
                      common.serialize(reply, {pretty = true})
                    )
                  end
                end

                table.insert(replies, reply)
                table.insert(message.replies, reply)
              end
            end
          end
          break
        end
      end
      if not found then
        table.remove(message.destinations, d-destinations_removed)
        destinations_removed = destinations_removed + 1
        if #message.destinations == 0 then
          table.remove(self.messages, m-messages_removed)
          messages_removed = messages_removed + 1
          message_removed = true
        end
      end
    end
    if
      not message_removed
      and
      (
        #message.replies == #message.destinations
        or
        message.timestamp + MESSAGE_EXPIRATION < os.time()
      )
    then
      table.remove(self.messages, m-messages_removed)
      messages_removed = messages_removed + 1
    end
  end

  return replies
end

---Blocks execution of current instance to wait for all replies by the
---specified message and when finished returns them.
---@param message_id string
---@return plugins.ipc.reply[] | nil
function IPC:wait_for_replies(message_id)
  local message_data = self:get_message(message_id)

  self:update_status()

  if message_data then
    self:read_replies()
    while true do
      if
        message_data.replies
        and
        #message_data.replies == #message_data.destinations
      then
        return message_data.replies
      elseif not self:get_message(message_id) then
        return message_data.replies
      end
      self:read_replies()
    end
  end
  return nil
end

---Blocks execution of current instance to wait for all messages to
---be replied to.
function IPC:wait_for_messages()
  self:update_status()
  while #self.messages > 0 do
    self:read_replies()
    system.sleep(0.1)
  end
end

---@class plugins.ipc.sendmessageoptions
---@field data table<string,any> @Optional data given to the receiver.
---@field on_reply plugins.ipc.onreply @Callback that allows monitoring all the replies received for this message.
---@field on_read plugins.ipc.onmessage @Function executed by the message receiver.
---@field destinations string | table<integer,string> | nil @Id of the running instances to receive the message, if not set all running instances will receive the message.

---Queue a new message to be sent to other pragtical instances.
---@param name string
---@param options? plugins.ipc.sendmessageoptions
---@param message_type? plugins.ipc.messagetype
---@return string | nil message_id
function IPC:send_message(name, options, message_type)
  options = options or {}

  local found_destinations = {}
  local instances = self:get_instances()
  local destinations = options.destinations

  if type(destinations) == "string" then
    destinations = { destinations }
  end

  if not destinations then
    for _, instance in ipairs(instances) do
      table.insert(found_destinations, instance.id)
    end
  else
      for _, destination in ipairs(destinations) do
        for _, instance in ipairs(instances) do
          if instance.id == destination then
            table.insert(found_destinations, destination)
          end
        end
      end
  end

  if #found_destinations <= 0 then
    return nil
  end

  ---@type plugins.ipc.message
  local message = {}
  message.id = self.id .. "." .. tostring(system.get_time())
  message.name = name
  message.type = message_type or "message"
  message.sender = self.id
  message.data = options.data or {}
  message.destinations = found_destinations
  message.timestamp = os.time()
  message.on_reply = options.on_reply or nil
  message.on_read = options.on_read and string.dump(options.on_read) or nil
  message.replies = {}

  table.insert(self.messages, message)

  self:update_status()

  return message.id
end

---Add a listener for a given type of message.
---@param name string
---@param callback plugins.ipc.onmessage
---@param message_type? plugins.ipc.messagetype
---@return integer listener_position
function IPC:listen_message(name, callback, message_type)
  message_type = message_type or "message"

  local type_name = message_type .. "." .. name
  if not self.listeners[type_name] then
    self.listeners[type_name] = {}
  end

  table.insert(self.listeners[type_name], callback)

  return #self.listeners[type_name]
end

---Listen for a given signal.
---@param name string
---@param callback plugins.ipc.function
---@return integer listener_position
function IPC:listen_signal(name, callback)
  local signal_cb = function(message)
    callback(table.unpack(message.data))
  end
  return self:listen_message(name, signal_cb, "signal")
end

---Add a new signal that can be sent to other instances.
---@param name string A unique name for the signal.
---@param params? plugins.ipc.vardecl[] Parameters that are going to be passed into callback.
function IPC:register_signal(name, params)
  if self.signals[name] then
    core.log_quiet("IPC: Overriding signal '%s'", name)
    table.remove(self.signal_definitions, self.signals[name])
  end

  self.signals[name] = table.insert(
    self.signal_definitions,
    generate_definition(name, params)
  )

  table.sort(self.signal_definitions)
end

---Add a new method that can be invoked from other instances.
---@param name string A unique name for the method.
---@param method fun(...) Function invoked when the method is called.
---@param params? plugins.ipc.vardecl[] Parameters that are going to be passed into method.
---@param returns? plugins.ipc.vardecl[] Return values of the method.
function IPC:register_method(name, method, params, returns)
  if self.methods[name] then
    core.log_quiet("IPC: Overriding method '%s'", name)
    table.remove(self.method_definitions, self.methods[name])
  end

  self.methods[name] = table.insert(
    self.method_definitions,
    generate_definition(name, params, returns)
  )

  table.sort(self.method_definitions)

  self:listen_message(name, function(message, reply)
    local ret = table.pack(method(table.unpack(message.data)))
    reply.data = ret
  end, "method")
end

---Broadcast a signal to running instances.
---@param destinations string | table<integer, string> | nil
---@param name string
---@vararg any signal_parameters
function IPC:signal(destinations, name, ...)
  self:send_message(name, {
    destinations = destinations,
    data = table.pack(self.id, ...)
  }, "signal")
end

---Call a method on another instance and wait for reply.
---@param destinations string | table<integer, string> | nil
---@param name string
---@return any | table<string,table> return_of_called_method
function IPC:call(destinations, name, ...)
  local message_id = self:send_message(name, {
    destinations = destinations,
    data = table.pack(...)
  }, "method")

  local ret = nil

  if message_id then
    local replies = self:wait_for_replies(message_id)
    if replies and #replies > 1 then
      ret = {}
      for _, reply in ipairs(replies) do
        ret[reply.replier] = reply.data
      end
    elseif replies and #replies > 0 then
      return table.unpack(replies[1].data)
    end
  else
    core.error("IPC Error: could not make call to '%s'", name)
  end

  return ret
end

---Call a method on another instance asynchronously waiting for the replies.
---@param destinations string | table<integer, string> | nil
---@param name string
---@param callback fun(id: string, ret: table) | nil Called with the returned values
---@return string | nil message_id
function IPC:call_async(destinations, name, callback, ...)
  return self:send_message(name, {
    destinations = destinations,
    data = table.pack(...),
    on_reply = callback and function(reply)
      callback(reply.replier, reply.data)
    end or nil
  }, "method")
end

---Main ipc session for current instance.
---@type plugins.ipc
local ipc = IPC()

---Get the IPC session for the running pragtical instance.
---@return plugins.ipc
function IPC.current()
  return ipc
end

---Tell the core to force a full redraw. Should be used when receiving signals
---that execute draw operations while the window could be unfocused.
function IPC.force_draw()
  core.redraw = true
end

--------------------------------------------------------------------------------
-- Override system.show_fatal_error to be able and destroy session file on crash.
--------------------------------------------------------------------------------
local system_show_fatal_error = system.show_fatal_error

system.show_fatal_error = function(title, message)
  if title == "Pragtical internal error" then
    ipc:stop()
  end
  system_show_fatal_error(title, message)
end

--------------------------------------------------------------------------------
-- Override core.run to destroy ipc session file on exit.
--------------------------------------------------------------------------------
local core_run = core.run

core.run = function()
  core_run()
  ipc:stop()
end

--------------------------------------------------------------------------------
-- Override system.get_time temporarily as first function called on core.run
-- to allow settings gui to properly load ipc config options as signal
-- core.open_file and core.change_directory.
--------------------------------------------------------------------------------
local system_get_time = system.get_time

system.get_time = function()
  if settings_found and settings and not settings.ui then
    return system_get_time()
  end

  if config.plugins.ipc.single_instance then
    system.get_time = system_get_time

    local primary_instance = ipc:get_primary_instance()
    if primary_instance and ARGS[2] then
      local open_directory = false
      for i=2, #ARGS do
        -- chdir to initial working directory to properly resolve absolute path
        system.chdir(core.init_working_dir)
        local path = system.absolute_path(ARGS[i])

        if path then
          local path_info = system.get_file_info(path)
          if path_info then
            if path_info.type == "file" then
              ipc:call_async(primary_instance, "core.open_file", nil, path)
            else
              if config.plugins.ipc.dirs_instance == "add" then
                ipc:call_async(primary_instance, "core.open_directory", nil, path)
              elseif config.plugins.ipc.dirs_instance == "change" then
                ipc:call_async(primary_instance, "core.change_directory", nil, path)
              else
                if #ARGS > 2 then
                  system.exec(string.format("%q %q", EXEFILE, path))
                else
                  open_directory = true
                end
              end
            end
          end
        end
      end
      ipc:wait_for_messages()
      if not open_directory then
        os.exit()
      end
      -- revert chdir to core.init_working_dir
      if core.projects[1] then
        system.chdir(core.projects[1].path)
      end
    end
  else
    system.get_time = system_get_time
  end

  return system_get_time()
end

--------------------------------------------------------------------------------
-- Register methods for opening files and directories.
--------------------------------------------------------------------------------
ipc:register_method("core.open_file", function(file)
  if system.get_file_info(file) then
    system.raise_window(core.window)
    core.root_view:open_doc(core.open_doc(file))
  end
end, {{name = "file", type = "string"}})

ipc:register_method("core.open_directory", function(directory)
  if system.get_file_info(directory) then
    system.raise_window(core.window)
    core.add_project(directory)
  end
end, {{name = "directory", type = "string"}})

ipc:register_method("core.change_directory", function(directory)
  if system.get_file_info(directory) then
    system.raise_window(core.window)
    if directory == core.root_project().path then return end
    core.confirm_close_docs(core.docs, function(dirpath)
      core.open_project(dirpath)
    end, directory)
  end
end, {{name = "directory", type = "string"}})

--------------------------------------------------------------------------------
-- Register file dragging signals from instance to instance
--------------------------------------------------------------------------------
ipc:register_signal("core.tab_drag_start", {{name = "file", type = "string"}})
ipc:register_signal("core.tab_drag_stop")
ipc:register_signal("core.tab_drag_received", {{name = "file", type = "string"}})

local rootview_tab_dragging = false
local rootview_dragged_node = nil
local rootview_waiting_drop_file = ""
local rootview_waiting_drop_instance = ""

local rootview_on_mouse_moved = RootView.on_mouse_moved
function RootView:on_mouse_moved(x, y, dx, dy)
  rootview_on_mouse_moved(self, x, y, dx, dy)
  if
    self.dragged_node and self.dragged_node.dragging
    and
    not rootview_tab_dragging
  then
    ---@type core.doc
    local doc = core.active_view.doc
    if doc and doc.abs_filename then
      rootview_tab_dragging = true
      ipc:signal(nil, "core.tab_drag_start", doc.abs_filename)
      rootview_dragged_node = self.dragged_node
    end
  elseif rootview_dragged_node then
    local w, h, wx, wy = system.get_window_size(core.window)
    if x < 0 or x > w or y < 0 or y > h then
      self.dragged_node = nil
      self:set_show_overlay(self.drag_overlay, false)
    elseif not self.dragged_node then
      self.dragged_node = rootview_dragged_node
      self:set_show_overlay(self.drag_overlay, true)
    end
    core.request_cursor("hand")
  elseif rootview_waiting_drop_file ~= "" then
    ipc:signal(
      rootview_waiting_drop_instance,
      "core.tab_drag_received",
      rootview_waiting_drop_file
    )
    core.root_view:open_doc(core.open_doc(rootview_waiting_drop_file))
    rootview_waiting_drop_file = ""
    rootview_waiting_drop_instance = ""
  end
end

local rootview_on_mouse_released = RootView.on_mouse_released
function RootView:on_mouse_released(button, x, y, ...)
  rootview_on_mouse_released(self, button, x, y, ...)
  if rootview_tab_dragging then
    rootview_tab_dragging = false
    rootview_dragged_node = nil
    ipc:signal(nil, "core.tab_drag_stop")
  end
end

ipc:listen_signal("core.tab_drag_start", function(instance, file)
  rootview_waiting_drop_instance = instance
  rootview_waiting_drop_file = file
end)

ipc:listen_signal("core.tab_drag_stop", function()
  core.add_thread(function()
    coroutine.yield()
    rootview_waiting_drop_instance = ""
    rootview_waiting_drop_file = ""
  end)
end)

ipc:listen_signal("core.tab_drag_received", function()
  IPC.force_draw()
  command.perform("root:close")
end)


return IPC

---@meta

---
---Provides threading capabilities.
---Workers have independent Lua states, but belong to the editor session that
---created them, including workers created by other workers. Completed worker
---states are closed even while their Thread handles are retained.
---
---Restart and normal exit request shutdown and wait for all workers to finish
---before closing the editor state. Channel operations interrupt workers during
---shutdown. Computation and native I/O must finish or reach a channel operation;
---a worker that never does so can prevent restart. Cancellation is not a forced
---termination of native code.
---@class thread
thread = {}

---
---A thread object.
---@class thread.Thread
thread.Thread = {}

---
---A channel object.
---@class thread.Channel
thread.Channel = {}

---
---Create a new thread and starts it.
---
---@param name string
---@param callback function
---@param ...? string|boolean|number|table|nil Optional arguments passed to callback
---
---@return thread.Thread|nil
---@return string errorMessage
function thread.create(name, callback, ...) end

---
---Creates a new channel or retrieve existing one.
---Names are shared within an editor session and its descendant workers, not
---across restarts. Keep a channel handle while sending or receiving: queued
---values are discarded when the last handle is collected.
---Channel operations raise a cancellation error when the session shuts down,
---including blocked wait() and supply() calls. Workers should not suppress it.
---
---@param name string
---
---@return thread.Channel|nil
---@return string errorMessage
function thread.get_channel(name) end

---
---Get the number of CPU cores available.
---
---Returns the total number of logical CPU cores. On CPUs that include
---technologies such as hyperthreading, the number of logical cores may be
---more than the number of physical cores.
---
---@return number
function thread.get_cpu_count() end

---
---Get the id of a thread.
---
---@return integer
function thread.Thread:get_id() end

---
---Get the name assigned to a thread.
---
---@return string
function thread.Thread:get_name() end

---
---Wait for a thread to finish and get the return code.
---Also waits for the worker's Lua state to close. Repeated calls return the
---same status. Dropping a Thread handle does not cancel a running worker;
---the session retains ownership and reclaims its native resources on completion.
---
---@return integer
function thread.Thread:wait() end

---
---Metamethod to automatically compare two threads.
---
---@param thread1 thread.Thread
---@param thread2 thread.Thread
---
---@return boolean
function thread.Thread:__eq(thread1, thread2) end

---
---Metamethod that automatically converts a thread to a string representation.
---
---@return string
function thread.Thread:__tostring() end

---
---Get the first element of the list in the channel.
---
---@return string|boolean|number|table|nil
function thread.Channel:first() end

---
---Get the last element of the list in the channel.
---
---@return string|boolean|number|table|nil
function thread.Channel:last() end

---
---Add a new element to the end of a channel list.
---
---@param element string|boolean|number|table|nil
---
---@return boolean|nil
---@return string errorMessage
function thread.Channel:push(element) end

---
---Add a new element to the end of a channel list and waits for thread to read it.
---
---@param element string|boolean|number|table|nil
---
---@return boolean | nil
---@return string errorMessage
function thread.Channel:supply(element) end

---
---Remove all elements from the channel.
function thread.Channel:clear() end

---
---Remove the first element of a channel.
function thread.Channel:pop() end

---
---Wait until the channel has one element and return it.
---
---@return string|boolean|number|table|nil
function thread.Channel:wait() end

---
---Metamethod that automatically converts a channel to a string representation.
---
---@return string
function thread.Channel:__tostring() end


return thread

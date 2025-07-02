---@meta

---
---Cross-platform readline like functionality.
---
---Usage Example:
---```lua
---local line, err = repl.input(prompt)
---while line do
---  if #line > 0 then
---    repl.add_history(line)
---    repl.save_history(history) -- save every new line
---  end
---  line, err = repl.input(prompt)
---end
---if err then
---  print('An error occurred: ' .. err)
---end
---```
---@class repl
repl = {}

---
---A repl completions list object
---@class repl.completion
repl.completion = {}

---
---Add a new string to the completions list.
---@param str string
function repl.completion:add(str) end

---
---Prompts for a line of input, using prompt as the prompt string.
---Returns nil if no more input is available;
---Returns nil and an error string if an error occurred.
---@return string? line
---@return string? errmsg
function repl.input(prompt) end

---
---Adds line to the history list.
---@param line string
function repl.add_history(line) end

---
---Sets the history list size to length.
---@param length integer
function repl.set_history_max_len(length) end

---
---Saves the history list to filename.
---@param filename string
function repl.save_history(filename) end

---
---Loads the history list from filename.
---@param filename string
function repl.load_history(filename) end

---
---Clears the screen.
function repl.clear_screen() end

---
---Sets the completion callback. This callback is called with two arguments:
---
--- * A completions object. Use object:add or repl.add_completion to add a
---   completion to this object.
--- * The current line of input.
---
---Example:
---```lua
---set_completion(function(completion,str)
---  if str == 'h' then
---    completion:add('help')
---    completion:add('halt')
---  end
---end)
---```
---@param callback fun(completion:repl.completion,str:string)
function repl.set_completion(callback) end

---
---Adds string to the list of completions.
---All functions return nil on error; functions that don't have an obvious
---return value return true on success.
---@param completions repl.completion
---@param str string
function repl.add_completion(completions, str) end

---Enables multi-line mode if multiline is true, disables otherwise.
---@param multiline boolean
function repl.set_multiline(multiline) end

---Prints repl key codes. Primarly used for debugging.
function repl.print_keycodes() end

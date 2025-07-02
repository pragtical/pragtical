---@meta

---
---Cross-platform readline like functionality.
---Upstream URL: https://github.com/hoelzro/lua-linenoise
---
---Usage Example:
---```lua
---local line, err = linenoise.linenoise(prompt)
---while line do
---  if #line > 0 then
---    linenoise.historyadd(line)
---    linenoise.historysave(history) -- save every new line
---  end
---  line, err = linenoise.linenoise(prompt)
---end
---if err then
---  print('An error occurred: ' .. err)
---end
---```
---@class linenoise
linenoise = {}

---
---A linenoise completions list object
---@class linenoise.completion
linenoise.completion = {}

---
---Add a new string to the completions list.
---@param str string
function linenoise.completion:add(str) end

---
---Prompts for a line of input, using prompt as the prompt string.
---Returns nil if no more input is available;
---Returns nil and an error string if an error occurred.
---@return string? line
---@return string? errmsg
function linenoise.linenoise(prompt) end

---
---Adds line to the history list.
---@param line string
function linenoise.historyadd(line) end

---
---Sets the history list size to length.
---@param length integer
function linenoise.historysetmaxlen(length) end

---
---Saves the history list to filename.
---@param filename string
function linenoise.historysave(filename) end

---
---Loads the history list from filename.
---@param filename string
function linenoise.historyload(filename) end

---
---Clears the screen.
function linenoise.clearscreen() end

---
---Sets the completion callback. This callback is called with two arguments:
---
--- * A completions object. Use object:add or linenpise.addcompletion to add a
---   completion to this object.
--- * The current line of input.
---
---Example:
---```lua
---setcompletion(function(completion,str)
---  if str == 'h' then
---    completion:add('help')
---    completion:add('halt')
---  end
---end)
---```
---@param callback fun(completion:linenoise.completion,str:string)
function linenoise.setcompletion(callback) end

---
---Adds string to the list of completions.
---All functions return nil on error; functions that don't have an obvious
---return value return true on success.
---@param completions linenoise.completion
---@param str string
function linenoise.addcompletion(completions, str) end

---Enables multi-line mode if multiline is true, disables otherwise.
---@param multiline boolean
function linenoise.setmultiline(multiline) end

---Prints linenoise key codes. Primarly used for debugging.
function linenoise.printkeycodes() end

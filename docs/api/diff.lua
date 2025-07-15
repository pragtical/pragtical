---@meta

---
---Functionality to generate the differences between two strings.
---@class encoding
diff = {}

---@class diff.changes
---@field tag "equal" | "delete" | "insert" | "modify"
---@field a? string
---@field b? string

---
---Split a string by the given mode ready for consumption by diff.diff(...).
---@param str string
---@param mode? "char" | "line"
---@return table<integer,string>
function diff.split(str, mode) end

---
---Generates the differences between two strings.
---@param a string
---@param b string
---@return diff.changes[]
function diff.inline_diff(a, b) end

---
---Generate the differences between two tables of strings.
---@param a table<integer,string>
---@param b table<integer,string>
---@return diff.changes[]
function diff.diff(a, b) end

---
---Same as diff.diff(...) but in iterable mode.
---@param a table<integer,string>
---@param b table<integer,string>
---@return fun():diff.changes
function diff.diff_iter(a, b) end

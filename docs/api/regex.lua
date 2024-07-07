---@meta

---
---Provides the base functionality for regular expressions matching.
---@class regex
regex = {}

---Instruct regex:cmatch() to match only at the first position.
---@type integer
regex.ANCHORED = 0x80000000

---Tell regex:cmatch() that the pattern can match only at end of subject.
---@type integer
regex.ENDANCHORED = 0x20000000

---Tell regex:cmatch() that subject string is not the beginning of a line.
---@type integer
regex.NOTBOL = 0x00000001

---Tell regex:cmatch() that subject string is not the end of a line.
---@type integer
regex.NOTEOL = 0x00000002

---Tell regex:cmatch() that an empty string is not a valid match.
---@type integer
regex.NOTEMPTY = 0x00000004

---Tell regex:cmatch() that an empty string at the start of the
---subject is not a valid match.
---@type integer
regex.NOTEMPTY_ATSTART = 0x00000008

---@alias regex.modifiers
---| "i"  # Case insesitive matching
---| "m"  # Multiline matching
---| "s"  # Match all characters with dot (.) metacharacter even new lines

---
---Compiles a regular expression pattern that can be used to search in strings.
---
---@param pattern string
---@param options? regex.modifiers A string of one or more pattern modifiers.
---
---@return regex? regex Ready to use regular expression object or nil on error.
---@return string? error The error message if compiling the pattern failed.
function regex.compile(pattern, options) end

---
---Search a string for valid matches and returns a list of matching offsets.
---
---@param pattern regex|string The regex pattern to use, either as a simple string or precompiled.
---@param subject string The string to search for valid matches.
---@param offset? integer The position on the subject to start searching.
---@param options? integer A bit field of matching options, eg:
---regex.NOTBOL | regex.NOTEMPTY
---
---@return integer? ... List of offsets where a match was found.
function regex.cmatch(pattern, subject, offset, options) end

---
---Behaves like `string.find`.
---Looks for the first match of `pattern` in the string `str`.
---If it finds a match, it returns the indices of `str` where this occurrence
---starts and ends; otherwise, it returns `nil`.
---If the pattern has captures, the captured strings are returned,
---after the two indexes ones.
---If a capture is empty, its offset is returned instead.
---
---@param pattern regex|string The regex pattern to use, either as a simple string or precompiled.
---@param subject string The string to search for valid matches.
---@param offset? integer The position on the subject to start searching.
---@param options? integer A bit field of matching options, eg:
---regex.NOTBOL | regex.NOTEMPTY
---
---@return integer? start Offset where the first match was found; `nil` if no match.
---@return integer? end Offset where the first match ends; `nil` if no match.
---@return (string|integer)? ... #List of captured matches; if the match is empty, its offset is returned instead.
function regex.find(pattern, subject, offset, options) end

---
---Looks for the first match of `pattern` in the string `subject`.
---If it finds a match, it returns the indices of `subject` where this occurrence
---starts and ends; otherwise, it returns `nil`.
---If the pattern has captures, the captured start and end indexes are returned,
---after the two initial ones.
---
---@param pattern regex|string The regex pattern to use, either as a simple string or precompiled.
---@param subject string The string to search for valid matches.
---@param offset? integer The position on the subject to start searching.
---@param options? integer A bit field of matching options, eg:
---regex.NOTBOL | regex.NOTEMPTY
---
---@return integer? start Offset where the first match was found; `nil` if no match.
---@return integer? end Offset where the first match ends; `nil` if no match.
---@return integer? ... #Captured matches offsets.
function regex.find_offsets(pattern, subject, offset, options) end

---
---Returns an iterator function that, each time it is called, returns the
---next captures from `pattern` over the string subject.
---
---Example:
---```lua
---    s = "hello world hello world"
---    for hello, world in regex.gmatch("(hello)\\s+(world)", s) do
---        print(hello .. " " .. world)
---    end
---```
---
---@param pattern regex|string The regex pattern to use, either as a simple string or precompiled.
---@param subject string
---@param offset? integer
---
---@return fun():string, ...
function regex.gmatch(pattern, subject, offset) end

---
---Replaces the matched pattern globally on the subject with the given
---replacement, supports named captures ((?'name'<pattern>), ${name}) and
---$[1-9][0-9]* substitutions. Raises an error when failing to compile the
---pattern or by a substitution mistake.
---
---@param pattern regex|string The regex pattern to use, either as a simple string or precompiled.
---@param subject string
---@param replacement string
---@param limit? integer Limits the number of substitutions that will be done.
---
---@return string? replaced_subject
---@return integer? total_replacements
function regex.gsub(pattern, subject, replacement, limit) end

---
---Behaves like `string.match`.
---Looks for the first match of `pattern` in the string `subject`.
---If it finds a match, it returns the matched string; otherwise, it returns `nil`.
---If the pattern has captures, only the captured strings are returned.
---If a capture is empty, its offset is returned instead.
---
---@param pattern regex|string The regex pattern to use, either as a simple string or precompiled.
---@param subject string The string to search for valid matches.
---@param offset? integer The position on the subject to start searching.
---@param options? integer A bit field of matching options, eg:
---regex.NOTBOL | regex.NOTEMPTY
---
---@return (string|integer)? ... #List of captured matches; the entire match if no matches were specified; if the match is empty, its offset is returned instead.
function regex.match(pattern, subject, offset, options) end


return regex

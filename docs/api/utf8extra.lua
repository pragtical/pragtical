---@meta

---Additional utf8 support not provided by lua.
---@class utf8extra
utf8extra = {}

---UTF-8 equivalent of string.byte
---@param s  string
---@param i? integer
---@param j? integer
---@return integer
---@return ...
function utf8extra.byte(s, i, j) end

---UTF-8 equivalent of string.find
---@param s       string
---@param pattern string
---@param init?   integer
---@param plain?  boolean
---@return integer start
---@return integer end
---@return ... captured
function utf8extra.find(s, pattern, init, plain) end

---UTF-8 equivalent of string.gmatch
---@param s       string
---@param pattern string
---@param init?   integer
---@return fun():string, ...
function utf8extra.gmatch(s, pattern, init) end

---UTF-8 equivalent of string.gsub
---@param s       string
---@param pattern string
---@param repl    string|table|function
---@param n       integer
---@return string
---@return integer count
function utf8extra.gsub(s, pattern, repl, n) end

---UTF-8 equivalent of string.lower
---@param s string
---@return string
function utf8extra.lower(s) end

---UTF-8 equivalent of string.match
---@param s       string
---@param pattern string
---@param init?   integer
---@return string | number captured
function utf8extra.match(s, pattern, init) end

---UTF-8 equivalent of string.reverse
---@param s string
---@return string
function utf8extra.reverse(s) end

---UTF-8 equivalent of string.sub
---@param s  string
---@param i  integer
---@param j? integer
---@return string
function utf8extra.sub(s, i, j) end

---UTF-8 equivalent of string.upper
---@param s string
---@return string
function utf8extra.upper(s) end

---Escape a str to UTF-8 format string. It support several escape format:
---* %ddd - which ddd is a decimal number at any length: change Unicode code point to UTF-8 format.
---* %{ddd} - same as %nnn but has bracket around.
---* %uddd - same as %ddd, u stands Unicode
---* %u{ddd} - same as %{ddd}
---* %xhhh - hexadigit version of %ddd
---* %x{hhh} same as %xhhh.
---* %? - '?' stands for any other character: escape this character.
---Example:
---```lua
---local u = utf8.escape
---print(u"%123%u123%{123}%u{123}%xABC%x{ABC}")
---print(u"%%123%?%d%%u")
---```
---@param s  string
---@return string utf8_string
function utf8extra.escape(s) end

---Convert UTF-8 position to byte offset. if only index is given, return byte
---offset of this UTF-8 char index. if both charpos and index is given, a new
---charpos will be calculated, by add/subtract UTF-8 char index to current
---charpos. in all cases, it returns a new char position, and code point
---(a number) at this position.
---@param s  string
---@param charpos? integer
---@param index? integer
---@return integer charpos
---@return integer codepoint
function utf8extra.charpos(s, charpos, index) end

---Iterate though the UTF-8 string s. If only s is given, it can used as a iterator:
---```lua
--- for pos, code in utf8.next, "utf8-string" do
--- -- ...
--- end
---````
---If only charpos is given, return the next byte offset of in string. if
---charpos and index is given, a new charpos will be calculated, by add/subtract
---UTF-8 char offset to current charpos. in all case, it return a new char
---position (in bytes), and code point (a number) at this position.
---@param s  string
---@param charpos? integer
---@param index? integer
---@return integer charpos
---@return integer codepoint
function utf8extra.next(s, charpos, index) end

---Insert a substring to s. If idx is given, insert substring before char at
---this index, otherwise substring will concat to s. idx can be negative.
---@param s string
---@param idx? integer
---@param substring string
---@return string new_string
function utf8extra.insert(s, idx, substring) end

---Delete a substring in s. If neither start nor stop is given, delete the last
---UTF-8 char in s, otherwise delete char from start to end of s. if stop is
---given, delete char from start to stop (include start and stop). start and
---stop can be negative.
---@param s string
---@param start? integer
---@param stop? integer
---@return string new_string
function utf8extra.remove(s, start, stop) end

---Calculate the width of UTF-8 string s. if ambi_is_double is given, the
---ambiguous width character's width is 2, otherwise it's 1. fullwidth/doublewidth
---character's width is 2, and other character's width is 1. if default_width is
---given, it will be the width of unprintable character, used display a
---non-character mark for these characters. if s is a code point, return the
---width of this code point.
---@param s string
---@param ambi_is_double? boolean
---@param default_width? integer
---@return integer width
function utf8extra.width(s, ambi_is_double, default_width) end

---Return the character index at given location in string s. this is a reverse
---operation of utf8.width(). this function returns a index of location, and a
---offset in UTF-8 encoding. e.g. if cursor is at the second column (middle)
---of the wide char, offset will be 2. the width of character at idx is
---returned, also.
---@param s string
---@param location integer
---@param ambi_is_double? boolean
---@param default_width? integer
---@return integer idx
---@return integer offset
---@return integer width
function utf8extra.widthindex(s, location, ambi_is_double, default_width) end

---Convert UTF-8 string s to title-case, used to compare by ignore case. if s
---is a number, it's treat as a code point and return a convert code point
---(number). utf8.lower/utf8.pper has the same extension.
---@param s string
---@return string new_string
function utf8extra.title(s) end

---Convert UTF-8 string s to folded case, used to compare by ignore case. if s
---is a number, it's treat as a code point and return a convert code point
---(number). utf8.lower/utf8.pper has the same extension.
---@param s string
---@return string new_string
function utf8extra.fold(s) end

---Compare a and b without case, -1 means a < b, 0 means a == b and 1 means a > b.
---@param a string
---@param b string
---@return integer result
function utf8extra.ncasecmp(a, b) end

---Check whether s is a valid UTF-8 string or not.
---@param s string
---@return boolean
function utf8extra.isvalid(s) end

---Replace any invalid UTF-8 byte sequences in s with the replacement string.
---if no replacement string is provided, the default is "�" (REPLACEMENT CHARACTER U+FFFD).
---Note that any number of consecutive invalid bytes will be replaced by a
---single copy of the replacement string unless the non_consecutive param is
---set to true. the 2nd return value is true if the original string was already
---valid (meaning no replacements were made).
---@param s string
---@param replacement_string? string
---@param non_consecutive? boolean
---@return string cleaned_string
---@return boolean was_valid
function utf8extra.clean(s, replacement_string, non_consecutive) end

---Return the byte offset within s of the first invalid UTF-8 byte sequence.
---(1 is the first byte of the string.) if s is a valid UTF-8 string, return
---nil. the optional numeric argument init specifies where to start the search;
---its default value is 1 and can be negative.
---@param s string
---@param init? integer
---@return integer offset
function utf8extra.invalidoffset(s, init) end

---Check whether s is in Normal Form C or not. "Normal Form C" means that
---whenever possible, combining marks are combined with a preceding codepoint.
---For example, instead of U+0041 (LATIN CAPITAL LETTER A) U+00B4 (ACUTE ACCENT),
---an NFC string will use U+00C1 (LATIN CAPITAL LETTER A WITH ACUTE). Also,
---some deprecated codepoints are converted to the recommended replacements.
---since the same sequence of characters can be represented in more than one
---way in Unicode, it is better to ensure strings are in Normal Form before
---comparing them. an error may be raised if s is not a valid UTF-8 string.
---@param s string
---@return boolean
function utf8extra.isnfc(s) end

---Convert s to Normal Form C. the 2nd return value is true if the original
---string was already in NFC (meaning no modifications were made). an error
---will be raised if s is not a valid UTF-8 string.
---@param s string
---@return string normal_string
---@return boolean was_n
function utf8extra.normalize_nfc(s) end

--------------------------------------------------------------------------------
-- Lua utf8 compatible functions and fields
--------------------------------------------------------------------------------

---A string pattern which matches exactly one UTF-8 byte sequence, assuming
---that the subject is a valid UTF-8 string. can be "[\0-\x7F\xC2-\xF4][\x80-\xBF]*"
---on lua > 5.2 or "[%z\1-\x7F\xC2-\xF4][\x80-\xBF]*" otherwise.
---@type string
utf8extra.charpattern = "[%z\1-\x7F\xC2-\xF4][\x80-\xBF]*"

---Receives zero or more integers, converts each one to its corresponding
---UTF-8 byte sequence and returns a string with the concatenation of all
---these sequences.
---@param ...? integer
---@return string
function utf8extra.char(...) end

---Returns values so that the construction:
---```lua
---for p, c in utf8.codes(s) do body end
---```
---will iterate over all characters in string s, with p being the position
---(in bytes) and c the code point of each character. It raises an error if
---it meets any invalid byte sequence.
function utf8extra.codes(s) end

---Returns the codepoints (as integers) from all characters in s that start
---between byte position i and j (both included). The default for i is 1 and
---for j is i. It raises an error if it meets any invalid byte sequence.
---@param s string
---@param i? integer
---@param j? integer
---@return fun():integer, ...
function utf8extra.codepoint(s, i, j) end

---Returns the number of UTF-8 characters in string s that start between
---positions i and j (both inclusive). The default for i is 1 and for j is -1.
---If it finds any invalid byte sequence, returns a false value plus the
---position of the first invalid byte.
---@param s string
---@param i? integer
---@param j? integer
---@return integer?
---@return integer?
function utf8extra.len(s, i, j) end

---Returns the position (in bytes) where the encoding of the n-th character
---of s (counting from position i) starts. A negative n gets characters before
---position i. The default for i is 1 when n is non-negative and #s + 1
---otherwise, so that utf8.offset(s, -n) gets the offset of the n-th character
---from the end of the string. If the specified character is neither in the
---subject nor right after its end, the function returns nil.
---
---As a special case, when n is 0 the function returns the start of the
---encoding of the character that contains the i-th byte of s.
---
---This function assumes that s is a valid UTF-8 string.
---@param s string
---@param n integer
---@param i? integer
---@return integer?
function utf8extra.offset(s, n, i) end

return utf8extra

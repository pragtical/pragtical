---@meta

---
---Native tokenizer module.
---
---This module provides the native tokenizer backend used by
---`core.tokenizer` when native tokenization is enabled.
---@class tokenizer
local tokenizer = {}

---Resume information returned by `tokenizer.tokenize()` when tokenization
---does not finish within the current frame budget.
---@class tokenizer.resume
---@field res string[] Accumulated tokens in the form `{ type, text, ... }`.
---@field i integer Next character position to continue tokenizing from.
---@field state string Tokenizer state that should be reused on resume.

---
---Tokenize a single line of text using the given syntax and state.
---
---Returns tokens in the form `{ type, text, ... }`.
---If the tokenizer runs out of time, it returns a third value containing the
---resume data to continue tokenizing the same line later.
---
---@param incoming_syntax table The syntax to tokenize against.
---@param text string The line text to tokenize.
---@param state? string Current tokenizer state.
---@param resume? tokenizer.resume Resume data from a previous incomplete call.
---
---@return string[] tokens Tokens in the form `{ type, text, ... }`.
---@return string state Updated tokenizer state.
---@return tokenizer.resume? resume Resume data when tokenization yields before finishing.
function tokenizer.tokenize(incoming_syntax, text, state, resume) end

---
---Return the list of syntaxes active for the given tokenizer state.
---
---@param base_syntax table The base syntax of the document.
---@param state string Tokenizer state previously returned by `tokenize`.
---
---@return table syntaxes Array of syntaxes starting from the innermost one.
function tokenizer.extract_subsyntaxes(base_syntax, state) end


return tokenizer

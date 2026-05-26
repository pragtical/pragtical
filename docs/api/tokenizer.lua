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

---Per-pattern native tokenizer compilation and runtime counters.
---@class tokenizer.pattern_stats
---@field fast_kind integer Native fast-path kind used by the opener pattern.
---@field close_fast_kind integer Native fast-path kind used by the closer pattern.
---@field unknown_starter boolean True when the opener pattern has unknown start bytes.
---@field fallback_match_calls integer Number of fallback matcher calls for this pattern.
---@field skipped_by_starter integer Number of matches skipped by starter filtering.
---@field pattern string? Display pattern from the syntax definition.
---@field code string? Opener pattern code used by the native tokenizer.
---@field close_code string? Closer pattern code used by the native tokenizer.

---Native tokenizer compilation and runtime counters for a syntax.
---@class tokenizer.syntax_stats
---@field patterns integer Number of patterns imported from the syntax.
---@field compiled_patterns integer Number of patterns with a native fast path.
---@field fallback_patterns integer Number of patterns using the fallback matcher.
---@field has_unknown_starters boolean True when any pattern has unknown start bytes.
---@field fallback_match_calls integer Number of fallback matcher calls for this syntax.
---@field skipped_by_starter integer Number of matches skipped by starter filtering.
---@field normal_run_skips integer Number of normal text runs skipped by starter filtering.
---@field pattern_stats tokenizer.pattern_stats[] Per-pattern counters.

---
---Tokenize a single line of text using the given syntax and state.
---
---Returns tokens in the form `{ type, text, ... }`.
---If the tokenizer runs out of time, it returns a third value containing the
---resume data to continue tokenizing the same line later.
---
---@param incoming_syntax core.syntax.syntax The syntax to tokenize against.
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
---@param base_syntax core.syntax.syntax The base syntax of the document.
---@param state string Tokenizer state previously returned by `tokenize`.
---
---@return core.syntax.syntax[] syntaxes Array of syntaxes starting from the innermost one.
function tokenizer.extract_subsyntaxes(base_syntax, state) end

---
---Return native tokenizer compilation and runtime counters for a syntax.
---
---@param syntax core.syntax.syntax The syntax to inspect.
---
---@return tokenizer.syntax_stats stats Native compilation and runtime counters.
function tokenizer.get_syntax_stats(syntax) end

return tokenizer

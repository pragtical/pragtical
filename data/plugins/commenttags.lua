-- mod-version:3
local syntax = require "core.syntax"
local style = require "core.style"
local common = require "core.common"

-- Add custom colors for comment tags
style.syntax["comment.todo"] = { common.color "#00ccff" }  -- Bright cyan for TODO
style.syntax["comment.note"] = { common.color "#00ff00" }  -- Bright green for NOTE
style.syntax["comment.fixme"] = { common.color "#ff0000" } -- Bright red for FIXME
style.syntax["comment.hack"] = { common.color "#ffaa00" }  -- Orange for HACK
style.syntax["comment.bug"] = { common.color "#ff00ff" }   -- Magenta for BUG
style.syntax["comment.warning"] = { common.color "#ffff00" } -- Yellow for WARNING
style.syntax["comment.xxx"] = { common.color "#ff0000" }   -- Red for XXX

-- Patterns to match comment tags
local tag_patterns = {
  { pattern = "TODO()[%s:]*()[^\n]*", type = { "comment.todo", "comment" } },
  { pattern = "NOTE()[%s:]*()[^\n]*", type = { "comment.note", "comment" } },
  { pattern = "FIXME()[%s:]*()[^\n]*", type = { "comment.fixme", "comment" } },
  { pattern = "FIX()[%s:]*()[^\n]*", type = { "comment.fixme", "comment" } },
  { pattern = "HACK()[%s:]*()[^\n]*", type = { "comment.hack", "comment" } },
  { pattern = "BUG()[%s:]*()[^\n]*", type = { "comment.bug", "comment" } },
  { pattern = "WARNING()[%s:]*()[^\n]*", type = { "comment.warning", "comment" } },
  { pattern = "WARN()[%s:]*()[^\n]*", type = { "comment.warning", "comment" } },
  { pattern = "XXX()[%s:]*()[^\n]*", type = { "comment.xxx", "comment" } },
}

-- Function to inject tag patterns into a syntax
local function inject_comment_tags(syn)
  if not syn or not syn.patterns then return end
  
  -- Find comment patterns and inject our tag patterns after them
  for i, pattern in ipairs(syn.patterns) do
    -- Check if this is a comment pattern
    if pattern.type == "comment" and type(pattern.pattern) == "string" then
      local comment_start = pattern.pattern
      
      -- For single-line comments (like --, //, #, etc.)
      if comment_start:match("%-%-") or 
         comment_start:match("//") or 
         comment_start:match("#") then
        
        -- Insert tag patterns right after this comment pattern
        for j = #tag_patterns, 1, -1 do
          table.insert(syn.patterns, i + 1, tag_patterns[j])
        end
        break
      end
    end
  end
end

-- Inject into existing syntaxes
for _, syn in ipairs(syntax.items) do
  inject_comment_tags(syn)
end

-- Hook into syntax.add to automatically inject into new syntaxes
local syntax_add = syntax.add
function syntax.add(t)
  syntax_add(t)
  inject_comment_tags(t)
end

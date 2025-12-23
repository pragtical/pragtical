-- This is a test file to demonstrate comment tag highlighting

-- TODO: Implement the user authentication system
-- NOTE: This function is called from multiple places
-- FIXME: Memory leak in the cleanup routine
-- HACK: Temporary workaround until the API is fixed
-- BUG: Sometimes returns nil instead of empty table
-- WARNING: This code is not thread-safe
-- XXX: This needs urgent attention

local function example()
  -- TODO implement caching
  -- FIX: the return value
  local result = 42
  return result
end

-- Regular comments look normal
-- But special tags stand out!

return example

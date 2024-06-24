-- Patches encoding library to fix known encoding issues

local encoding_convert = encoding.convert

encoding.convert = function(tocharset, fromcharset, text, options)
  if fromcharset == "SHIFT_JIS" then
    -- on Japanese \ is shown as Yen sign ¥, iconv do this conversion
    -- which is problematic because it changes the original codepoint,
    -- we are insterested on keeping the original to prevent issues on
    -- code that uses escape sequences like '\n', '\r', etc...
    local errmsg
    text = text:gsub("\\", "{\\\\\\}")
    text, errmsg = encoding_convert(tocharset, fromcharset, text, options)
    if text then
      text = text:gsub("%{¥¥¥%}", "\\")
    end
    return text, errmsg
  end
  return encoding_convert(tocharset, fromcharset, text, options)
end

-- Patches encoding library to fix known encoding issues

local encoding_convert = encoding.convert

encoding.convert = function(tocharset, fromcharset, text, options)
  if fromcharset == "SHIFT_JIS" then
    -- on Japanese \ is shown as Yen sign ¥, iconv do this conversion
    -- which is problematic because it changes the original codepoint,
    -- we are insterested on keeping the original to prevent issues on
    -- code that uses escape sequences like '\n', '\r', etc...
    local errmsg
    -- replace \ with placeholder {\\\} in order to restore it back
    -- into the original backslash after encoding conversion
    text = text
      -- in between characters respecting multi-byte sequences
      :gsub("([^\x81-\x9f\xe0-\xef])(\\)", "%1{\\\\\\}")
      -- at beginning of text in case the first character is a \
      :gsub("^\\", "{\\\\\\}")
    text, errmsg = encoding_convert(tocharset, fromcharset, text, options)
    if text then
      text = text:gsub("%{¥¥¥%}", "\\")
    end
    return text, errmsg
  end
  return encoding_convert(tocharset, fromcharset, text, options)
end

local encoding_detect = encoding.detect

encoding.detect = function(filename)
  local charset, bom, errmsg = encoding_detect(filename)
  if not charset then
    local file = io.open(filename, "r")
    if file then
      local content = file:read("*a")
      file:close()
      local test_charsets = {
        "UTF-16LE", "UTF-16BE", "UTF-32LE", "UTF-32BE"
      }
      for _, from_charset in ipairs(test_charsets) do
        if encoding_convert("UTF-8", from_charset, content, {strict = true}) then
          _, bom = encoding.strip_bom(content:sub(1, 32), from_charset)
          return from_charset, bom
        end
      end
    end
  end
  return charset, bom, errmsg
end

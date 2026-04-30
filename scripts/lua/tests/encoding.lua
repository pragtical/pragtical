local common = require "core.common"
local test = require "core.test"

local temp_root

test.describe("encoding", function()
  test.before_each(function(context)
    temp_root = USERDIR
      .. PATHSEP .. "encoding-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    local ok, err = common.mkdirp(temp_root)
    test.ok(ok, err)
    context.temp_root = temp_root
  end)

  test.after_each(function(context)
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  test.test("exports the documented functions", function()
    for _, name in ipairs({
      "detect", "detect_string", "convert",
      "get_charset_bom", "strip_bom"
    }) do
      test.type(encoding[name], "function", "missing encoding." .. name)
    end
  end)

  test.test("handles byte order marks", function()
    local bom = encoding.get_charset_bom("UTF-8")
    test.not_nil(bom)

    local cleaned, stripped = encoding.strip_bom(bom .. "hello", "UTF-8")
    test.equal(cleaned, "hello")
    test.equal(stripped, bom)
  end)

  test.test("converts and detects utf8 text", function()
    local converted, err = encoding.convert("UTF-8", "UTF-8", "héllo")
    test.equal(converted, "héllo")
    test["nil"](err)

    local charset, bom, detect_err = encoding.detect_string("héllo")
    test.not_nil(charset, detect_err)
    test.match(charset, "UTF%-8")
    test["nil"](bom)
  end)

  test.test("detects utf16 files through the patched fallback", function(context)
    local path = context.temp_root .. PATHSEP .. "utf16le.txt"
    local file = io.open(path, "wb")
    test.not_nil(file)
    file:write("\255\254h\000i\000")
    file:close()

    local charset, bom, err = encoding.detect(path)
    test.equal(charset, "UTF-16LE")
    test.not_nil(bom, err)

    local removed, remove_err = os.remove(path)
    test.ok(removed, remove_err)
  end)
end)

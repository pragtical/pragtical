local common = require "core.common"
local test = require "core.test"

local temp_root
local original_cwd

local function join_path(...)
  return table.concat({...}, PATHSEP)
end

local function write_file(path, content)
  local file, err = io.open(path, "wb")
  test.not_nil(file, err)
  file:write(content or "")
  file:close()
end

local function has_value(items, expected)
  for _, item in ipairs(items) do
    if item == expected then
      return true
    end
  end
  return false
end

local function assert_contains(items, expected)
  test.ok(has_value(items, expected), string.format("missing %s", expected))
end

test.describe("core.common", function()
  test.before_each(function(context)
    original_cwd = system.getcwd()
    temp_root = USERDIR
      .. PATHSEP .. "core-common-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    context.generated_files = {
      join_path(temp_root, "test.lua"),
      join_path(temp_root, "test.txt"),
      join_path(temp_root, "other.txt"),
      join_path(temp_root, "testdir", "file.lua"),
      join_path(temp_root, "testdir", "other.txt"),
      join_path(temp_root, "testdir", "subdir", "nested.lua")
    }

    local ok, err = common.mkdirp(join_path(temp_root, "testdir", "subdir"))
    test.ok(ok, err)
    ok, err = common.mkdirp(join_path(temp_root, "projects"))
    test.ok(ok, err)
    ok, err = common.mkdirp(join_path(temp_root, "documents"))
    test.ok(ok, err)

    write_file(context.generated_files[1], "return true\n")
    write_file(context.generated_files[2], "hello\n")
    write_file(context.generated_files[3], "other\n")
    write_file(context.generated_files[4], "return 1\n")
    write_file(context.generated_files[5], "other\n")
    write_file(context.generated_files[6], "return 2\n")

    context.temp_root = temp_root
    context.original_cwd = original_cwd
  end)

  test.after_each(function(context)
    system.chdir(context.original_cwd)
    for _, path in ipairs(context.generated_files or {}) do
      if system.get_file_info(path) then
        local removed, remove_err = os.remove(path)
        test.ok(removed, remove_err)
      end
    end
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  test.describe("path_suggest", function()
    test.test("suggests relative paths from the current directory", function(context)
      system.chdir(context.temp_root)
      local result = common.path_suggest("test")
      test.type(result, "table")
      assert_contains(result, "test.lua")
      assert_contains(result, "test.txt")
      assert_contains(result, "testdir" .. PATHSEP)
    end)

    test.test("suggests absolute paths", function(context)
      local prefix = join_path(context.temp_root, "testdir", "fi")
      local result = common.path_suggest(prefix)
      test.type(result, "table")
      assert_contains(result, join_path(context.temp_root, "testdir", "file.lua"))
    end)

    test.test("suggests paths relative to a root directory", function(context)
      local result = common.path_suggest("test", context.temp_root)
      test.type(result, "table")
      assert_contains(result, "test.lua")
      assert_contains(result, "test.txt")
      assert_contains(result, "testdir" .. PATHSEP)
    end)

    test.test("lists root entries when given an empty path", function(context)
      local result = common.path_suggest("", context.temp_root)
      test.type(result, "table")
      assert_contains(result, "documents" .. PATHSEP)
      assert_contains(result, "projects" .. PATHSEP)
      assert_contains(result, "test.lua")
    end)

    test.test("does not prefix relative suggestions with dot slash", function(context)
      system.chdir(context.temp_root)
      local result = common.path_suggest("test")
      for _, item in ipairs(result) do
        test.not_equal(item:sub(1, 2), "." .. PATHSEP)
      end
    end)
  end)

  test.describe("dir_path_suggest", function()
    test.test("suggests directories relative to a root directory", function(context)
      local result = common.dir_path_suggest(join_path(context.temp_root, "test"), context.temp_root)
      test.type(result, "table")
      test.equal(#result, 1)
      assert_contains(result, join_path(context.temp_root, "testdir"))
    end)

    test.test("suggests nested directories", function(context)
      local prefix = join_path(context.temp_root, "testdir", "sub")
      local result = common.dir_path_suggest(prefix, context.temp_root)
      test.type(result, "table")
      test.equal(#result, 1)
      assert_contains(result, join_path(context.temp_root, "testdir", "subdir"))
    end)
  end)

  test.describe("dir_list_suggest", function()
    test.test("filters a directory list by prefix", function(context)
      local dir_list = {
        join_path(context.temp_root, "testdir"),
        join_path(context.temp_root, "projects"),
        join_path(context.temp_root, "documents")
      }
      local result = common.dir_list_suggest(join_path(context.temp_root, "test"), dir_list)
      test.type(result, "table")
      test.equal(#result, 1)
      assert_contains(result, join_path(context.temp_root, "testdir"))
    end)

    test.test("returns an empty list when no entries match", function(context)
      local dir_list = {
        join_path(context.temp_root, "projects"),
        join_path(context.temp_root, "documents")
      }
      local result = common.dir_list_suggest(join_path(context.temp_root, "test"), dir_list)
      test.type(result, "table")
      test.equal(#result, 0)
    end)
  end)

  test.describe("dirname", function()
    test.test("returns parent directories for common paths", function()
      if PLATFORM == "Windows" then
        test.equal(common.dirname("C:\\Users\\username\\test\\file.lua"), "C:\\Users\\username\\test")
        test.equal(common.dirname("C:\\Users"), "C:")
        test.equal(common.dirname("\\\\server\\share\\folder\\file.txt"), "\\\\server\\share\\folder")
      else
        test.equal(common.dirname("/home/username/test/file.lua"), "/home/username/test")
        test.equal(common.dirname("/home.txt"), "/")
        test.equal(common.dirname("./src/core/common.lua"), "./src/core")
      end
      test.is_nil(common.dirname("file.lua"))
    end)
  end)

  test.describe("normalize_path", function()
    test.test("normalizes dot and dot-dot components", function()
      if PLATFORM == "Windows" then
        test.equal(common.normalize_path("C:\\Users\\.\\test"), "C:\\Users\\test")
        test.equal(common.normalize_path("C:\\Users\\username\\..\\test"), "C:\\Users\\test")
        test.equal(common.normalize_path("C:/Users/username/test"), "C:\\Users\\username\\test")
        test.error(function()
          common.normalize_path("C:\\..\\test")
        end)
      else
        test.equal(common.normalize_path("/home/./username/./test"), "/home/username/test")
        test.equal(common.normalize_path("/home/username/../test"), "/home/test")
        test.equal(common.normalize_path("../test"), "../test")
      end
      test.is_nil(common.normalize_path(nil))
    end)
  end)

  test.describe("relative_path", function()
    test.test("makes paths relative when possible", function(context)
      local base = context.temp_root
      local target = join_path(context.temp_root, "testdir", "file.lua")
      test.equal(common.relative_path(base, target), join_path("testdir", "file.lua"))
      test.equal(common.relative_path(base, base), ".")
    end)

    test.test("preserves Windows paths on different drives", function()
      if PLATFORM == "Windows" then
        test.equal(
          common.relative_path("C:\\Users", "D:\\Users\\test\\file.lua"),
          "D:\\Users\\test\\file.lua"
        )
      end
    end)
  end)

  test.describe("is_absolute_path", function()
    test.test("recognizes absolute and relative paths", function()
      if PLATFORM == "Windows" then
        test.not_nil(common.is_absolute_path("C:\\Users\\username\\test\\file.lua"))
        test.ok(common.is_absolute_path("\\\\server\\share\\folder\\file.txt"))
        test.is_nil(common.is_absolute_path("Users\\username\\test\\file.lua"))
      else
        test.ok(common.is_absolute_path("/home/username/test/file.lua"))
        test.ok(common.is_absolute_path("/"))
        test.is_nil(common.is_absolute_path("home/username/test/file.lua"))
        test.is_nil(common.is_absolute_path("./test/file.lua"))
      end
    end)
  end)

  test.describe("normalize_volume", function()
    test.test("normalizes Windows drive letters and leaves other paths unchanged", function()
      test.is_nil(common.normalize_volume(nil))

      if PLATFORM == "Windows" then
        test.equal(common.normalize_volume("c:\\Users\\username\\test\\file.lua"),
          "C:\\Users\\username\\test\\file.lua")
        test.equal(common.normalize_volume("d:\\Users\\"), "D:\\Users")
        test.equal(common.normalize_volume("\\\\server\\share\\folder\\file.txt"),
          "\\\\server\\share\\folder\\file.txt")
      else
        test.equal(common.normalize_volume("/home/username/test/file.lua"),
          "/home/username/test/file.lua")
        test.equal(common.normalize_volume("/"), "/")
      end
    end)
  end)
end)

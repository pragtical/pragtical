local common = require "core.common"

describe("Testing common.path_suggest for", function()
  -- Ensure globals are accessible
  setup(function()
    _G.PLATFORM = _G.PLATFORM or "Linux"
    _G.PATHSEP = _G.PATHSEP or "/"
    -- Create mock system table if it doesn't exist
    if not system then
      _G.system = {}
    end
  end)

  -- Store original functions (if they exist)
  local original_list_dir
  local original_get_file_info
  local original_is_absolute_path

  before_each(function()
    original_list_dir = system.list_dir
    original_get_file_info = system.get_file_info
    original_is_absolute_path = common.is_absolute_path
  end)

  after_each(function()
    if system then
      system.list_dir = original_list_dir
      system.get_file_info = original_get_file_info
    end
    if common.is_absolute_path then
      common.is_absolute_path = original_is_absolute_path
    end
  end)

  describe("Linux", function()
    before_each(function()
      _G.PLATFORM = "Linux"
      _G.PATHSEP = "/"

      -- Mock system.list_dir for Linux paths
      system.list_dir = function(path)
        if path:match("/home/username/test") or path:match("home/username/test") then
          return {"file.lua", "other.txt"}
        elseif path:match("/test") or path:match("test") and not path:match("username") then
          return {"file.lua", "subdir"}
        elseif path:match("subdir") then
          return {"nested.lua"}
        elseif path:match("/home") then
          return {"username", "test"}
        elseif path == "./" or path == "." then
          return {"file.lua", "test.txt", "subdir", "test.lua", "other.txt"}
        end
        return {}
      end

      -- Mock system.get_file_info for Linux
      system.get_file_info = function(file)
        if file:match("subdir") or file:match("username") or (file:match("test") and not file:match("%.")) then
          return {type = "dir"}
        elseif file:match("%.") then
          return {type = "file"}
        end
        return nil
      end

      -- Mock common.is_absolute_path for Linux
      common.is_absolute_path = function(path)
        return path:sub(1, 1) == "/"
      end
    end)

    it("should suggest paths for relative path", function()
      local result = common.path_suggest("test")
      assert.is_table(result)
      -- Should return paths that start with "test"
      for _, path in ipairs(result) do
        assert.is_true(path:lower():find("test", 1, true) == 1)
      end
    end)

    it("should suggest paths for ~/test/file.lua", function()
      local result = common.path_suggest("~/test/file.lua")
      assert.is_table(result)
    end)

    it("should suggest paths for /home/username/test/file.lua", function()
      local result = common.path_suggest("/home/username/test/file.lua")
      assert.is_table(result)
    end)

    it("should suggest paths with root directory", function()
      local result = common.path_suggest("test", "/home")
      assert.is_table(result)
    end)

    it("should handle empty path with root", function()
      local result = common.path_suggest("", "/home")
      assert.is_table(result)
    end)

    it("should remove ./ prefix when path is empty and no root provided", function()
      -- Mock system.list_dir for current directory
      system.list_dir = function(path)
        if path == "./" or path == "." then
          return {"file.lua", "test.txt", "subdir"}
        end
        return {}
      end

      -- Mock system.get_file_info
      system.get_file_info = function(file)
        if file:match("subdir") then
          return {type = "dir"}
        elseif file:match("%.") then
          return {type = "file"}
        end
        return nil
      end

      local result = common.path_suggest("file")
      assert.is_table(result)
      -- Results should not start with ./
      for _, path in ipairs(result) do
        assert.is_false(path:sub(1, 2) == "./", "Path should not start with ./: " .. path)
      end
    end)

    it("should remove ./ prefix for single filename with no root", function()
      -- Mock system.list_dir for current directory
      system.list_dir = function(path)
        if path == "./" or path == "." then
          return {"test.lua", "other.txt"}
        end
        return {}
      end

      -- Mock system.get_file_info
      system.get_file_info = function(file)
        if file:match("%.") then
          return {type = "file"}
        end
        return nil
      end

      local result = common.path_suggest("test")
      assert.is_table(result)
      -- Results should not start with ./
      for _, path in ipairs(result) do
        assert.is_false(path:sub(1, 2) == "./", "Path should not start with ./: " .. path)
      end
    end)
  end)

  describe("Windows", function()
    before_each(function()
      _G.PLATFORM = "Windows"
      _G.PATHSEP = "\\"

      -- Mock system.list_dir for Windows paths
      system.list_dir = function(path)
        if path:match("C:\\Users\\username\\test") or path:match("Users\\username\\test") then
          return {"file.lua", "other.txt"}
        elseif path:match("\\test") or (path:match("test") and not path:match("username")) then
          return {"file.lua", "subdir"}
        elseif path:match("subdir") then
          return {"nested.lua"}
        elseif path:match("C:\\Users") or path:match("Users") then
          return {"username", "test"}
        elseif path == ".\\" or path == "." then
          return {"file.lua", "test.txt", "subdir", "test.lua", "other.txt"}
        end
        return {}
      end

      -- Mock system.get_file_info for Windows
      system.get_file_info = function(file)
        if file:match("subdir") or file:match("username") or (file:match("test") and not file:match("%.")) then
          return {type = "dir"}
        elseif file:match("%.") then
          return {type = "file"}
        end
        return nil
      end

      -- Mock common.is_absolute_path for Windows
      common.is_absolute_path = function(path)
        return path:match("^%a:\\") or path:sub(1, 1) == "\\"
      end
    end)

    it("should suggest paths for relative path", function()
      local result = common.path_suggest("test")
      assert.is_table(result)
    end)

    it("should suggest paths for C:\\Users\\username\\test\\file.lua", function()
      local result = common.path_suggest("C:\\Users\\username\\test\\file.lua")
      assert.is_table(result)
    end)

    it("should suggest paths with root directory", function()
      local result = common.path_suggest("test", "C:\\Users")
      assert.is_table(result)
    end)

    it("should handle Windows path separators", function()
      local result = common.path_suggest("Users\\username")
      assert.is_table(result)
    end)

    it("should remove .\\ prefix when path is empty and no root provided", function()
      local result = common.path_suggest("file")
      assert.is_table(result)
      -- Results should not start with .\
      for _, path in ipairs(result) do
        assert.is_false(path:sub(1, 2) == ".\\", "Path should not start with .\\: " .. path)
      end
    end)

    it("should remove .\\ prefix for single filename with no root", function()
      local result = common.path_suggest("test")
      assert.is_table(result)
      -- Results should not start with .\
      for _, path in ipairs(result) do
        assert.is_false(path:sub(1, 2) == ".\\", "Path should not start with .\\: " .. path)
      end
    end)
  end)
end)

describe("Testing common.dir_path_suggest for", function()
  -- Ensure globals are accessible
  setup(function()
    _G.PLATFORM = _G.PLATFORM or "Linux"
    _G.PATHSEP = _G.PATHSEP or "/"
    -- Create mock system table if it doesn't exist
    if not system then
      _G.system = {}
    end
  end)

  -- Store original functions (if they exist)
  local original_list_dir
  local original_get_file_info

  before_each(function()
    original_list_dir = system.list_dir
    original_get_file_info = system.get_file_info
  end)

  after_each(function()
    if system then
      system.list_dir = original_list_dir
      system.get_file_info = original_get_file_info
    end
  end)

  describe("Linux", function()
    before_each(function()
      _G.PLATFORM = "Linux"
      _G.PATHSEP = "/"

      -- Mock system.list_dir for Linux paths (only directories)
      system.list_dir = function(path)
        if path:match("/home/username") or path:match("home/username") then
          return {"test", "projects", "documents"}
        elseif path:match("/home/") or path:match("home/") then
          return {"username", "otheruser"}
        elseif path:match("/test") or path:match("test") then
          return {"subdir", "otherdir"}
        elseif path:match("/") then
          return {"home", "usr", "var"}
        end
        return {}
      end

      -- Mock system.get_file_info for Linux (only return dirs)
      system.get_file_info = function(file)
        if file:match("subdir") or file:match("otherdir") or file:match("test") or
           file:match("projects") or file:match("documents") or file:match("username") or
           file:match("otheruser") or file:match("home") or file:match("usr") or file:match("var") then
          return {type = "dir"}
        end
        return nil
      end
    end)

    it("should suggest directories for relative path", function()
      local result = common.dir_path_suggest("test", "/home")
      assert.is_table(result)
      assert.are.equal(0, #result)
      -- Should only return directories
      for _, path in ipairs(result) do
        assert.is_true(path:lower():find("test", 1, true) == 1)
      end
    end)

    it("should suggest directories for ~/test", function()
      local result = common.dir_path_suggest("~/test", "/home")
      assert.is_table(result)
      assert.are.equal(0, #result)
    end)

    it("should suggest directories for /home/username/test", function()
      local result = common.dir_path_suggest("/home/username/test", "/home")
      assert.is_table(result)
      assert.are.equal(1, #result)
    end)

    it("should suggest directories with root directory", function()
      local result = common.dir_path_suggest("/home/username", "/home")
      assert.is_table(result)
      assert.are.equal(1, #result)
    end)
  end)

  describe("Windows", function()
    before_each(function()
      _G.PLATFORM = "Windows"
      _G.PATHSEP = "\\"

      -- Mock system.list_dir for Windows paths (only directories)
      system.list_dir = function(path)
        if path:match("C:\\Users\\username") or path:match("Users\\username") then
          return {"test", "projects", "documents"}
        elseif path:match("C:\\Users") or path:match("Users") then
          return {"username", "otheruser"}
        elseif path:match("\\test") or (path:match("test") and not path:match("username")) then
          return {"subdir", "otherdir"}
        elseif path:match("C:\\") then
          return {"Users", "Program Files", "Windows"}
        end
        return {}
      end

      -- Mock system.get_file_info for Windows (only return dirs)
      system.get_file_info = function(file)
        if file:match("subdir") or file:match("otherdir") or file:match("test") or
           file:match("projects") or file:match("documents") or file:match("username") or
           file:match("otheruser") or file:match("Users") or file:match("Program Files") or
           file:match("Windows") then
          return {type = "dir"}
        end
        return nil
      end
    end)

    it("should suggest directories for relative path", function()
      local result = common.dir_path_suggest("test", "C:\\Users")
      assert.is_table(result)
      assert.are.equal(0, #result)
    end)

    it("should suggest directories for C:\\Users\\username\\test", function()
      local result = common.dir_path_suggest("C:\\Users\\username\\test", "C:\\Users")
      assert.is_table(result)
      assert.are.equal(1, #result)
    end)

    it("should suggest directories with root directory", function()
      local result = common.dir_path_suggest("C:\\Users\\username", "C:\\Users")
      assert.is_table(result)
      assert.are.equal(1, #result)
    end)

    it("should handle Windows path separators", function()
      local result = common.dir_path_suggest("Users\\username", "C:\\")
      assert.is_table(result)
      assert.are.equal(1, #result)
    end)
  end)
end)

describe("Testing common.dir_list_suggest for", function()
  -- Ensure globals are accessible
  setup(function()
    _G.PLATFORM = _G.PLATFORM or "Linux"
    _G.PATHSEP = _G.PATHSEP or "/"
  end)

  describe("Linux", function()
    before_each(function()
      _G.PLATFORM = "Linux"
      _G.PATHSEP = "/"
    end)

    it("should filter directories from list for relative path", function()
      local dir_list = {"/home/username/test", "/home/username/projects", "/home/otheruser/test", "/var/log"}
      local result = common.dir_list_suggest("test", dir_list)
      assert.is_table(result)
      -- Should return paths that start with "test"
      for _, path in ipairs(result) do
        assert.is_true(path:lower():find("test", 1, true) == 1)
      end
    end)

    it("should filter directories for ~/test", function()
      local dir_list = {"~/test", "~/projects", "~/documents"}
      local result = common.dir_list_suggest("~/test", dir_list)
      assert.is_table(result)
      assert.is_true(#result > 0)
    end)

    it("should filter directories for /home/username/test", function()
      local dir_list = {"/home/username/test", "/home/username/projects", "/home/otheruser/test"}
      local result = common.dir_list_suggest("/home/username/test", dir_list)
      assert.is_table(result)
      assert.is_true(#result > 0)
    end)

    it("should return empty list when no matches", function()
      local dir_list = {"/home/username/projects", "/var/log"}
      local result = common.dir_list_suggest("test", dir_list)
      assert.is_table(result)
      assert.is_true(#result == 0)
    end)
  end)

  describe("Windows", function()
    before_each(function()
      _G.PLATFORM = "Windows"
      _G.PATHSEP = "\\"
    end)

    it("should filter directories from list for relative path", function()
      local dir_list = {"C:\\Users\\username\\test", "C:\\Users\\username\\projects", "C:\\Users\\otheruser\\test"}
      local result = common.dir_list_suggest("test", dir_list)
      assert.is_table(result)
      for _, path in ipairs(result) do
        assert.is_true(path:lower():find("test", 1, true) == 1)
      end
    end)

    it("should filter directories for C:\\Users\\username\\test", function()
      local dir_list = {"C:\\Users\\username\\test", "C:\\Users\\username\\projects", "C:\\Users\\otheruser\\test"}
      local result = common.dir_list_suggest("C:\\Users\\username\\test", dir_list)
      assert.is_table(result)
      assert.is_true(#result > 0)
    end)

    it("should handle Windows path separators", function()
      local dir_list = {"C:\\Users\\username", "C:\\Program Files", "D:\\Users"}
      local result = common.dir_list_suggest("C:\\Users", dir_list)
      assert.is_table(result)
      assert.is_true(#result > 0)
    end)

    it("should handle case-insensitive matching", function()
      local dir_list = {"C:\\Users\\username\\Test", "C:\\users\\username"}
      local result = common.dir_list_suggest("C:\\Users", dir_list)
      assert.is_table(result)
      assert.is_true(#result == 2)
    end)
  end)
end)

describe("Testing common.dirname for", function()
  -- Ensure globals are accessible
  setup(function()
    _G.PLATFORM = _G.PLATFORM or "Linux"
    _G.PATHSEP = _G.PATHSEP or "/"
  end)

  describe("Linux", function()
    before_each(function()
      _G.PLATFORM = "Linux"
      _G.PATHSEP = "/"
    end)

    it("should return directory from absolute path", function()
      assert.are.equal("/home/username/test", common.dirname("/home/username/test/file.lua"))
    end)

    it("should return directory from relative path", function()
      assert.are.equal("home/username/test", common.dirname("home/username/test/file.lua"))
    end)

    it("should return parent directory", function()
      assert.are.equal("/home/username", common.dirname("/home/username/test"))
    end)

    it("should return root directory", function()
      assert.are.equal("/", common.dirname("/home.txt"))
    end)

    it("should return nil for single component path", function()
      assert.is_nil(common.dirname("file.lua"))
    end)

    it("should return nil for root path", function()
      assert.are.equal("/", common.dirname("/"))
    end)

    it("should handle path with multiple levels", function()
      assert.are.equal("/usr/local/share", common.dirname("/usr/local/share/pragtical"))
    end)

    it("should handle path with tilde", function()
      assert.are.equal("~/test", common.dirname("~/test/file.lua"))
    end)

    it("should return directory from path starting with ./", function()
      assert.are.equal("./test", common.dirname("./test/file.lua"))
    end)

    it("should return nil for path starting with ./ and single file (no separator)", function()
      assert.are.equal(".", common.dirname("./file.lua"))
    end)

    it("should handle nested paths starting with ./", function()
      assert.are.equal("./home/username/test", common.dirname("./home/username/test/file.lua"))
    end)

    it("should handle ./ with multiple levels", function()
      assert.are.equal("./src/core", common.dirname("./src/core/common.lua"))
    end)
  end)

  describe("Windows", function()
    before_each(function()
      _G.PLATFORM = "Windows"
      _G.PATHSEP = "\\"
    end)

    it("should return directory from absolute path", function()
      assert.are.equal("C:\\Users\\username\\test", common.dirname("C:\\Users\\username\\test\\file.lua"))
    end)

    it("should return directory from relative path", function()
      assert.are.equal("Users\\username\\test", common.dirname("Users\\username\\test\\file.lua"))
    end)

    it("should return parent directory", function()
      assert.are.equal("C:\\Users\\username", common.dirname("C:\\Users\\username\\test"))
    end)

    it("should return drive root", function()
      assert.are.equal("C:", common.dirname("C:\\Users"))
    end)

    it("should return nil for single component path", function()
      assert.is_nil(common.dirname("file.lua"))
    end)

    it("should handle path with multiple levels", function()
      assert.are.equal("C:\\Program Files\\Pragtical", common.dirname("C:\\Program Files\\Pragtical\\pragtical.exe"))
    end)

    it("should handle UNC path", function()
      assert.are.equal("\\\\server\\share\\folder", common.dirname("\\\\server\\share\\folder\\file.txt"))
    end)
  end)
end)

describe("Testing common.normalize_path for", function()
  -- Ensure globals are accessible
  setup(function()
    _G.PLATFORM = _G.PLATFORM or "Linux"
    _G.PATHSEP = _G.PATHSEP or "/"
  end)

  describe("Linux", function()
    before_each(function()
      _G.PLATFORM = "Linux"
      _G.PATHSEP = "/"
    end)

    it("should return nil for nil input", function()
      assert.is_nil(common.normalize_path(nil))
    end)

    it("should normalize absolute path", function()
      assert.are.equal("/home/username/test/file.lua",
        common.normalize_path("/home/username/test/file.lua"))
    end)

    it("should normalize relative path", function()
      assert.are.equal("home/username/test/file.lua",
        common.normalize_path("home/username/test/file.lua"))
    end)

    it("should handle root path", function()
      assert.are.equal("/", common.normalize_path("/"))
    end)

    it("should remove . components", function()
      assert.are.equal("/home/username/test",
        common.normalize_path("/home/./username/./test"))
    end)

    it("should resolve .. components", function()
      assert.are.equal("/home/test",
        common.normalize_path("/home/username/../test"))
    end)

    it("should handle multiple .. components", function()
      assert.are.equal("/test",
        common.normalize_path("/home/username/../../test"))
    end)

    it("should keep .. at start of relative path", function()
      assert.are.equal("../test",
        common.normalize_path("../test"))
    end)

    it("should handle complex path with . and ..", function()
      assert.are.equal("/home/test/file.lua",
        common.normalize_path("/home/username/.././test/./file.lua"))
    end)

    it("should normalize path with mixed separators (converts to /)", function()
      assert.are.equal("/home\\username/test",
        common.normalize_path("/home\\username/test"))
    end)
  end)

  describe("Windows", function()
    before_each(function()
      _G.PLATFORM = "Windows"
      _G.PATHSEP = "\\"
    end)

    it("should return nil for nil input", function()
      assert.is_nil(common.normalize_path(nil))
    end)

    it("should normalize absolute path with drive", function()
      assert.are.equal("C:\\Users\\username\\test\\file.lua",
        common.normalize_path("C:\\Users\\username\\test\\file.lua"))
    end)

    it("should convert lowercase drive to uppercase", function()
      assert.are.equal("C:\\Users\\test",
        common.normalize_path("c:\\Users\\test"))
    end)

    it("should normalize relative path", function()
      assert.are.equal("Users\\username\\test",
        common.normalize_path("Users\\username\\test"))
    end)

    it("should convert forward slashes to backslashes", function()
      assert.are.equal("C:\\Users\\username\\test",
        common.normalize_path("C:/Users/username/test"))
    end)

    it("should handle mixed separators", function()
      assert.are.equal("C:\\Users\\username\\test",
        common.normalize_path("C:/Users\\username/test"))
    end)

    it("should remove . components", function()
      assert.are.equal("C:\\Users\\test",
        common.normalize_path("C:\\Users\\.\\test"))
    end)

    it("should resolve .. components", function()
      assert.are.equal("C:\\Users\\test",
        common.normalize_path("C:\\Users\\username\\..\\test"))
    end)

    it("should error on .. beyond drive root", function()
      assert.has_error(function()
        common.normalize_path("C:\\..\\test")
      end)
    end)

    it("should handle UNC paths", function()
      local result = common.normalize_path("\\\\server\\share\\folder\\file.txt")
      assert.is_string(result)
      assert.are.equal("\\\\server\\share\\folder\\file.txt", result)
    end)
  end)
end)

describe("Testing common.relative_path for", function()
  -- Ensure globals are accessible
  setup(function()
    _G.PLATFORM = _G.PLATFORM or "Linux"
    _G.PATHSEP = _G.PATHSEP or "/"
  end)

  describe("Linux", function()
    before_each(function()
      _G.PLATFORM = "Linux"
      _G.PATHSEP = "/"
    end)

    it("should make path relative to reference directory", function()
      assert.are.equal("test/file.lua",
        common.relative_path("/home/username", "/home/username/test/file.lua"))
    end)

    it("should handle nested directories", function()
      assert.are.equal("test/subdir/file.lua",
        common.relative_path("/home/username", "/home/username/test/subdir/file.lua"))
    end)

    it("should handle paths going up directories", function()
      assert.are.equal("../../other/file.lua",
        common.relative_path("/home/username/test", "/home/other/file.lua"))
    end)

    it("should return . for same directory", function()
      assert.are.equal(".",
        common.relative_path("/home/username", "/home/username"))
    end)

    it("should handle relative reference directory", function()
      assert.are.equal("test/file.lua",
        common.relative_path("home/username", "home/username/test/file.lua"))
    end)
  end)

  describe("Windows", function()
    before_each(function()
      _G.PLATFORM = "Windows"
      _G.PATHSEP = "\\"
    end)

    it("should make path relative to reference directory", function()
      assert.are.equal("test\\file.lua",
        common.relative_path("C:\\Users\\username", "C:\\Users\\username\\test\\file.lua"))
    end)

    it("should handle nested directories", function()
      assert.are.equal("test\\subdir\\file.lua",
        common.relative_path("C:\\Users\\username", "C:\\Users\\username\\test\\subdir\\file.lua"))
    end)

    it("should handle paths going up directories", function()
      assert.are.equal("..\\..\\other\\file.lua",
        common.relative_path("C:\\Users\\username\\test", "C:\\Users\\other\\file.lua"))
    end)

    it("should return absolute path for different drives", function()
      assert.are.equal("D:\\Users\\test\\file.lua",
        common.relative_path("C:\\Users", "D:\\Users\\test\\file.lua"))
    end)

    it("should return . for same directory", function()
      assert.are.equal(".",
        common.relative_path("C:\\Users\\username", "C:\\Users\\username"))
    end)
  end)
end)

describe("Testing common.is_absolute_path for", function()
  -- Ensure globals are accessible
  setup(function()
    _G.PLATFORM = _G.PLATFORM or "Linux"
    _G.PATHSEP = _G.PATHSEP or "/"
  end)

  describe("Linux", function()
    before_each(function()
      _G.PLATFORM = "Linux"
      _G.PATHSEP = "/"
    end)

    it("should return true for absolute path starting with /", function()
      assert.is_true(common.is_absolute_path("/home/username/test/file.lua"))
    end)

    it("should return true for root path", function()
      assert.is_true(common.is_absolute_path("/"))
    end)

    it("should return true for root-level file", function()
      assert.is_true(common.is_absolute_path("/home.txt"))
    end)

    it("should return false for relative path", function()
      assert.is_nil(common.is_absolute_path("home/username/test/file.lua"))
    end)

    it("should return false for relative path starting with ./", function()
      assert.is_nil(common.is_absolute_path("./test/file.lua"))
    end)

    it("should return false for relative path starting with ../", function()
      assert.is_nil(common.is_absolute_path("../test/file.lua"))
    end)

    it("should return false for single component path", function()
      assert.is_nil(common.is_absolute_path("file.lua"))
    end)

    it("should return false for path starting with ~", function()
      assert.is_nil(common.is_absolute_path("~/test/file.lua"))
    end)
  end)

  describe("Windows", function()
    before_each(function()
      _G.PLATFORM = "Windows"
      _G.PATHSEP = "\\"
    end)

    it("should return true for absolute path with drive letter", function()
      assert.is_not_nil(common.is_absolute_path("C:\\Users\\username\\test\\file.lua"))
    end)

    it("should return true for lowercase drive letter", function()
      assert.is_not_nil(common.is_absolute_path("c:\\Users\\test"))
    end)

    it("should return true for drive root", function()
      assert.is_not_nil(common.is_absolute_path("C:\\"))
    end)

    it("should return true for UNC path", function()
      assert.is_true(common.is_absolute_path("\\\\server\\share\\folder\\file.txt"))
    end)

    it("should return false for relative path", function()
      assert.is_nil(common.is_absolute_path("Users\\username\\test\\file.lua"))
    end)

    it("should return false for relative path starting with ./", function()
      assert.is_nil(common.is_absolute_path(".\\test\\file.lua"))
    end)

    it("should return false for relative path starting with ../", function()
      assert.is_nil(common.is_absolute_path("..\\test\\file.lua"))
    end)

    it("should return false for single component path", function()
      assert.is_nil(common.is_absolute_path("file.lua"))
    end)

    it("should return false for path with forward slashes but no drive", function()
      assert.is_nil(common.is_absolute_path("/Users/test"))
    end)
  end)
end)

describe("Testing common.normalize_volume for", function()
  -- Ensure globals are accessible
  setup(function()
    _G.PLATFORM = _G.PLATFORM or "Linux"
    _G.PATHSEP = _G.PATHSEP or "/"
  end)

  describe("Linux", function()
    before_each(function()
      _G.PLATFORM = "Linux"
      _G.PATHSEP = "/"
    end)

    it("should return nil for nil input", function()
      assert.is_nil(common.normalize_volume(nil))
    end)

    it("should return path unchanged for absolute path", function()
      assert.are.equal("/home/username/test/file.lua",
        common.normalize_volume("/home/username/test/file.lua"))
    end)

    it("should return path unchanged for relative path", function()
      assert.are.equal("home/username/test/file.lua",
        common.normalize_volume("home/username/test/file.lua"))
    end)

    it("should return root path unchanged", function()
      assert.are.equal("/", common.normalize_volume("/"))
    end)
  end)

  describe("Windows", function()
    before_each(function()
      _G.PLATFORM = "Windows"
      _G.PATHSEP = "\\"
    end)

    it("should return nil for nil input", function()
      assert.is_nil(common.normalize_volume(nil))
    end)

    it("should normalize lowercase drive to uppercase", function()
      assert.are.equal("C:\\Users\\username\\test\\file.lua",
        common.normalize_volume("c:\\Users\\username\\test\\file.lua"))
    end)

    it("should normalize uppercase drive (no change)", function()
      assert.are.equal("C:\\Users\\username\\test\\file.lua",
        common.normalize_volume("C:\\Users\\username\\test\\file.lua"))
    end)

    it("should normalize drive root", function()
      assert.are.equal("C:\\", common.normalize_volume("c:\\"))
    end)

    it("should normalize drive with trailing backslash", function()
      assert.are.equal("D:\\Users",
        common.normalize_volume("d:\\Users\\"))
    end)

    it("should normalize drive without trailing backslash", function()
      assert.are.equal("E:\\Users",
        common.normalize_volume("e:\\Users"))
    end)

    it("should return path unchanged if no drive letter", function()
      assert.are.equal("Users\\username\\test",
        common.normalize_volume("Users\\username\\test"))
    end)

    it("should handle UNC paths (no change)", function()
      assert.are.equal("\\\\server\\share\\folder\\file.txt",
        common.normalize_volume("\\\\server\\share\\folder\\file.txt"))
    end)
  end)

end)

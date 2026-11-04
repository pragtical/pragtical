local test = require "core.test"

test.describe("regex", function()
  test.test("exports the documented functions and flags", function()
    for _, name in ipairs({
      "compile", "cmatch", "find", "find_offsets",
      "gmatch", "gsub", "match"
    }) do
      test.type(regex[name], "function", "missing regex." .. name)
    end

    for _, name in ipairs({
      "ANCHORED", "ENDANCHORED", "NOTBOL",
      "NOTEOL", "NOTEMPTY", "NOTEMPTY_ATSTART"
    }) do
      test.type(regex[name], "number", "missing regex." .. name)
    end
  end)

  test.test("compiles and matches simple patterns", function()
    local compiled, err = regex.compile("(hello)\\s+(world)")
    test.not_nil(compiled, err)

    local start_idx, end_idx, first, second = regex.find(compiled, "well hello world!")
    test.equal(start_idx, 6)
    test.equal(end_idx, 16)
    test.equal(first, "hello")
    test.equal(second, "world")

    local match_first, match_second = regex.match(compiled, "hello world")
    test.equal(match_first, "hello")
    test.equal(match_second, "world")
  end)

  test.test("iterates and replaces matches", function()
    local items = {}
    for first, second in regex.gmatch("(a)(b)", "ab ab") do
      table.insert(items, first .. second)
    end
    test.same(items, {"ab", "ab"})

    local replaced, total = regex.gsub("(ab)", "ab-ab", "[$1]")
    test.equal(replaced, "[ab]-[ab]")
    test.equal(total, 2)
  end)

  test.test("reports invalid patterns and match offsets", function()
    local compiled, err = regex.compile("(")
    test.is_nil(compiled)
    test.not_nil(err)

    local start_idx, end_idx, c1s, c1e, c2s, c2e =
      regex.find_offsets("(he)(llo)", "hello")
    test.equal(start_idx, 1)
    test.equal(end_idx, 6)
    test.equal(c1s, 1)
    test.equal(c1e, 2)
    test.equal(c2s, 3)
    test.equal(c2e, 5)
  end)

  test.test("handles negative offsets like string.find", function()
    local subject = "0123456789"
    local compiled = test.not_nil(regex.compile("(.)"))

    local start_idx, end_idx, capture = regex.find(compiled, subject, -1)
    test.equal(start_idx, 10)
    test.equal(end_idx, 10)
    test.equal(capture, "9")

    start_idx, end_idx, capture = regex.find(compiled, subject, -10)
    test.equal(start_idx, 1)
    test.equal(end_idx, 1)
    test.equal(capture, "0")

    start_idx, end_idx, capture = regex.find(compiled, subject, -100)
    test.equal(start_idx, 1)
    test.equal(end_idx, 1)
    test.equal(capture, "0")
  end)

  test.test("handles negative offsets for offset-returning regex APIs", function()
    local subject = "0123456789"

    local start_idx, end_idx, cap_start, cap_end =
      regex.find_offsets("(.)", subject, -1)
    test.equal(start_idx, 10)
    test.equal(end_idx, 11)
    test.equal(cap_start, 10)
    test.equal(cap_end, 10)

    local whole_start, whole_end, capture_start, capture_end =
      regex.cmatch("(.)", subject, -1)
    test.equal(whole_start, 10)
    test.equal(whole_end, 11)
    test.equal(capture_start, 10)
    test.equal(capture_end, 11)
  end)

  test.test("handles negative offsets for match and gmatch", function()
    local subject = "0123456789"

    test.equal(regex.match("(.)", subject, -1), "9")

    local items = {}
    for item in regex.gmatch("(.)", subject, -2) do
      items[#items + 1] = item
    end
    test.same(items, { "8", "9" })
  end)
  test.test("returns no match for offsets past the subject", function()
    for _, name in ipairs({"find", "find_offsets", "cmatch", "match"}) do
      for _, pattern in ipairs({".", test.not_nil(regex.compile("."))}) do
        test.is_nil(regex[name](pattern, "a", 100))
        test.is_nil(regex[name](pattern, "", 100))
        test.is_nil(regex[name](pattern, "a", 2 ^ 40))
      end
      test.not_nil(regex[name]("$", "a", 2))
    end
    local iter = regex.gmatch(".", "a", 100)
    test.is_nil(iter())
    test.is_nil(iter())
  end)

  test.test("can repeatedly call exhausted and failed iterators", function()
    for _, pattern in ipairs({"x", test.not_nil(regex.compile("x"))}) do
      local iter = regex.gmatch(pattern, "x")
      test.equal(iter(), "x")
      for _ = 1, 3 do test.is_nil(iter()) end
      iter = regex.gmatch(pattern, "")
      for _ = 1, 3 do test.is_nil(iter()) end
    end
    local iter = regex.gmatch(".", string.char(255))
    test.error(iter, "regex matching error")
    test.is_nil(iter())
  end)

  test.test("advances iterators by whole matches and UTF-8 characters", function()
    local iter = regex.gmatch("(a)b", "ab ab")
    test.equal(iter(), "a")
    test.equal(iter(), "a")
    test.is_nil(iter())
    iter = regex.gmatch("", "é")
    test.equal(iter(), 1)
    test.equal(iter(), 3)
    test.is_nil(iter())
  end)

  test.test("cleans up abandoned iterators and caught matching errors", function()
    for _ = 1, 20 do
      local iter = regex.gmatch("x", "xxx")
      test.equal(iter(), "x")
      for _, name in ipairs({"find", "find_offsets", "cmatch", "match"}) do
        test.error(function() regex[name](".", string.char(255)) end,
          "regex matching error")
        test.error(function() regex[name](".", {}) end)
      end
    end
    collectgarbage("forcecollect")
  end)

  test.test("limits replacements without leaking intermediate subjects", function()
    for _, pattern in ipairs({"a", test.not_nil(regex.compile("a"))}) do
      for _, case in ipairs({
        {"ab", "x", 2, "xb", 1},
        {"aba", "xx", 1, "xxba", 1},
        {"aba", "", 3, "b", 2},
        {"bbb", "x", 2, "bbb", 0},
        {"aaa", string.rep("x", 2048), 2, string.rep("x", 4096) .. "a", 2}
      }) do
        local result, count = regex.gsub(pattern, case[1], case[2], case[3])
        test.equal(result, case[4])
        test.equal(count, case[5])
      end
    end
    local result, count = regex.gsub("", "é", "x", 10)
    test.equal(result, "xéx")
    test.equal(count, 2)
    test.error(function() regex.gsub("a", "a", "$2", 1) end,
      "regex substitute error")
  end)
  test.test("returns many captures with correct subject offsets", function()
    local compiled = test.not_nil(regex.compile(string.rep("(a)", 32)))
    local subject = "--" .. string.rep("a", 32)
    local found = {compiled:find(subject, 3)}
    test.equal(#found, 34)
    test.equal(found[1], 3)
    test.equal(found[2], 34)
    for i = 3, #found do test.equal(found[i], "a") end
    local matched = {compiled:match(subject, 3)}
    test.equal(#matched, 32)
    for _, capture in ipairs(matched) do test.equal(capture, "a") end
    local offsets = {compiled:cmatch(subject, 3)}
    test.equal(#offsets, 66)
    test.equal(offsets[1], 3)
    test.equal(offsets[2], 35)
    test.equal(offsets[65], 34)
    test.equal(offsets[66], 35)
    local iter = compiled:gmatch(subject, 3)
    local captures = {iter()}
    test.equal(#captures, 32)
    for _, capture in ipairs(captures) do test.equal(capture, "a") end
    test.is_nil(iter())
    test.is_nil(iter())
  end)
  test.test("preserves UTF-8 validation and iterator end matches", function()
    local iter = regex.gmatch("a|$", "a")
    test.equal(iter(), "a")
    test.equal(iter(), 2)
    test.is_nil(iter())
    iter = regex.gmatch("(?<=é).", "éxéy", 3)
    test.equal(iter(), "x")
    test.equal(iter(), "y")
    test.is_nil(iter())
    iter = regex.gmatch(".", string.char(255) .. "ab", 2)
    test.equal(iter(), "a")
    test.equal(iter(), "b")
    test.is_nil(iter())
    iter = regex.gmatch("[a-z]+", "alpha " .. string.char(255))
    test.error(iter, "regex matching error")
    test.is_nil(iter())
    for _, pattern in ipairs({"\\C", test.not_nil(regex.compile("\\C"))}) do
      iter = regex.gmatch(pattern, "é")
      test.equal(iter(), string.char(195))
      test.error(iter, "regex matching error")
      test.is_nil(iter())
    end
  end)

  test.test("releases replacement buffers across heap and stack transitions", function()
    local result, count = regex.gsub("a{1000}", string.rep("a", 2200), "", 3)
    test.equal(result, string.rep("a", 200))
    test.equal(count, 2)
    result, count = regex.gsub("a+", "aaa-b", string.rep("x", 2048), 2)
    test.equal(result, string.rep("x", 2048) .. "-b")
    test.equal(count, 1)
  end)
  test.test("validates short UTF-8 subjects at word boundaries", function()
    for _, len in ipairs({0, 1, 7, 8, 9, 63, 64, 65}) do
      local subject = string.rep("a", len)
      if len > 0 then
        test.equal(regex.match("a+", subject), subject)
        test.equal(regex.match("(a+)", string.char(255) .. subject, 2), subject)
      else
        test.is_nil(regex.match("a+", subject))
      end
      test.error(function() regex.match("a*", subject .. string.char(255)) end,
        "regex matching error")
    end
    test.equal(regex.match("(.)", "é"), "é")
    test.equal(regex.match(".", string.char(0)), string.char(0))
  end)
end)

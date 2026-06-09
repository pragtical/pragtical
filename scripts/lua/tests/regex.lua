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
end)

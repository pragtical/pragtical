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
    test["nil"](compiled)
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
end)

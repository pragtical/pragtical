local test = require "core.test"

test.describe("diff", function()
  test.test("exports the documented functions", function()
    for _, name in ipairs({"split", "inline_diff", "diff", "diff_iter"}) do
      test.type(diff[name], "function", "missing diff." .. name)
    end
  end)

  test.test("splits strings by chars and lines", function()
    test.same(diff.split("abc", "char"), {"a", "b", "c"})
    test.same(diff.split("a\nb\n", "line"), {"a", "b", ""})
  end)

  test.test("returns change objects and iterable diffs", function()
    local changes = diff.diff({"one", "two"}, {"one", "three"})
    test.type(changes, "table")
    test.ok(#changes >= 1)
    test.type(changes[1].tag, "string")

    local iter_changes = {}
    for change in diff.diff_iter({"one", "two"}, {"one", "three"}) do
      table.insert(iter_changes, change)
    end
    test.equal(#iter_changes, #changes)

    local inline_changes = diff.inline_diff("cat", "cot")
    test.type(inline_changes, "table")
    test.ok(#inline_changes >= 1)
    test.type(inline_changes[1].tag, "string")
  end)
end)

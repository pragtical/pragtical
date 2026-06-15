local test = require "core.test"
local Doc = require "core.doc"
local search = require "core.doc.search"

local function make_doc(lines)
  local doc = Doc(nil, nil, true)
  doc.lines = lines
  doc.cache.col_x = {}
  doc.cache.ulen = {}
  doc.highlighter:reset()
  return doc
end

test.describe("core.doc.search", function()
  test.test("finds unicode case-insensitive plain matches forward", function()
    local doc = make_doc({
      "Мы мы МЫ МЫ\n",
      "мы Мы МЫ мы\n",
      "Мы Мы мы Мы\n"
    })

    local expected = {
      {1, 1, 1, 5},
      {1, 6, 1, 10},
      {1, 11, 1, 15},
      {1, 16, 1, 20},
      {2, 1, 2, 5},
      {2, 6, 2, 10},
      {2, 11, 2, 15},
      {2, 16, 2, 20},
      {3, 1, 3, 5},
      {3, 6, 3, 10},
      {3, 11, 3, 15},
      {3, 16, 3, 20},
    }

    local line, col = 1, 1
    for _, match in ipairs(expected) do
      local line1, col1, line2, col2 = search.find(
        doc, line, col, "Мы", { no_case = true }
      )
      test.same({line1, col1, line2, col2}, match)
      line, col = line2, col2
    end
  end)

  test.test("finds unicode case-insensitive plain matches backward", function()
    local doc = make_doc({
      "Мы мы МЫ МЫ\n",
      "мы Мы МЫ мы\n",
      "Мы Мы мы Мы\n"
    })

    local expected = {
      {3, 16, 3, 20},
      {3, 11, 3, 15},
      {3, 6, 3, 10},
      {3, 1, 3, 5},
      {2, 16, 2, 20},
      {2, 11, 2, 15},
      {2, 6, 2, 10},
      {2, 1, 2, 5},
      {1, 16, 1, 20},
      {1, 11, 1, 15},
      {1, 6, 1, 10},
      {1, 1, 1, 5},
    }

    local line, col = 3, #doc.lines[3]
    for _, match in ipairs(expected) do
      local line1, col1, line2, col2 = search.find(
        doc, line, col, "Мы", { no_case = true, reverse = true }
      )
      test.same({line1, col1, line2, col2}, match)
      line, col = line1, col1
    end
  end)
end)

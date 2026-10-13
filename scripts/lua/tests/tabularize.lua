local core = require "core"
local command = require "core.command"
local Doc = require "core.doc"
local DocView = require "core.docview"
local test = require "core.test"

require "plugins.tabularize"

---Create a document and activate its view for the Tabularize command.
---@param context table Test state holding documents to close afterward
---@param text string Document contents
---@return core.doc doc Document to tabularize
local function document(context, text)
  local doc = Doc(nil, nil, true)
  context.docs[#context.docs + 1] = doc
  doc:insert(1, 1, text)
  core.active_view = DocView(doc)
  return doc
end

---Run the command and submit its delimiter prompt without displaying the input.
---@param context table Test state holding the captured prompt options
---@param delimiter string Separator submitted to Tabularize
local function tabularize(context, delimiter)
  context.prompt = nil
  test.ok(command.perform("tabularize:tabularize"))
  test.not_nil(context.prompt)
  context.prompt.submit(delimiter)
end

test.describe("tabularize", function()
  test.before_each(function(context)
    context.active = core.active_view
    context.enter = core.command_view.enter
    context.docs = {}
    core.command_view.enter = function(_, _, options)
      context.prompt = options
    end
  end)

  test.after_each(function(context)
    core.active_view = context.active
    core.command_view.enter = context.enter
    for _, doc in ipairs(context.docs) do doc:on_close() end
  end)

  for _, reverse in ipairs { false, true } do
    test.test("preserves Markdown table borders with a "
      .. (reverse and "reversed" or "forward") .. " selection", function(context)
      local lines = {
        "## Important paths",
        "",
        "| Path | Purpose |",
        "| --- | --- |",
        "| `src/` | Native application code |",
        "| `data/` | Core Lua modules, plugins, colors, fonts, and runtime data |",
        "| `scripts/` | Build, run, package, and helper scripts |",
        "| `docs/` | User and developer documentation |",
        "| `docs/memories/` | Agent knowledge base, one Markdown file per subject |",
        "| `resources/cross/` | Cross-compilation files |",
        "| `subprojects/` | Meson subprojects and bundled dependencies |",
        "| `changelog.md` | Release-facing change log |"
      }
      local doc = document(context,
        "Before\n" .. table.concat(lines, "\n") .. "\n\nAfter")
      local last = #lines + 1
      doc:set_selection(2, 1, last, #lines[#lines] + 1, reverse)

      tabularize(context, "|")

      test.equal(doc.lines[1], "Before\n")
      test.equal(doc.lines[2], lines[1] .. "\n")
      test.equal(doc.lines[3], "\n")
      test.equal(doc.lines[last + 1], "\n")
      test.equal(doc.lines[last + 2], "After\n")
      local borders
      for line = 4, last do
        local positions = {}
        for position in doc.lines[line]:gmatch("()|") do
          positions[#positions + 1] = position
        end
        test.equal(#positions, 3, "Missing table border on line " .. line)
        test.equal(positions[1], 1)
        if borders then test.same(positions, borders) end
        borders = positions
      end
      test.match(doc.lines[last], "Release%-facing change log%s*|\n$")
    end)
  end

  for _, case in ipairs {
    {
      name = "leading, consecutive and trailing empty columns",
      delimiter = "|",
      text = "|a||b|\n|long|mid|tail|",
      expected = "|a   |   |b   |\n|long|mid|tail|"
    },
    {
      name = "headings and blank lines without affecting column widths",
      delimiter = "|",
      text = "Heading without columns\n\n|a|b|\n|long|tail|",
      expected = "Heading without columns\n\n|a   |b   |\n|long|tail|"
    },
    {
      name = "a trailing newline independently of the closing separator",
      delimiter = "|",
      text = "|a|b|\n|long|tail|\n",
      expected = "|a   |b   |\n|long|tail|\n"
    },
    {
      name = "empty comma-separated columns",
      delimiter = ",",
      text = "one,,\nlong,middle,last",
      expected = "one ,      ,\nlong,middle,last"
    },
    {
      name = "the default whitespace delimiter",
      delimiter = "",
      text = "a   b\nlonger two",
      expected = "a      b\nlonger two"
    },
    {
      name = "separator spacing supplied with the delimiter",
      delimiter = ", ",
      text = "a,b\nlong,tail",
      expected = "a   , b\nlong, tail"
    }
  } do
    test.test("preserves " .. case.name, function(context)
      local doc = document(context, case.text)
      doc:set_selection(1, 1, math.huge, math.huge)
      tabularize(context, case.delimiter)
      test.equal(doc:get_text(1, 1, math.huge, math.huge), case.expected)
    end)
  end

  for _, delimiter in ipairs { "%", "]", "-" } do
    test.test("treats " .. delimiter .. " as a literal separator", function(context)
      local doc = document(context,
        delimiter .. "a" .. delimiter .. "\n"
        .. delimiter .. "long" .. delimiter)
      doc:set_selection(1, 1, math.huge, math.huge)
      tabularize(context, delimiter)
      test.equal(doc:get_text(1, 1, math.huge, math.huge),
        delimiter .. "a   " .. delimiter .. "\n"
        .. delimiter .. "long" .. delimiter)
    end)
  end

  test.test("does not add spacing on a second pass", function(context)
    local doc = document(context, "|a||b|\n|long|mid|tail|")
    doc:set_selection(1, 1, math.huge, math.huge)
    tabularize(context, "|")
    local first = doc:get_text(1, 1, math.huge, math.huge)
    tabularize(context, "|")
    test.equal(doc:get_text(1, 1, math.huge, math.huge), first)
  end)
end)

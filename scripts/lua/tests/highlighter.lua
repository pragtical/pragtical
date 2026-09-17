local test = require "core.test"
local core = require "core"
local Doc = require "core.doc"
local tokenizer = require "core.tokenizer"

local function drain(context)
  for _, thread in ipairs(context.threads) do
    while coroutine.status(thread) ~= "dead" do
      local ok, err = coroutine.resume(thread)
      assert(ok, err)
    end
  end
end

for _, native in ipairs { false, true } do
  test.describe("highlighter first_line native=" .. tostring(native), function()
    test.before_each(function(context)
      context.native = tokenizer.is_using_native()
      context.add_thread = core.add_thread
      context.max_time = core.co_max_time
      context.redraw = core.redraw
      context.threads = {}
      core.add_thread = function(fn)
        context.threads[#context.threads + 1] = coroutine.create(fn)
      end
      tokenizer.set_use_native(native)
      local doc = Doc(nil, nil, true)
      context.doc = doc
      doc.lines = { "head\n", "head\n", "tail\n" }
      doc.syntax = { patterns = {
        { pattern = "head", first_line = true, type = "keyword" },
        { pattern = "%a+", type = "symbol" },
      }, symbols = {} }
    end)

    test.after_each(function(context)
      context.doc:on_close()
      core.add_thread = context.add_thread
      core.redraw = context.redraw
      core.co_max_time = context.max_time
      tokenizer.set_use_native(context.native)
    end)

    for _, background in ipairs { false, true } do
      test.test("insertion, deletion and undo update cached eligibility, background=" .. tostring(background), function(context)
        local doc = context.doc
        local highlighter = doc.highlighter
        for i = 1, #doc.lines do highlighter:get_line(i) end
        drain(context)
        test.equal(highlighter:get_line(1).tokens[1], "keyword")
        local later = highlighter.lines[2]

        local function refresh()
          if background then
            highlighter.max_wanted_line = #doc.lines
            highlighter:start()
            drain(context)
          end
        end

        doc:insert(1, 1, "\n")
        refresh()
        test.equal(highlighter:get_line(2).tokens[1], "symbol")
        test.equal(highlighter.lines[3], later)
        doc:undo()
        refresh()
        test.equal(highlighter:get_line(1).tokens[1], "keyword")
        doc:clear_undo_redo()
        doc:remove(1, 1, 2, 1)
        refresh()
        test.equal(highlighter:get_line(1).tokens[1], "keyword")
        doc:undo()
        refresh()
        test.equal(highlighter:get_line(2).tokens[1], "symbol")
      end)
    end

    test.test("background discards a moved first-line resume", function(context)
      local doc = context.doc
      local highlighter = doc.highlighter
      doc.lines[1] = string.rep("head", 100) .. "\n"
      -- Force both backends to yield independently of clock resolution.
      core.co_max_time = -1
      highlighter:get_line(1)
      test.type(highlighter.lines[1].resume, "table")
      core.co_max_time = context.max_time
      doc:insert(1, 1, "\n")
      highlighter.max_wanted_line = #doc.lines
      drain(context)
      test.equal(highlighter:get_line(2).tokens[1], "symbol")
      test.is_nil(highlighter.lines[2].resume)
    end)
  end)
end

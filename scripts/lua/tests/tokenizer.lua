local test = require "core.test"
local config = require "core.config"
local tokenizer = require "core.tokenizer"

local function collect_each_token(tokens, scol)
  local items = {}
  for _, type, text in tokenizer.each_token(tokens, scol) do
    table.insert(items, { type, text })
  end
  return items
end

test.describe("tokenizer", function()
  test.test("toggles the native module while keeping each_token", function()
    local original = config.native_tokenizer
    local syntax = {
      patterns = {
        { pattern = "%d+", type = "number" }
      },
      symbols = {}
    }
    config.native_tokenizer = true
    test.ok(tokenizer.set_use_native(true))
    test.equal(tokenizer.is_using_native(), true)
    tokenizer.tokenize(syntax, "123", string.char(0))
    test.type(tokenizer._tokenizer_native_text_arena, "userdata")
    test.type(tokenizer._tokenizer_native_token_arena, "userdata")
    tokenizer.set_use_native(false)
    test.equal(tokenizer.is_using_native(), false)
    test.equal(tokenizer._tokenizer_native_text_arena, nil)
    test.equal(tokenizer._tokenizer_native_token_arena, nil)
    tokenizer.set_use_native(true)
    test.equal(tokenizer.is_using_native(), true)
    config.native_tokenizer = original
    tokenizer.set_use_native(original ~= false)
    test.type(tokenizer.each_token, "function")
  end)

  test.test("clears cached native syntax userdata", function()
    local nested = {
      patterns = {
        { pattern = "%d+", type = "number" }
      },
      symbols = {}
    }
    local syntax = {
      patterns = {
        { pattern = { '"', '"' }, type = "string", syntax = nested },
        { pattern = "[%a_]+", type = "symbol" }
      },
      symbols = {}
    }

    tokenizer.set_use_native(true)
    tokenizer.tokenize(syntax, [["123"]], string.char(0))
    test.type(tokenizer._tokenizer_native_text_arena, "userdata")
    test.type(tokenizer._tokenizer_native_token_arena, "userdata")
    test.type(syntax._tokenizer_native_cache, "userdata")
    test.type(nested._tokenizer_native_cache, "userdata")

    tokenizer.clear_native_cache(syntax)
    test.equal(syntax._tokenizer_native_cache, nil)
    test.equal(nested._tokenizer_native_cache, nil)
  end)

  test.test("tokenizes regex captures and preserves token merging", function()
    local syntax = {
      patterns = {
        { regex = "0()[0-7]+", type = { "keyword", "number" } },
        { pattern = "%s+", type = "normal" },
        { pattern = "[%a_]+", type = "keyword" }
      },
      symbols = {}
    }

    local tokens, state = tokenizer.tokenize(syntax, "077 foo", string.char(0))
    test.equal(state, string.char(0))
    test.same(tokens, {
      "keyword", "0",
      "number", "77",
      "keyword", " foo"
    })
  end)

  test.test("keeps regex matches after normal text", function()
    local syntax = {
      patterns = {
        { regex = [[-?\d+]], type = "number" },
        { pattern = "[=]", type = "operator" },
        { pattern = "[%a_][%w_]*", type = "symbol" }
      },
      symbols = {}
    }
    local using_native = tokenizer.is_using_native()

    tokenizer.set_use_native(true)
    local tokens, state = tokenizer.tokenize(syntax, "(3==value", string.char(0))
    tokenizer.set_use_native(using_native)

    test.equal(state, string.char(0))
    test.same(tokens, {
      "normal", "(",
      "number", "3",
      "operator", "==",
      "symbol", "value"
    })
  end)

  test.test("tokenizes lua patterns with multiple position captures", function()
    local syntax = {
      patterns = {
        {
          pattern = "static()%s+()const",
          type = { "keyword", "normal", "keyword" }
        }
      },
      symbols = {}
    }

    local tokens, state = tokenizer.tokenize(syntax, "static const", string.char(0))
    test.equal(state, string.char(0))
    test.same(tokens, {
      "keyword", "static",
      "keyword", " const"
    })
  end)

  test.test("tokenizes common language pattern shapes with native fast paths", function()
    local syntax = {
      patterns = {
        { pattern = "//.*", type = "comment" },
        { pattern = { "/%*", "%*/" }, type = "comment" },
        { pattern = { '"', '"', '\\' }, type = "string" },
        { pattern = "[%+%-=/%*]", type = "operator" },
        { pattern = "[%a_][%w_]*", type = "symbol" },
      },
      symbols = {
        ["let"] = "keyword"
      }
    }
    local using_native = tokenizer.is_using_native()

    tokenizer.set_use_native(true)
    local tokens, state = tokenizer.tokenize(
      syntax,
      [[let value = "text" // trailing]],
      string.char(0)
    )
    tokenizer.set_use_native(using_native)

    test.equal(state, string.char(0))
    test.same(tokens, {
      "keyword", "let",
      "symbol", " value",
      "operator", " =",
      "string", ' "text"',
      "comment", " // trailing"
    })
  end)

  test.test("reports native syntax compilation stats", function()
    local syntax = {
      patterns = {
        { pattern = "[%a_][%w_]*", type = "symbol" },
        { regex = [[\d+]], type = "number" },
        { pattern = "%s+", type = "normal" },
      },
      symbols = {}
    }
    local using_native = tokenizer.is_using_native()

    tokenizer.set_use_native(true)
    tokenizer.tokenize(syntax, "name 123", string.char(0))
    local stats = tokenizer.get_syntax_stats(syntax)
    tokenizer.set_use_native(using_native)

    test.type(stats, "table")
    test.equal(stats.patterns, 3)
    test.type(stats.compiled_patterns, "number")
    test.type(stats.fallback_patterns, "number")
    test.type(stats.skipped_by_starter, "number")
    test.type(stats.pattern_stats, "table")
    test.equal(#stats.pattern_stats, 3)
  end)

  test.test("keeps non-ascii identifiers on the utf8 pattern fallback", function()
    local syntax = {
      patterns = {
        { pattern = "[%a_][%w_]*", type = "symbol" },
        { pattern = "[%+%-=]", type = "operator" }
      },
      symbols = {}
    }
    local using_native = tokenizer.is_using_native()

    tokenizer.set_use_native(true)
    local tokens, state = tokenizer.tokenize(syntax, "café = año", string.char(0))
    tokenizer.set_use_native(using_native)

    test.equal(state, string.char(0))
    test.same(tokens, {
      "symbol", "café",
      "operator", " =",
      "symbol", " año"
    })
  end)

  test.test("keeps optional leading lua pattern atoms searchable", function()
    local syntax = {
      patterns = {
        { pattern = "%.?%d+", type = "number" },
        { pattern = "[%a_][%w_]*", type = "symbol" },
        { pattern = "%s+", type = "normal" },
      },
      symbols = {}
    }
    local using_native = tokenizer.is_using_native()

    tokenizer.set_use_native(true)
    local tokens, state = tokenizer.tokenize(syntax, "value 1 .2", string.char(0))
    tokenizer.set_use_native(using_native)

    test.equal(state, string.char(0))
    test.same(tokens, {
      "symbol", "value",
      "number", " 1",
      "number", " .2"
    })
  end)

  test.test("tokenizes balanced quoted strings with matching delimiters", function()
    local syntax = {
      patterns = {
        {
          pattern = "@type%s+()%b\"\"",
          type = { "annotation", "annotation.string" }
        },
        {
          pattern = "|%s*()%b\"\"",
          type = { "annotation.operator", "annotation.string" }
        },
        { pattern = "[%w%p]+", type = "comment" }
      },
      symbols = {}
    }
    local using_native = tokenizer.is_using_native()

    tokenizer.set_use_native(true)
    local tokens, state = tokenizer.tokenize(syntax, '@type "all" | "background"', string.char(0))
    tokenizer.set_use_native(using_native)

    test.equal(state, string.char(0))
    test.same(tokens, {
      "annotation", "@type ",
      "annotation.string", '"all"',
      "annotation.operator", " | ",
      "annotation.string", '"background"'
    })
  end)

  test.test("tokenizes balanced parentheses in Lua patterns", function()
    local syntax = {
      patterns = {
        { pattern = "fun%s*%b()", type = "annotation.type" },
        { pattern = "[%w%p]+", type = "comment" }
      },
      symbols = {}
    }
    local using_native = tokenizer.is_using_native()

    tokenizer.set_use_native(true)
    local tokens, state = tokenizer.tokenize(
      syntax,
      'fun(status: "accept"|"cancel", result: string[]|string|nil)',
      string.char(0)
    )
    tokenizer.set_use_native(using_native)

    test.equal(state, string.char(0))
    test.same(tokens, {
      "annotation.type", 'fun(status: "accept"|"cancel", result: string[]|string|nil)'
    })
  end)

  test.test("does not close subsyntax on escaped delimiters", function()
    local string_syntax = {
      patterns = {
        { pattern = "%$[%a_][%w_]*", type = "keyword2" },
        { pattern = "[^\"]", type = "string" },
        { pattern = "%p", type = "string" }
      },
      symbols = {}
    }
    local syntax = {
      patterns = {
        { pattern = { '"', '"', '\\' }, type = "string", syntax = string_syntax }
      },
      symbols = {}
    }

    local tokens, state = tokenizer.tokenize(syntax, [["$name=\"$value\" "]], string.char(0))
    test.equal(state, string.char(0))
    test.same(tokens, {
      "string", '"',
      "keyword2", "$name",
      "string", '=\\"',
      "keyword2", "$value",
      "string", '\\" "'
    })
  end)

  test.test("handles zero-width regex subsyntax openers at line start", function()
    local signature_syntax = {
      patterns = {
        { pattern = "[%a_][%w_]*", type = "symbol" }
      },
      symbols = {
        ["function"] = "keyword"
      }
    }
    local syntax = {
      patterns = {
        {
          regex = { [[(?=function\s+[a-z_][a-z0-9_]*\s*\()]], [[\)]] },
          type = "normal",
          syntax = signature_syntax
        },
        { pattern = "[%a_][%w_]*", type = "normal" }
      },
      symbols = {}
    }

    local tokens, state = tokenizer.tokenize(syntax, "function demo(", string.char(0))
    test.equal(state, string.char(1))
    test.same(tokens, {
      "keyword", "function",
      "symbol", " demo",
      "normal", "("
    })
  end)

  test.test("closes zero-width regex subsyntax on the same line", function()
    local signature_syntax = {
      patterns = {
        { pattern = "[%a_][%w_]*", type = "symbol" }
      },
      symbols = {
        ["function"] = "keyword"
      }
    }
    local syntax = {
      patterns = {
        {
          regex = {
            [[(?=function\s+[a-zA-Z_][a-zA-Z0-9_\.:]*\s*\()]],
            [[\)]]
          },
          type = "normal",
          syntax = signature_syntax
        },
        { pattern = "[%a_][%w_]*", type = "normal" }
      },
      symbols = {}
    }
    local using_native = tokenizer.is_using_native()

    tokenizer.set_use_native(true)
    local tokens, state = tokenizer.tokenize(
      syntax,
      "function Highlighter:reset()\n",
      string.char(0)
    )
    tokenizer.set_use_native(using_native)

    test.equal(state, string.char(0))
    test.same(tokens, {
      "keyword", "function",
      "symbol", " Highlighter",
      "normal", ":",
      "symbol", "reset",
      "normal", "()\n"
    })
  end)

  test.test("tracks subsyntax state and extracts subsyntaxes", function()
    local inner = {
      name = "inner",
      patterns = {
        { pattern = { '"', '"', '\\' }, type = "string" }
      },
      symbols = {}
    }
    local syntax = {
      name = "outer",
      patterns = {
        { pattern = { "%[", "%]" }, type = "operator", syntax = inner }
      },
      symbols = {}
    }

    local open_tokens, open_state = tokenizer.tokenize(syntax, "[", string.char(0))
    test.same(open_tokens, { "operator", "[" })
    test.equal(open_state, string.char(1))

    local syntaxes = tokenizer.extract_subsyntaxes(syntax, open_state)
    test.equal(#syntaxes, 1)
    test.equal(syntaxes[1], inner)

    local close_tokens, close_state = tokenizer.tokenize(syntax, "]", open_state)
    test.same(close_tokens, { "operator", "]" })
    test.equal(close_state, string.char(0))
  end)

  test.test("supports resuming from incomplete tokenization", function()
    local syntax = {
      patterns = { { pattern = "%a+", type = "keyword" } },
      symbols = {}
    }
    local original_co_max_time = core.co_max_time
    -- Force a timeout even when the native clock has not advanced.
    core.co_max_time = -1

    local text = string.rep("a", 256)
    local partial_tokens, partial_state, resume = tokenizer.tokenize(syntax, text, string.char(0))

    core.co_max_time = original_co_max_time

    test.equal(partial_state, string.char(0))
    test.type(resume, "table")
    test.equal(partial_tokens[#partial_tokens - 1], "incomplete")

    local final_tokens, final_state = tokenizer.tokenize(syntax, text, partial_state, resume)
    test.same(final_tokens, { "keyword", text })
    test.equal(final_state, string.char(0))
  end)

  test.test("iterates token slices with each_token", function()
    local items = collect_each_token({ "keyword", "abc", "normal", " def" }, 3)
    test.same(items, {
      { "keyword", "c" },
      { "normal", " def" }
    })

    items = collect_each_token({ "keyword", "abc", "normal", " def" }, 4)
    test.same(items, {
      { "normal", " def" }
    })

    items = collect_each_token({ "keyword", "abc", "normal", " def" }, 6)
    test.same(items, {
      { "normal", "ef" }
    })

    items = collect_each_token({ "keyword", "abc", "normal", " def" }, 8)
    test.same(items, {})
  end)
end)

for _, native in ipairs { false, true } do
  test.describe("tokenizer first_line (" .. (native and "native" or "Lua") .. ")", function()
    test.before_each(function(context)
      context.native = tokenizer.is_using_native()
      context.max_time = core.co_max_time
      tokenizer.set_use_native(native)
    end)

    test.after_each(function(context)
      core.co_max_time = context.max_time
      tokenizer.set_use_native(context.native)
    end)

    for _, matcher in ipairs { "pattern", "regex" } do
      test.test(matcher .. " restricts starts without imposing a column", function()
        local syn = { patterns = {
          { [matcher] = "@", first_line = true, type = "keyword" },
          { pattern = "@", first_line = false, type = "symbol" },
        }, symbols = {} }
        -- Emulate a plugin that forwards exactly the original four arguments.
        local function forward(syntax, text, state, resume)
          return tokenizer.tokenize(syntax, text, state, resume)
        end
        local tokens, state = forward(syn, "x@@", nil, { first_line = true })
        test.same(tokens, { "normal", "x", "keyword", "@@" })
        test.equal(state, string.char(0))
        for _, options in ipairs { {}, { first_line = false } } do
          test.same(forward(syn, "x@@", nil, options),
            { "normal", "x", "symbol", "@@" })
        end
        test.same(forward(syn, "x@@"), { "normal", "x", "symbol", "@@" })
      end)

      for _, embedded in ipairs { false, true } do
        test.test(matcher .. " multiline pair, embedded=" .. tostring(embedded), function()
          local syn = { patterns = {
            {
              [matcher] = { "^BEGIN", "^END", "\\" },
              first_line = true, type = "string",
              syntax = embedded and {
                patterns = { { pattern = "%d+", type = "number" } }, symbols = {}
              } or nil
            }
          }, symbols = {} }
          local tokens, state = tokenizer.tokenize(syn, "BEGIN\n", nil, { first_line = true })
          test.equal(state:byte(1), 1)
          tokens, state = tokenizer.tokenize(syn, "123\n", state)
          test.equal(tokens[1], embedded and "number" or "string")
          test.equal(state:byte(1), 1)
          tokens, state = tokenizer.tokenize(syn, "END\n", state)
          test.equal(state:byte(1), 0)
          tokens, state = tokenizer.tokenize(syn, "BEGIN\n", state)
          test.equal(tokens[1], "normal")
          test.equal(state:byte(1), 0)
        end)
      end
    end

    if not native then
      test.test("escaped first-line openers are skipped before a valid opener", function()
        local syn = { patterns = {
          { pattern = { "@", "@", "\\" }, first_line = true, type = "string" },
        }, symbols = {} }
        local text = "\\@x@body@"
        local tokens, state = tokenizer.tokenize(syn, text, nil, { first_line = true })
        test.same(tokens, { "normal", "\\@x", "string", "@body@" })
        test.equal(state, string.char(0))
        test.same(tokenizer.tokenize(syn, text), { "normal", text })
      end)
    end

    test.test("nested syntaxes inherit document position", function()
      local inner = { patterns = {
        { pattern = "@", first_line = true, type = "keyword" }
      }, symbols = {} }
      local syn = { patterns = {
        { pattern = { "<", ">" }, type = "string", syntax = inner }
      }, symbols = {} }
      local tokens = tokenizer.tokenize(syn, "<@>", nil, { first_line = true })
      test.same(tokens, { "string", "<", "keyword", "@", "string", ">" })
      tokens = tokenizer.tokenize(syn, "<@>")
      test.same(tokens, { "string", "<", "normal", "@", "string", ">" })
    end)

    test.test("filtered opening rules preserve original nested state indices", function()
      local syn = { patterns = {
        { pattern = "@", first_line = true, type = "keyword" },
        { pattern = { "<", ">" }, type = "string", syntax = {
          patterns = {
            { pattern = "@", first_line = true, type = "keyword" },
            { pattern = { '"', '"' }, type = "number" },
          }, symbols = {}
        } }
      }, symbols = {} }
      local _, state = tokenizer.tokenize(syn, '<"')
      test.equal(state, string.char(2, 2))
      local tokens
      tokens, state = tokenizer.tokenize(syn, '">', state)
      test.equal(state:byte(1), 0)
      test.same(tokens, { "number", '"', "string", ">" })
    end)

    test.test("clearing syntax caches picks up changed first_line flags", function()
      local syn = { patterns = {
        { pattern = "@", first_line = true, type = "keyword" },
      }, symbols = {} }
      test.same(tokenizer.tokenize(syn, "@"), { "normal", "@" })
      syn.patterns[1].first_line = false
      tokenizer.clear_native_cache(syn)
      test.same(tokenizer.tokenize(syn, "@"), { "keyword", "@" })
      syn.patterns[1].first_line = true
      tokenizer.clear_native_cache(syn)
      test.same(tokenizer.tokenize(syn, "@"), { "normal", "@" })
    end)

    test.test("raw and wrapped resumes preserve or override first-line context", function(context)
      for _, mode in ipairs { "raw", "wrapped", "override", "legacy" } do
        local syn = { patterns = {
          { pattern = "@+", first_line = true, type = "keyword" },
          { pattern = "@+", type = "symbol" }
        }, symbols = {} }
        -- Both backends must yield even if their clocks have not advanced.
        core.co_max_time = -1
        local text = string.rep("@", 256)
        local _, state, resume = tokenizer.tokenize(syn, text, nil, { first_line = true })
        core.co_max_time = context.max_time
        test.type(resume, "table")
        test.equal(resume.first_line, true)
        local options = resume
        if mode == "wrapped" then options = { resume = resume } end
        if mode == "override" then options = { resume = resume, first_line = false } end
        if mode == "legacy" then resume.first_line = nil end
        local tokens, final_state, pending = tokenizer.tokenize(syn, text, state, options)
        test.same(tokens, { (mode == "override" or mode == "legacy") and "symbol" or "keyword", text })
        test.equal(final_state, string.char(0))
        test.is_nil(pending)
      end
    end)

    test.test("frontmatter-style regions cannot reopen at later delimiters", function()
      local syn = { patterns = {
        {
          pattern = { "^%-%-%-%s*\n", "^%-%-%-%s*$" },
          first_line = true,
          type = "string",
          syntax = {
            patterns = { { pattern = "%a+", type = "symbol" } },
            symbols = {}
          }
        }
      }, symbols = {} }
      local state
      local lines = { "---\n", "title: example\n", "---\n", "text\n", "---\n", "ordinary text\n" }
      for i, line in ipairs(lines) do
        local tokens
        tokens, state = tokenizer.tokenize(syn, line, state, i == 1 and { first_line = true } or nil)
        if i == 1 or i == 2 then test.ok(state:byte(1) ~= 0) end
        if i >= 3 then test.equal(state:byte(1), 0) end
      end
    end)
  end)
end

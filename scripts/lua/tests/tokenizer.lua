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
    local original_get_time = system.get_time
    local original_co_max_time = core.co_max_time
    local tick = 0

    system.get_time = function()
      tick = tick + 1
      return tick
    end
    core.co_max_time = 0.0001

    local text = string.rep("a", 256)
    local partial_tokens, partial_state, resume = tokenizer.tokenize(syntax, text, string.char(0))

    system.get_time = original_get_time
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

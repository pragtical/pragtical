-- mod-version:3
local syntax = require "core.syntax"

-- integer suffix combinations as a regex
local isuf = [[(?:[lL][uU]|ll[uU]|LL[uU]|[uU][lL]\b|[uU]ll|[uU]LL|[uU]|[lL]\b|ll|LL)?]]
-- float suffix combinations as a Lua pattern / regex
local fsuf = "[fFlL]?"

syntax.add {
  name = "C",
  files = { "%.c$" },
  comment = "//",
  block_comment = { "/*", "*/" },
  symbol_pattern = "[%a_#][%w_]*",
  symbol_non_word_chars = " \t\n/\\()\"':,.;<>~!@$%^&*|+=[]{}`?-",
  patterns = {
    { pattern = "//.*",                  type = "comment" },
    { pattern = { "/%*", "%*/" },        type = "comment" },
    { pattern = { '"', '"', '\\' },      type = "string"  },
    { pattern = { "'", "'", '\\' },      type = "string"  },
    { regex   = "0x[0-9a-fA-f]+"..isuf,  type = "number"  },
    { regex   = "0()[0-7]+"..isuf,       type = { "keyword", "number" } },
    { pattern = "%d+%.%d*[Ee]%d+"..fsuf, type = "number"  },
    { pattern = "%d+[Ee]%d+"..fsuf,      type = "number"  },
    { pattern = "%d+%.%d*"..fsuf,        type = "number"  },
    { pattern = "%.%d+"..fsuf,           type = "number"  },
    { regex   = "\\d+"..isuf,            type = "number"  },
    { pattern = "[%+%-=/%*%^%%<>!~|&]",  type = "operator" },
    { pattern = "##",                    type = "operator" },
    { pattern = "struct%s()[%a_][%w_]*", type = {"keyword", "keyword2"} },
    { pattern = "enum%s()[%a_][%w_]*",   type = {"keyword", "keyword2"} },
    { pattern = "union%s()[%a_][%w_]*",  type = {"keyword", "keyword2"} },
    -- static declarations
    { pattern = "static()%s+()inline",
      type = { "keyword", "normal", "keyword" }
    },
    { pattern = "static()%s+()const",
      type = { "keyword", "normal", "keyword" }
    },
    { pattern = "static()%s+()[%a_][%w_]*",
      type = { "keyword", "normal", "literal" }
    },
    -- match single line type declarations (exclude keywords)
    { pattern = "^%s*_?%u[%u_][%u%d_]*%s*\n", -- skip uppercase constants
      type = "number"
    },
    { pattern = "^%s*()[%a_][%w_]*()%s*%*+()%s*\n", -- pointer
      type = { "normal", "literal", "operator", "normal" }
    },
    { pattern = "^%s*()[%a_][%w_]*()%s*\n", -- non-pointer
      type = { "normal", "literal", "normal" }
    },
    -- match function type declarations (exclude keywords)
    { pattern = "[%a_][%w_]*()%*+()%s+()[%a_][%w_]*()%s*%f[%(]",
      type = { "literal", "operator", "normal", "function", "normal" }
    },
    { pattern = "[%a_][%w_]*()%s+()%*+()[%a_][%w_]*()%s*%f[%(]",
      type = { "literal", "normal", "operator", "function", "normal" }
    },
    { pattern = "[%a_][%w_]*()%s+()[%a_][%w_]*()%s*%f[%(]",
      type = { "literal", "normal", "function", "normal" }
    },
    -- match variable type declarations
    { pattern = "[%a_][%w_]*()%*+()%s+()[%a_][%w_]*",
      type = { "literal", "operator", "normal", "normal" }
    },
    { pattern = "[%a_][%w_]*()%s+()%*+()[%a_][%w_]*",
      type = { "literal", "normal", "operator", "normal" }
    },
    { pattern = "[%a_][%w_]*()%s+()[%a_][%w_]*()%s*()[;,%[%)]",
      type = { "literal", "normal", "normal", "normal", "normal" }
    },
    { pattern = "^%s*()[%a_][%w_]*()%s+[%a_][%w_]*()%s*\n",
      type = { "normal", "literal", "normal", "normal" }
    },
    { pattern = "[%a_][%w_]*()%s+()[%a_][%w_]*()%s*()=",
      type = { "literal", "normal", "normal", "normal", "operator" }
    },
    { pattern = "[%a_][%w_]*()&()%s+()[%a_][%w_]*",
      type = { "literal", "operator", "normal", "normal" }
    },
    { pattern = "[%a_][%w_]*()%s+()&()[%a_][%w_]*",
      type = { "literal", "normal", "operator", "normal" }
    },
    -- Uppercase constants of at least 2 chars in len
    { pattern = "_?%u[%u_][%u%d_]*%s*%f[%(]", -- when used as function
      type = "number"
    },
    { pattern = "_?%u[%u_][%u%d_]*%f[%s%+%*%-%.%)%]}%?%^%%=/<>~|&;:,!]",
      type = "number"
    },
    -- Magic constants
    { pattern = "__[%u%l]+__",           type = "number"   },
    -- all other functions (excludes keywords)
    { pattern = "[%a_][%w_]*()%s*%f[(]", type = {"function", "normal"} },
    -- Macros
    { pattern = "^%s*#%s*define%s+()[%a_][%a%d_]*",
      type = { "keyword", "symbol" }
    },
    { pattern = "#%s*include%s()<.->",   type = {"keyword", "string"} },
    { pattern = "%f[#]#%s*[%a_][%w_]*",  type = "keyword"   },
    -- Everything else to make the tokenizer work properly
    { pattern = "[%a_][%w_]*",           type = "symbol" },
  },
  symbols = {
    ["if"]       = "keyword",
    ["then"]     = "keyword",
    ["else"]     = "keyword",
    ["elseif"]   = "keyword",
    ["do"]       = "keyword",
    ["while"]    = "keyword",
    ["for"]      = "keyword",
    ["break"]    = "keyword",
    ["continue"] = "keyword",
    ["return"]   = "keyword",
    ["goto"]     = "keyword",
    ["typedef"]  = "keyword",
    ["enum"]     = "keyword",
    ["extern"]   = "keyword",
    ["static"]   = "keyword",
    ["volatile"] = "keyword",
    ["const"]    = "keyword",
    ["inline"]   = "keyword",
    ["switch"]   = "keyword",
    ["case"]     = "keyword",
    ["default"]  = "keyword",
    ["auto"]     = "keyword",
    ["struct"]   = "keyword",
    ["union"]    = "keyword",
    ["void"]     = "keyword2",
    ["int"]      = "keyword2",
    ["short"]    = "keyword2",
    ["long"]     = "keyword2",
    ["float"]    = "keyword2",
    ["double"]   = "keyword2",
    ["char"]     = "keyword2",
    ["unsigned"] = "keyword2",
    ["bool"]     = "keyword2",
    ["true"]     = "literal",
    ["false"]    = "literal",
    ["NULL"]     = "literal",
    ["#include"] = "keyword",
    ["#if"] = "keyword",
    ["#ifdef"] = "keyword",
    ["#ifndef"] = "keyword",
    ["#elif"]    = "keyword",
    ["#else"] = "keyword",
    ["#elseif"] = "keyword",
    ["#endif"] = "keyword",
    ["#define"] = "keyword",
    ["#warning"] = "keyword",
    ["#error"] = "keyword",
    ["#pragma"] = "keyword",
  },
}

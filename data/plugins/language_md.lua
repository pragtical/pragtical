-- mod-version:3
local syntax = require "core.syntax"
local style = require "core.style"
local core = require "core"

local in_squares_match = "^%[%]"
local in_parenthesis_match = "^%(%)"

syntax.add {
  name = "Markdown",
  files = { "%.md$", "%.markdown$" },
  block_comment = { "<!--", "-->" },
  space_handling = false, -- turn off this feature to handle it our selfs
  patterns = {
  ---- Place patterns that require spaces at start to optimize matching speed
  ---- and apply the %s+ optimization immediately afterwards
    -- checkbox
    -- - [x]
    -- - [X]
    -- - [-] Partially done
    {
      pattern = "^%s*%-%s()%[()[xX%-]()%]",
      type = { "number", "comment", "string", "comment" },
    },
    -- - [ ]
    {
      pattern = "^%s*%-%s()%[%s+%]",
      type = { "number", "comment" }
    },
    -- bullets
    -- * example1
    -- - example2
    -- + example3
    { pattern = "^%s*%*%s",                 type = "number" },
    { pattern = "^%s*%-%s",                 type = "number" },
    { pattern = "^%s*%+%s",                 type = "number" },
    -- numbered bullet
    -- 1. example
    { pattern = "^%s*[0-9]+[%.%)]%s",       type = "number" },
    -- blockquote
    -- > example
    { pattern = "^%s*>+%s",                 type = "string" },
    -- alternative bold italic formats
    { pattern = { "%s___", "___" },         type = "markdown_bold_italic" },
    { pattern = { "%s__", "__" },           type = "markdown_bold" },
    { pattern = { "%s_[%S]", "_" },         type = "markdown_italic" },
    -- reference links
    -- [example]: https://example.com
    {
      pattern = "^%s*%[%^()["..in_squares_match.."]+()%]: ",
      type = { "function", "number", "function" }
    },
    -- [^note]: footnote
    {
      pattern = "^%s*%[%^?()["..in_squares_match.."]+()%]:%s+.*",
      type = { "function", "number", "function" }
    },
    -- optimization
    { pattern = "%s+",                      type = "normal" },

  ---- HTML rules imported and adapted from language_html
  ---- to not conflict with markdown rules
    -- Inline JS and CSS
    {
      pattern = {
      "<%s*[sS][cC][rR][iI][pP][tT]%s+[tT][yY][pP][eE]%s*=%s*" ..
        "['\"]%a+/[jJ][aA][vV][aA][sS][cC][rR][iI][pP][tT]['\"]%s*>",
      "<%s*/[sS][cC][rR][iI][pP][tT]>"
      },
      syntax = ".js",
      type = "function"
    },
    {
      pattern = {
      "<%s*[sS][cC][rR][iI][pP][tT]%s*>",
      "<%s*/%s*[sS][cC][rR][iI][pP][tT]>"
      },
      syntax = ".js",
      type = "function"
    },
    {
      pattern = {
      "<%s*[sS][tT][yY][lL][eE][^>]*>",
      "<%s*/%s*[sS][tT][yY][lL][eE]%s*>"
      },
      syntax = ".css",
      type = "function"
    },
    -- Comments
    -- <!-- example -->
    { pattern = { "<!%-%-", "%-%->" },   type = "comment" },
    -- Tags
    { pattern = "%f[^<]![%a_][%w_]*",    type = "keyword2" },
    { pattern = "%f[^<][%a_][%w_]*",     type = "function" },
    { pattern = "%f[^<]/[%a_][%w_]*",    type = "function" },
    -- Attributes
    {
      pattern = "[a-z%-]+%s*()=%s*()\".-\"",
      type = { "keyword", "operator", "string" }
    },
    {
      pattern = "[a-z%-]+%s*()=%s*()'.-'",
      type = { "keyword", "operator", "string" }
    },
    {
      pattern = "[a-z%-]+%s*()=%s*()%-?%d[%d%.]*",
      type = { "keyword", "operator", "number" }
    },
    -- Entities
    { pattern = "&#?[a-zA-Z0-9]+;",         type = "keyword2" },

  ---- Markdown rules
    -- math
    { pattern = { "%$%$", "%$%$", "\\"  },  type = "string", syntax = ".tex"},
    { regex   = { "\\$", [[\$|(?=\\*\n)]], "\\" },  type = "string", syntax = ".tex"},
    -- code blocks, order matters
    { pattern = { "```autohotkey", "```" }, type = "string", syntax = ".ahk" },
    { pattern = { "```ahk", "```" }, 		type = "string", syntax = ".ahk" },
    { pattern = { "```awk", "```" }, 		type = "string", syntax = ".awk" },
    { pattern = { "```gawk", "```" }, 		type = "string", syntax = ".awk" },
    { pattern = { "```mawk", "```" }, 		type = "string", syntax = ".awk" },
    { pattern = { "```nawk", "```" }, 		type = "string", syntax = ".awk" },
    { pattern = { "```bat", "```" }, 		type = "string", syntax = ".bat" }, -- batch, batchfile
    { pattern = { "```dosbatch", "```" },   type = "string", syntax = ".bat" },
    { pattern = { "```winbatch", "```" },   type = "string", syntax = ".bat" },
    { pattern = { "```cmd", "```" }, 		type = "string", syntax = ".cmd" },
    { pattern = { "```brainfuck", "```" },  type = "string", syntax = ".bf" },
    { pattern = { "```caddyfile", "```" },  type = "string", syntax = "Caddyfile" },
    { pattern = { "```c++", "```" },        type = "string", syntax = ".cpp" },
    { pattern = { "```cpp", "```" },        type = "string", syntax = ".cpp" },
    { pattern = { "```python", "```" },     type = "string", syntax = ".py" },
    { pattern = { "```ruby", "```" },       type = "string", syntax = ".rb" },
    { pattern = { "```perl", "```" },       type = "string", syntax = ".pl" },
    { pattern = { "```php", "```" },        type = "string", syntax = ".php" },
    { pattern = { "```javascript", "```" }, type = "string", syntax = ".js" },
    { pattern = { "```json", "```" }, 		type = "string", syntax = ".json" }, -- jsonc
    { pattern = { "```cjson", "```" }, 		type = "string", syntax = ".json" },
    { pattern = { "```html", "```" },       type = "string", syntax = ".html" },
    { pattern = { "```ini", "```" },        type = "string", syntax = ".ini" },
    { pattern = { "```xml", "```" },        type = "string", syntax = ".xml" },
    { pattern = { "```css", "```" },        type = "string", syntax = ".css" },
    { pattern = { "```sass", "```" },		type = "string", syntax = ".sass" },
    { pattern = { "```scss", "```" }, 		type = "string", syntax = ".scss" },
    { pattern = { "```lua", "```" },        type = "string", syntax = ".lua" },
    { pattern = { "```bash", "```" },       type = "string", syntax = ".sh" },
    { pattern = { "```ksh", "```" }, 		type = "string", syntax = ".sh" },
    { pattern = { "```zsh", "```" }, 		type = "string", syntax = ".sh" },
    { pattern = { "```java", "```" },       type = "string", syntax = ".java" },
    { pattern = { "```c3", "```" }, 		type = "string", syntax = ".c3" },
    { pattern = { "```c#", "```" },         type = "string", syntax = ".cs" },
    { pattern = { "```csharp", "```" }, 	type = "string", syntax = ".cs" },
    { pattern = { "```cmake", "```" },      type = "string", syntax = ".cmake" },
    { pattern = { "```glsl", "```" },       type = "string", syntax = ".glsl" },
    { pattern = { "```julia", "```" },      type = "string", syntax = ".jl" },
    { pattern = { "```rust", "```" },       type = "string", syntax = ".rs" },
    { pattern = { "```dart", "```" },       type = "string", syntax = ".dart" },
    { pattern = { "```diff", "```" },       type = "string", syntax = ".diff" },
    { pattern = { "```toml", "```" },       type = "string", syntax = ".toml" },
    { pattern = { "```yaml", "```" },       type = "string", syntax = ".yaml" },
    { pattern = { "```yml", "```" }, 		type = "string", syntax = ".yaml" },
    { pattern = { "```nim", "```" },        type = "string", syntax = ".nim" },
    { pattern = { "```typescript", "```" }, type = "string", syntax = ".ts" },
    { pattern = { "```rescript", "```" },   type = "string", syntax = ".res" },
    { pattern = { "```moon", "```" },       type = "string", syntax = ".moon" },
    { pattern = { "```lobster", "```" },    type = "string", syntax = ".lobster" },
    { pattern = { "```liquid", "```" },     type = "string", syntax = ".liquid" },
    { pattern = { "```nix", "```" },        type = "string", syntax = ".nix" },
    { pattern = { "```elixir", "```" },     type = "string", syntax = ".ex" },
    { pattern = { "```elm", "```" },        type = "string", syntax = ".elm" },
    { pattern = { "```fennel", "```" },     type = "string", syntax = ".fnl" },
    { pattern = { "```fortran", "```" },    type = "string", syntax = ".f90" },
    { pattern = { "```haxe", "```" },       type = "string", syntax = ".hx" },
    { pattern = { "```hlsl", "```" },       type = "string", syntax = ".hlsl" },
    { pattern = { "```kotlin", "```" },     type = "string", syntax = ".kt" },
    { pattern = { "```objc", "```" },       type = "string", syntax = ".m" },
    { pattern = { "```objectivec", "```" }, type = "string", syntax = ".m" },
    { pattern = { "```openscad", "```" },   type = "string", syntax = ".scad" },
    { pattern = { "```scala", "```" },      type = "string", syntax = ".scala" },
    { pattern = { "```swift", "```" },      type = "string", syntax = ".swift" },
    { pattern = { "```wren", "```" },       type = "string", syntax = ".wren" },
    { pattern = { "```zig", "```" },        type = "string", syntax = ".zig" },
    { pattern = { "```hare", "```" },       type = "string", syntax = ".ha" },
    { pattern = { "```html-eruby", "```" }, type = "string", syntax = ".erb" },
    { pattern = { "```erb", "```" },        type = "string", syntax = ".erb" },
    { pattern = { "```jsx", "```" },        type = "string", syntax = ".jsx" },
    { pattern = { "```tsx", "```" },        type = "string", syntax = ".tsx" },
    { pattern = { "```astro", "```" }, 		type = "string", syntax = ".tsx" },
    { pattern = { "```gdscript", "```" },   type = "string", syntax = ".gd" },
    { pattern = { "```graphql", "```" },    type = "string", syntax = ".graphql" },
    { pattern = { "```powershell", "```" }, type = "string", syntax = ".ps1" },
    { pattern = { "```pwsh", "```" }, 		type = "string", syntax = ".ps1" },
    { pattern = { "```ps1", "```" },        type = "string", syntax = ".ps1" },
    { pattern = { "```sql", "```" },        type = "string", syntax = ".sql" },
    { pattern = { "```postgresql", "```" }, type = "string", syntax = ".sql" },
    { pattern = { "```clojure", "```" },    type = "string", syntax = ".clj" },
    { pattern = { "```clj", "```" },        type = "string", syntax = ".clj" },
    { pattern = { "```haskell", "```" },    type = "string", syntax = ".hs" },
    { pattern = { "```groovy", "```" },     type = "string", syntax = ".groovy" },
    { pattern = { "```odin", "```" },       type = "string", syntax = ".odin" },
    { pattern = { "```tcl", "```" },        type = "string", syntax = ".tcl" },
    { pattern = { "```starlark", "```" },   type = "string", syntax = ".star" },
    { pattern = { "```carbon", "```" },     type = "string", syntax = ".carbon" },
    { pattern = { "```meson", "```" },      type = "string", syntax = PATHSEP .. "meson.build" },
    { pattern = { "```nginx", "```" }, 		type = "string", syntax = PATHSEP .. "nginx.conf" },
    { pattern = { "```kdl", "```" },        type = "string", syntax = ".kdl" },
    -- tex
    { pattern = { "```bib", "```" }, 		type = "string", syntax = ".bib" }, -- bibtex
    { pattern = { "```latex", "```" }, 		type = "string", syntax = ".tex" },
    { pattern = { "```tex", "```" }, 		type = "string", syntax = ".tex" },
    { pattern = { "```typ", "```" }, 		type = "string", syntax = ".typ" }, -- typst
    -- yes, this *could* happen
    { pattern = { "```markdown", "```" }, 	type = "string", syntax = ".md" },
    -- isolate 2 char alias to avoid mismatch
    { pattern = { "```md", "```" }, 		type = "string", syntax = ".md" },
    { pattern = { "```bf", "```" }, 		type = "string", syntax = ".bf" },
    { pattern = { "```go", "```" }, 		type = "string", syntax = ".go" },
    { pattern = { "```hs", "```" }, 		type = "string", syntax = ".hs" },
    { pattern = { "```js", "```" }, 		type = "string", syntax = ".js" },
    { pattern = { "```py", "```" }, 		type = "string", syntax = ".py" },
    { pattern = { "```rb", "```" }, 		type = "string", syntax = ".rb" },
    { pattern = { "```rs", "```" }, 		type = "string", syntax = ".rs" },
    { pattern = { "```sh", "```" }, 		type = "string", syntax = ".sh" }, -- shell
    { pattern = { "```ts", "```" }, 		type = "string", syntax = ".ts" },
    -- 1 char identifier
    { pattern = { "```c", "```" }, 			type = "string", syntax = ".c" },
    { pattern = { "```d", "```" }, 			type = "string", syntax = ".d" },
    { pattern = { "```r", "```" }, 			type = "string", syntax = ".r" },
    { pattern = { "```v", "```" }, 			type = "string", syntax = ".v" },
    { pattern = { "```", "```" },           type = "string" },
    { pattern = { "``", "``" },             type = "string" },
    { pattern = { "%f[\\`]%`[%S]", "`" },   type = "string" },
    -- lines
    { pattern = "^%-%-%-+\n" ,              type = "comment" },
    { pattern = "^%*%*%*+\n",               type = "comment" },
    { pattern = "^___+\n",                  type = "comment" },
    { pattern = "^===+\n",                  type = "comment" },
    -- strike
    { pattern = { "~~", "~~" },             type = "keyword2" },
    -- highlight
    { pattern = { "==", "==" },             type = "literal" },
    -- bold and italic
    { pattern = { "%*%*%*%S", "%*%*%*" },   type = "markdown_bold_italic" },
    { pattern = { "%*%*%S", "%*%*" },       type = "markdown_bold" },
    -- handle edge case where asterisk can be at end of line and not close
    {
      pattern = { "%f[\\%*]%*[%S]", "%*%f[^%*]" },
      type = "markdown_italic"
    },
    -- alternative bold italic formats
    { pattern = "^___[%s%p%w]+___" ,        type = "markdown_bold_italic" },
    { pattern = "^__[%s%p%w]+__" ,          type = "markdown_bold" },
    { pattern = "^_[%s%p%w]+_" ,            type = "markdown_italic" },
    -- heading with custom id
    {
      pattern = "^#+%s[%w%s%p]+(){()#[%w%-]+()}",
      type = { "keyword", "function", "string", "function" }
    },
    -- headings
    { pattern = "^#+%s.+\n",                type = "keyword" },
    -- superscript and subscript
    {
      pattern = "%^()%d+()%^",
      type = { "function", "number", "function" }
    },
    {
      pattern = "%~()%d+()%~",
      type = { "function", "number", "function" }
    },
    -- definitions
    { pattern = "^:%s.+",                   type = "function" },
    -- emoji
    { pattern = ":[a-zA-Z0-9_%-]+:",        type = "literal" },
    -- images and link
    {
      pattern = "!?%[!?%[()["..in_squares_match.."]+()%]%(()["..in_parenthesis_match.."]+()%)%]%(()["..in_parenthesis_match.."]+()%)",
      type = { "function", "string", "function", "number", "function", "number", "function" }
    },
    {
      pattern = "!?%[!?%[?()["..in_squares_match.."]+()%]?%]%(()["..in_parenthesis_match.."]+()%)",
      type = { "function", "string", "function", "number", "function" }
    },
    -- inline metadata
    -- [key::value]
    {
      pattern = "%[()[^:%]%s]+()::()[^%]%s]+()%]",
      type = { "function", "string", "comment", "number", "function" },
    },
    -- reference links
    -- [example][example]
    {
      pattern = "%[()["..in_squares_match.."]+()%] *()%[()["..in_squares_match.."]+()%]",
      type = { "function", "string", "function", "function", "number", "function" }
    },
    -- wikilinks
    -- ![[example]]
    {
      pattern = "!()%[%[()[" .. in_squares_match .. "]+()%]%]",
      type = { "normal", "comment", "number", "comment" },
    },
    -- [[example]]
    {
      pattern = "%[%[()[" .. in_squares_match .. "]+()%]%]",
      type = { "comment", "number", "comment" },
    },
    -- ![example]
    {
      pattern = "!()%[()[" .. in_squares_match .. "]+()%]",
      type = { "normal", "comment", "number", "comment" },
    },
    -- [^note]
    {
      pattern = "%[%^()[" .. in_squares_match .. "]+()%]",
      type = { "comment", "normal", "comment" },
    },
    -- [example]
    {
      pattern = "%[()[" .. in_squares_match .. "]+()%]",
      type = { "comment", "number", "comment" },
    },
    -- email
    {
      pattern = "<[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+%.[a-zA-Z0-9-.]+>",
      type = "function"
    },
    -- url
    { pattern = "<https?://%S+>",           type = "function" },
    { pattern = "https?://%S+",             type = "function" },
    -- optimize consecutive dashes used in tables
    { pattern = "%-+",                      type = "normal" },
  },
  symbols = { },
}

-- Adjust the color on theme changes
core.add_thread(function()
  local custom_fonts = { bold = {font = nil, color = nil}, italic = {}, bold_italic = {} }
  local initial_color
  local last_code_font

  local function set_font(attr)
    local attributes = {}
    if attr ~= "bold_italic" then
      attributes[attr] = true
    else
      attributes["bold"] = true
      attributes["italic"] = true
    end
    local font = style.code_font:copy(
      style.code_font:get_size(),
      attributes
    )
    custom_fonts[attr].font = font
    style.syntax_fonts["markdown_"..attr] = font
  end

  local function set_color(attr)
    custom_fonts[attr].color = style.syntax["keyword2"]
    style.syntax["markdown_"..attr] = style.syntax["keyword2"]
  end

  -- Add 3 type of font styles for use on markdown files
  for attr, _ in pairs(custom_fonts) do
    -- Only set it if the font wasn't manually customized
    if not style.syntax_fonts["markdown_"..attr] then
      set_font(attr)
    end

    -- Only set it if the color wasn't manually customized
    if not style.syntax["markdown_"..attr] then
      set_color(attr)
    end
  end

  while true do
    if last_code_font ~= style.code_font then
      last_code_font = style.code_font
      for attr, _ in pairs(custom_fonts) do
        -- Only set it if the font wasn't manually customized
        if style.syntax_fonts["markdown_"..attr] == custom_fonts[attr].font then
          set_font(attr)
        end
      end
    end

    if initial_color ~= style.syntax["keyword2"] then
      initial_color = style.syntax["keyword2"]
      for attr, _ in pairs(custom_fonts) do
        -- Only set it if the color wasn't manually customized
        if style.syntax["markdown_"..attr] == custom_fonts[attr].color then
          set_color(attr)
        end
      end
    end
    coroutine.yield(1)
  end
end)

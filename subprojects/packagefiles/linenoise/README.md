# lua-linenoise - Lua binding for the linenoise command line library

Linenoise (https://github.com/antirez/linenoise) is a delightfully simple command
line library.  This Lua module is simply a binding for it.

The main Linenoise upstream has stagnated a bit, so this binding tracks https://github.com/yhirose/linenoise/tree/utf8-support, which
includes things like UTF-8 support and ANSI terminal escape sequence detection.

This repository also contains a Windows-compatible version of linenoise taken from MSOpenTech's [Windows port](https://github.com/MSOpenTech/redis) of redis.

# Compilation

If you use LuaRocks, you can run `luarocks make` on the latest rockspec.

You can also build with make. When building this module using make, you may use the original linenoise source included in
the repository, or you may set the Makefile variable `LIBLINENOISE` to override
it:

```sh
make LIBLINENOISE=-llinenoise
# OR:
make LIBLINENOISE=/path/to/liblinenoise.a
```

You may need to change the value of the LN_EXPORT macro in lua-linenoise.c to the appropriate keyword to ensure the luaopen_linenoise function is exported properly (I don't know much about C or Unix-like systems, so I may have gotten it wrong).

If you have Visual Studio 2012 (even the free Express version), you can compile this module with the Windows-compatible linenoise source using the included solution file (you'll need to edit the include paths and import library dependencies to match your configuration).

If you prefer to compile using other tools, just link lua-linenoise.c with line-noise-windows/linenoise.c and line-noise-windows/win32fixes.c to create the Windows-compatible DLL.

# Usage

This library is a fairly thin wrapper over linenoise itself, so the function calls
are named similarly.  I may develop a "porcelain" layer in the future.

## L.linenoise(prompt)

Prompts for a line of input, using *prompt* as the prompt string.  Returns nil if
no more input is available; Returns nil and an error string if an error occurred.

## L.historyadd(line)

Adds *line* to the history list.

## L.historysetmaxlen(length)

Sets the history list size to *length*.

## L.historysave(filename)

Saves the history list to *filename*.

## L.historyload(filename)

Loads the history list from *filename*.

## L.clearscreen()

Clears the screen.

## L.setcompletion(callback)

Sets the completion callback.  This callback is called with two arguments:

  * A completions object.  Use object:add or L.addcompletion to add a completion to this object.
  * The current line of input.

## L.addcompletion(completions, string)

Adds *string* to the list of completions.

All functions return nil on error; functions that don't have an obvious return value
return true on success.

## L.setmultiline(multiline)

Enables multi-line mode if *multiline* is true, disables otherwise.

## L.printkeycodes()

Prints linenoise key codes.  Primarly used for debugging.

# Example

```lua
local L = require 'linenoise'
local colors = require('term').colors -- optional
-- L.clearscreen()
print '----- Testing lua-linenoise! ------'
local prompt, history = '? ', 'history.txt'
L.historyload(history) -- load existing history
L.setcompletion(function(completion,str)
   if str == 'h' then
    completion:add('help')
    completion:add('halt')
  end
end)

local line, err = L.linenoise(prompt)
while line do
    if #line > 0 then
        print(line:upper())
        L.historyadd(line)
        L.historysave(history) -- save every new line
    end
    line, err = L.linenoise(prompt)
end
if err then
  print('An error occurred: ' .. err)
end
```

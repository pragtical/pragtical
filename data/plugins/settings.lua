-- mod-version:3 --priority:0
local core = require "core"
local config = require "core.config"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local tokenizer = require "core.tokenizer"
local View = require "core.view"
local DocView = require "core.docview"
local Widget = require "widget"
local Label = require "widget.label"
local Line = require "widget.line"
local NoteBook = require "widget.notebook"
local Button = require "widget.button"
local TextBox = require "widget.textbox"
local SelectBox = require "widget.selectbox"
local NumberBox = require "widget.numberbox"
local Toggle = require "widget.toggle"
local ListBox = require "widget.listbox"
local FoldingBook = require "widget.foldingbook"
local FontsList = require "widget.fontslist"
local ItemsList = require "widget.itemslist"
local WidgetList = require "widget.widgetlist"
local KeybindingDialog = require "widget.keybinddialog"
local Fonts = require "widget.fonts"
local FilePicker = require "widget.filepicker"
local ColorPicker = require "widget.colorpicker"
local MessageBox = require "widget.messagebox"
local Container = require "widget.container"

-- Load treeview if enabled
local treeview
core.add_thread(function()
  if config.plugins.treeview ~= false then
    treeview = require "plugins.treeview"
  end
end)

---@class plugins.settings
local settings = {}

settings.core = {}
settings.plugins = {}
settings.sections = {}
settings.plugin_sections = {}
settings.config = {}
settings.default_keybindings = {}

---Enumeration for the different types of settings.
---@type table<string, integer>
settings.type = {
  STRING = 1,
  NUMBER = 2,
  TOGGLE = 3,
  SELECTION = 4,
  LIST_STRINGS = 5,
  BUTTON = 6,
  FONT = 7,
  FILE = 8,
  DIRECTORY = 9,
  COLOR = 10,
  SUBCONFIG = 11,
  LIST_WIDGETS = 12
}

---@alias settings.types
---| `settings.type.STRING`
---| `settings.type.NUMBER`
---| `settings.type.TOGGLE`
---| `settings.type.SELECTION`
---| `settings.type.LIST_STRINGS`
---| `settings.type.BUTTON`
---| `settings.type.FONT`
---| `settings.type.FILE`
---| `settings.type.DIRECTORY`
---| `settings.type.COLOR`
---| `settings.type.SUBCONFIG`
---| `settings.type.LIST_WIDGETS`

---Represents a setting to render on a settings pane.
---@class settings.option
---Title displayed to the user eg: "My Option"
---@field public label string
---Description of the option eg: "Modifies the document indentation"
---@field public description string
---Config path in the config table, eg: section.myoption, myoption, etc...
---@field public path string
---Type of option that will be used to render an appropriate control
---@field public type settings.types | integer
---Default edit value, also used by Reset through set_value and on_apply.
---A function resolves the current default when building the control or resetting,
---for example `default = function() return style.dim end` for a theme color.
---Returned tables are copied so editing the setting cannot modify its source.
---Reset removes the saved GUI override; nil clears an optional value.
---@field public default string | number | boolean | table | fun():any | nil
---Used for NUMBER to indicate the minimum number allowed
---@field public min number
---Used for NUMBER to indicate the maximum number allowed
---@field public max number
---Used for NUMBER to indicate the increment/decrement amount
---@field public step number
---Used in a SELECTION to provide the list of valid options
---@field public values table
---Optionally used for FONT to store the generated font group.
---@field public fonts_list table<string, renderer.font>
---Flag set to true when loading user defined fonts fail
---@field public font_error boolean
---Optional function that is used to manipulate the current value on retrieval.
---@field public get_value nil | fun(value:any):any
---Optional function that is used to manipulate the saved value on save.
---Return nil and an error as the second result to reject the change.
---@field public set_value nil | fun(value:any):any, string?
---The icon set for a BUTTON
---@field public icon string
---Command or function executed when a BUTTON is clicked
---@field public on_click nil | string | fun(button:string, x:integer, y:integer)
---Title used when opening a SUBCONFIG view.
---@field public title string
---Spec used when opening a SUBCONFIG view.
---@field public spec settings.config_spec|settings.option[]
---Optional function executed when the option value is applied.
---@field public on_apply nil | fun(value:any)
---When FILE or DIRECTORY this flag tells the path should exist.
---@field public exists boolean
---Lua patterns used on FILE or DIRECTORY to filter browser results and
---also force the selection to match one of the filters.
---@field public filters table<integer,string>
---Items displayed by a LIST_WIDGETS, or a function that generates them.
---@field public items? table|fun(value:any):table
---Return the text used to filter a LIST_WIDGETS item.
---@field public item_text? fun(item:any):string
---Populate a LIST_WIDGETS row with child controls.
---@field public build_item? fun(row:widget.widgetlist.item, item:any, value:any, commit:fun(value:any))
---Maximum number of LIST_WIDGETS rows visible without scrolling.
---@field public visible_rows? integer
---Whether a LIST_WIDGETS includes a text filter. Defaults to true.
---@field public filterable? boolean
---Placeholder displayed by a LIST_WIDGETS filter.
---@field public filter_placeholder? string

---Represents a standalone settings specification.
---@class settings.config_spec
---Title displayed by the generated configuration view.
---@field public name string
---Optional config path prefix prepended to all option paths.
---@field public path_prefix string
---Optional named sections. Each section value is a `settings.option[]`.
---@field public sections table<string, settings.option[]>|table<integer, table>

---Add a new settings section to the settings UI
---@param section string
---@param options settings.option[]
---@param plugin_name? string Optional name of plugin
---@param overwrite? boolean Overwrite previous section options
function settings.add(section, options, plugin_name, overwrite)
  local category = ""
  if plugin_name ~= nil then
    category = "plugins"
  else
    category = "core"
  end

  if overwrite and settings[category][section] then
    settings[category][section] = {}
  end

  if not settings[category][section] then
    settings[category][section] = {}
    if category ~= "plugins" then
      table.insert(settings.sections, section)
    else
      table.insert(settings.plugin_sections, section)
    end
  end

  if plugin_name ~= nil then
    if not settings[category][section][plugin_name] then
      settings[category][section][plugin_name] = {}
    end
    if type(options.sections) == "table" then
      settings[category][section][plugin_name].sections = options.sections
    end
    for _, option in ipairs(options) do
      table.insert(settings[category][section][plugin_name], option)
    end
  else
    for _, option in ipairs(options) do
      table.insert(settings[category][section], option)
    end
  end
end

--------------------------------------------------------------------------------
-- Add Core Settings
--------------------------------------------------------------------------------

settings.add("General",
  {
    {
      label = "User Module",
      description = "Open your init.lua for customizations.",
      type = settings.type.BUTTON,
      icon = "F",
      on_click = "core:open-user-module"
    },
    {
      label = "Clear Fonts Cache",
      description = "Delete current font cache and regenerate a fresh one.",
      type = settings.type.BUTTON,
      icon = "T",
      on_click = function()
        if Fonts.cache_is_building() then
          MessageBox.warning(
            "Clear Fonts Cache",
            { "The font cache is already been built,\n"
              .. "status will be logged on the core log."
            }
          )
        else
          MessageBox.info(
            "Clear Fonts Cache",
            { "Re-building the font cache can take some time,\n"
              .. "it is needed when you have installed new fonts\n"
              .. "which are not listed on the font picker tool.\n\n"
              .. "Do you want to continue?"
            },
            function(_, button_id, _)
              if button_id == 1 then
                Fonts.clean_cache()
              end
            end,
            MessageBox.BUTTONS_YES_NO
          )
        end
      end
    },
    {
      label = "File Size Limit",
      description = "The maximum file size in megabytes allowed for editing.",
      path = "file_size_limit",
      type = settings.type.NUMBER,
      default = 10,
      min = 1,
      max = 50,
      on_apply = function()
        for _, project in ipairs(core.projects) do
          project:compile_ignore_files()
        end
        core.add_thread(function()
          if treeview then
            treeview.cache = {}
          end
        end)
      end
    },
    {
      label = "Ignore Files",
      description = "List of lua patterns matching files to be ignored by the editor.",
      path = "ignore_files",
      type = settings.type.LIST_STRINGS,
      default = {
        -- folders
        "^%.svn/",        "^%.git/",   "^%.hg/",        "^CVS/", "^%.Trash/", "^%.Trash%-.*/",
        "^node_modules/", "^%.cache/", "^__pycache__/",
        -- files
        "%.pyc$",         "%.pyo$",       "%.exe$",        "%.dll$",   "%.obj$", "%.o$",
        "%.a$",           "%.lib$",       "%.so$",         "%.dylib$", "%.ncb$", "%.sdf$",
        "%.suo$",         "%.pdb$",       "%.idb$",        "%.class$", "%.psd$", "%.db$",
        "^desktop%.ini$", "^%.DS_Store$", "^%.directory$",
      },
      on_apply = function()
        for _, project in ipairs(core.projects) do
          project:compile_ignore_files()
        end
        core.add_thread(function()
          if treeview then
            treeview.cache = {}
          end
        end)
      end
    },
    {
      label = "Maximum Clicks",
      description = "The maximum amount of consecutive clicks that are registered by the editor.",
      path = "max_clicks",
      type = settings.type.NUMBER,
      default = 3,
      min = 1,
      max = 10
    },
    {
      label = "Use System File Picker",
      description = "Use the native file picker by default when opening files and directories.",
      path = "use_system_file_picker",
      type = settings.type.TOGGLE,
      default = system.get_sandbox() ~= "none"
    },
  }
)

local disabled_transition_items = {
  { key = "floating", label = "Floating View Slides" },
  { key = "scroll", label = "Scrolling" },
  { key = "commandview", label = "Command View" },
  { key = "contextmenu", label = "Context Menu" },
  { key = "logview", label = "Log View" },
  { key = "menubar", label = "Menu Bar" },
  { key = "nagbar", label = "Nag Bar" },
  { key = "tabs", label = "Tabs" },
  { key = "tab_drag", label = "Tab Drag" },
  { key = "statusbar", label = "Status Bar" }
}

settings.add("Graphics",
  {
    {
      label = "Renderer",
      description = "Requires closing and reopening Pragtical. Default uses the build's default renderer. PRAGTICAL_RENDERER overrides this choice.",
      path = "renderer",
      type = settings.type.SELECTION,
      default = "default",
      values = {
        { "Default", "default" },
        { "Surface", "surface" },
        { "SDLGPU", "sdlgpu" },
        { "SDLRenderer", "sdlrenderer" }
      },
      get_value = function()
        local file = io.open(USERDIR .. PATHSEP .. "renderer", "r")
        if file then
          local value = file:read("*a")
          file:close()
          value = value and value:match("^%s*(.-)%s*$")
          if value == "surface" or value == "sdlgpu" or value == "sdlrenderer" then
            return value
          end
        end
        return "default"
      end,
      set_value = function(value)
        local path = USERDIR .. PATHSEP .. "renderer"
        if value == "default" then
          local ok, err, code = os.remove(path)
          if not ok and code ~= 2 then return nil, err end -- ENOENT is already default.
          return value
        end

        local file, err = io.open(path, "w")
        if not file then return nil, err end
        local written, write_err = file:write(value .. "\n")
        local closed, close_err = file:close()
        if not written or not closed then
          return nil, write_err or close_err
        end
        return value
      end
    },
    {
      label = "Auto FPS",
      description = "Automatically set frames per second from current display refresh rate. If supported also toggles the current renderer v-sync.",
      path = "auto_fps",
      type = settings.type.TOGGLE,
      default = true,
      on_apply = function(enabled)
        if enabled then
          config.fps = DEFAULT_FPS
        else
          config.fps = settings.config.fps or DEFAULT_FPS
        end
        core.window:set_vsync(enabled)
      end
    },
    {
      label = "Frames Per Second",
      description = "Lower value for low end machines and higher for a smoother experience. This value is ignored if Auto FPS is enabled.",
      path = "fps",
      type = settings.type.NUMBER,
      default = DEFAULT_FPS,
      min = 10,
      max = 300,
      on_apply = function(value)
        if config.auto_fps then
          config.fps = DEFAULT_FPS
        else
          config.fps = value
        end
      end
    },
    {
      label = "Transitions",
      description = "If disabled turns off all transitions but improves rendering performance.",
      path = "transitions",
      type = settings.type.TOGGLE,
      default = true
    },
    {
      label = "Animation Rate",
      description = "The speed of transitions, higher value means faster.",
      path = "animation_rate",
      type = settings.type.NUMBER,
      default = 1.0,
      min = 0.5,
      max = 3.0,
      step = 0.1
    },
    {
      label = "Animation Type",
      description = "The type of animation system used on general transitions.",
      path = "animation_type",
      type = settings.type.SELECTION,
      default = "constant",
      values = {
        {"Constant Velocity", "constant"},
        {"Linear Interpolation", "lerp"}
      }
    },
    {
      label = "Editor Scroll Animation Type",
      description = "The type of animation system used on the editor scroll transition.",
      path = "scroll_animation_type",
      type = settings.type.SELECTION,
      default = "constant",
      values = {
        {"Constant Velocity with Acceleration", "constant"},
        {"Linear Interpolation", "lerp"}
      }
    },
    {
      label = "Animate Mouse Drag Scroll",
      description = "Causes higher cpu usage but smoother scroll transition.",
      path = "animate_drag_scroll",
      type = settings.type.TOGGLE,
      default = false
    },
    {
      label = "Disable Transitions",
      description = "Choose which individual transitions should be disabled.",
      path = "disabled_transitions",
      type = settings.type.LIST_WIDGETS,
      default = {
        floating = false,
        scroll = false,
        commandview = false,
        contextmenu = false,
        logview = false,
        menubar = false,
        nagbar = false,
        tabs = false,
        tab_drag = false,
        statusbar = false
      },
      filterable = false,
      visible_rows = #disabled_transition_items,
      get_value = function(value)
        return common.merge({}, type(value) == "table" and value or {})
      end,
      items = disabled_transition_items,
      item_text = function(item)
        return item.label
      end,
      build_item = function(row, item, value, commit)
        local label = Label(row, item.label)
        row:set_child_properties(label, { stretch = 1 })

        local toggle = Toggle(row, "", value[item.key] == true)
        function toggle:on_change(disabled)
          value[item.key] = disabled
          commit(value)
        end
      end
    },
  }
)

settings.add("User Interface",
  {
    {
      label = "Font",
      description = "The font and fallbacks used on non code text.",
      path = "font",
      type = settings.type.FONT,
      fonts_list = style,
      default = {
        fonts = {
          {
            name = "Fira Sans Regular",
            path = DATADIR .. "/fonts/FiraSans-Regular.ttf"
          }
        },
        options = {
          size = 15,
          antialiasing = "subpixel",
          hinting = "slight"
        }
      }
    },
    {
      label = "Borderless",
      description = "Use built-in window decorations.",
      path = "borderless",
      type = settings.type.TOGGLE,
      default = true,
      on_apply = function()
        core.configure_borderless_window()
      end
    },
    {
      label = "Borderless Outline",
      description = "Draw a thin border around borderless windows. Hidden when maximized or fullscreen.",
      path = "borderless_outline",
      type = settings.type.TOGGLE,
      default = true
    },
    {
      label = "Focused Outline Color",
      description = "Borderless outline color when the window has keyboard focus.",
      path = "outline_focused",
      type = settings.type.COLOR,
      default = nil,
      get_value = function(value) return value or style.caret end
    },
    {
      label = "Unfocused Outline Color",
      description = "Borderless outline color when the window loses focus.",
      path = "outline_unfocused",
      type = settings.type.COLOR,
      default = nil,
      get_value = function(value) return value or style.dim end
    },
    {
      label = "Inactive Title Bar Overlay",
      description = "Tint the entire built-in title bar when the window loses focus. Set alpha to 0 to disable it.",
      path = "borderless_unfocused_overlay",
      type = settings.type.COLOR,
      default = { 0, 0, 0, 64 }
    },
    {
      label = "Show Menu Bar",
      description = "Show the application menu bar on the top or inside the title bar in borderless mode.",
      path = "show_menubar",
      type = settings.type.TOGGLE,
      default = true,
      ---Apply saved or edited visibility through the bar's animated lifecycle.
      ---@param enabled boolean Whether the application menu bar should be shown
      on_apply = function(enabled)
        if enabled then core.menu_view:show() else core.menu_view:hide() end
      end
    },
    {
      label = "Command Palette Position",
      description = "Place command prompts at the bottom, top, or center. Applies to the next prompt.",
      path = "commandview_position",
      type = settings.type.SELECTION,
      default = "bottom",
      values = {
        { "Bottom", "bottom" },
        { "Top", "top" },
        { "Center", "center" }
      }
    },
    {
      label = "Maximum Palette Items",
      description = "The maximum amount of items visible on the command palette.",
      path = "max_visible_commands",
      type = settings.type.NUMBER,
      default = 10,
      min = 1
    },
    {
      label = "Maximum Recent Files",
      description = "The maximum amount of recently visited files to keep on history.",
      path = "max_visited_files",
      type = settings.type.NUMBER,
      default = 5,
      min = 1
    },
    {
      label = "Hide Tabs",
      description = "Always hide tabs even if multiple documents are open.",
      path = "hide_tabs",
      type = settings.type.TOGGLE,
      default = false
    },
    {
      label = "Always Show Tabs",
      description = "Shows tabs even if a single document is opened.",
      path = "always_show_tabs",
      type = settings.type.TOGGLE,
      default = true
    },
    {
      label = "Maximum Tabs",
      description = "The maximum amount of visible document tabs.",
      path = "max_tabs",
      type = settings.type.NUMBER,
      default = 8,
      min = 1,
      max = 100
    },
    {
      label = "Tabs Top Margin",
      description = "The amount of margin to apply on the top of tabs.",
      path = "tabs_top_margin",
      type = settings.type.NUMBER,
      default = -style.divider_size,
      on_apply = function(value)
        style.margin.tab.top = (tonumber(value) or -1) * SCALE
      end
    },
    {
      label = "Close Button on Tabs",
      description = "Display the close button on tabs.",
      path = "tab_close_button",
      type = settings.type.TOGGLE,
      default = true
    },
    {
      label = "Mouse wheel scroll rate",
      description = "The amount to scroll when using the mouse wheel.",
      path = "mouse_wheel_scroll",
      type = settings.type.NUMBER,
      default = 70,
      min = 10,
      max = 200,
      get_value = function(value)
        return value / SCALE
      end,
      on_apply = function(value)
        config.mouse_wheel_scroll = value * SCALE
      end
    },
    {
      label = "Force Scrollbar Status",
      description = "Choose a fixed scrollbar state instead of resizing it on mouse hover.",
      path = "force_scrollbar_status",
      type = settings.type.SELECTION,
      default = false,
      values = {
        {"Disabled", false},
        {"Expanded", "expanded"},
        {"Contracted", "contracted"}
      },
      on_apply = function(value)
        local mode = config.force_scrollbar_status_mode or "global"
        local globally = mode == "global"
        local views = core.root_view.root_node:get_children()
        for _, view in ipairs(views) do
          if globally or view:extends(DocView) then
            view.h_scrollbar:set_forced_status(value)
            view.v_scrollbar:set_forced_status(value)
          else
            view.h_scrollbar:set_forced_status(false)
            view.v_scrollbar:set_forced_status(false)
          end
        end
      end
    },
    {
      label = "Force Scrollbar Status Mode",
      description = "Choose between applying globally or document views only.",
      path = "force_scrollbar_status_mode",
      type = settings.type.SELECTION,
      default = "global",
      values = {
        {"Documents", "docview"},
        {"Globally", "global"}
      },
      on_apply = function(value)
        local globally = value == "global"
        local views = core.root_view.root_node:get_children()
        for _, view in ipairs(views) do
          if globally or view:extends(DocView) then
            view.h_scrollbar:set_forced_status(config.force_scrollbar_status)
            view.v_scrollbar:set_forced_status(config.force_scrollbar_status)
          else
            view.h_scrollbar:set_forced_status(false)
            view.v_scrollbar:set_forced_status(false)
          end
        end
      end
    },
    {
      label = "Disable Cursor Blinking",
      description = "Disables cursor blinking on text input elements."
        .. " This reduces idle CPU usage.",
      path = "disable_blink",
      type = settings.type.TOGGLE,
      default = false
    },
    {
      label = "Cursor Blinking Period",
      description = "Interval in seconds in which the cursor blinks.",
      path = "blink_period",
      type = settings.type.NUMBER,
      default = 1.2,
      min = 0.3,
      max = 2.0,
      step = 0.1
    }
  }
)

settings.add("Editor",
  {
    {
      label = "Code Font",
      description = "The font and fallbacks used on the code editor.",
      path = "code_font",
      type = settings.type.FONT,
      fonts_list = style,
      default = {
        fonts = {
          {
            name = "JetBrains Mono Regular",
            path = DATADIR .. "/fonts/JetBrainsMono-Regular.ttf"
          }
        },
        options = {
          size = 15,
          antialiasing = "subpixel",
          hinting = "slight"
        }
      }
    },
    {
      label = "Indentation Type",
      description = "The character inserted when pressing the tab key.",
      path = "tab_type",
      type = settings.type.SELECTION,
      default = "soft",
      values = {
        {"Space", "soft"},
        {"Tab", "hard"}
      }
    },
    {
      label = "Indentation Size",
      description = "Amount of spaces shown per indentation.",
      path = "indent_size",
      type = settings.type.NUMBER,
      default = 2,
      min = 1,
      max = 10
    },
    {
      label = "Default Line Endings",
      description = "If set to 'auto' defaults to `crlf` on Windows and `lf` on everything else.",
      path = "line_endings_gui",
      type = settings.type.SELECTION,
      default = "auto",
      values = {
        {"Auto", "auto"},
        {"CRLF (\\r\\n)", "crlf"},
        {"LF (\\n)", "lf"}
      },
      on_apply = function(value)
        if value == "auto" then
          config.line_endings = PLATFORM == "Windows" and "crlf" or "lf"
        else
          config.line_endings = value
        end
      end
    },
    {
      label = "New File Extension",
      description = "The extension suggested for new untitled documents. "
        .. "Leave empty for no fallback; a leading period is optional.",
      path = "new_file_extension",
      type = settings.type.STRING,
      default = ""
    },
    {
      label = "New File Extension Mode",
      description = "Always use the configured extension or follow the active "
        .. "document and use the configured extension as a fallback.",
      path = "new_file_extension_mode",
      type = settings.type.SELECTION,
      default = "configured",
      values = {
        {"Configured Extension", "configured"},
        {"Follow Current File", "current"}
      }
    },
    {
      label = "Keep Newline Whitespace",
      description = "Do not remove whitespace when pressing enter.",
      path = "keep_newline_whitespace",
      type = settings.type.TOGGLE,
      default = false
    },
    {
      label = "Line Limit",
      description = "Amount of characters at which the line breaking column will be drawn.",
      path = "line_limit",
      type = settings.type.NUMBER,
      default = 80,
      min = 1
    },
    {
      label = "Line Height",
      description = "The amount of spacing between lines.",
      path = "line_height",
      type = settings.type.NUMBER,
      default = 1.2,
      min = 0.8,
      max = 3.0,
      step = 0.1
    },
    {
      label = "Context Lines",
      description = "Minimum number of lines to keep visible above and below the cursor when scrolling the document.",
      path = "scroll_context_lines",
      type = settings.type.NUMBER,
      default = 1,
      min = 0,
      step = 1
    },
    {
      label = "Show Line Numbers",
      description = "Show or hide a document line numbers.",
      path = "show_line_numbers",
      type = settings.type.TOGGLE,
      default = true,
    },
    {
      label = "Highlight Line",
      description = "Highlight the current line.",
      path = "highlight_current_line",
      type = settings.type.SELECTION,
      default = "no_selection",
      values = {
        {"Yes", true},
        {"No", false},
        {"No Selection", "no_selection"}
      },
      set_value = function(value)
        if type(value) == "nil" then return false end
        return value
      end
    },
    {
      label = "Case Insensitive Word Selection",
      description = "Perform case insensitive next word selection.",
      path = "select_add_next_no_case",
      type = settings.type.TOGGLE,
      default = false
    },
    {
      label = "Maximum Undo History",
      description = "The amount of undo elements to keep.",
      path = "max_undos",
      type = settings.type.NUMBER,
      default = 10000,
      min = 100,
      max = 100000
    },
    {
      label = "Undo Merge Timeout",
      description = "Time in seconds before applying an undo action.",
      path = "undo_merge_timeout",
      type = settings.type.NUMBER,
      default = 0.3,
      min = 0.1,
      max = 1.0,
      step = 0.1
    },
    {
      label = "Symbol Pattern",
      description = "A lua pattern used to match symbols in the document.",
      path = "symbol_pattern",
      type = settings.type.STRING,
      default = "[%a_][%w_]*"
    },
    {
      label = "Non Word Characters",
      description = "A string of characters that do not belong to a word.",
      path = "non_word_chars",
      type = settings.type.STRING,
      default = " \\t\\n/\\()\"':,.;<>~!@#$%^&*|+=[]{}`?-",
      get_value = function(value)
        return value:gsub("\n", "\\n"):gsub("\t", "\\t")
      end,
      set_value = function(value)
        return value:gsub("\\n", "\n"):gsub("\\t", "\t")
      end
    },
    {
      label = "Scroll Past the End",
      description = "Allow scrolling beyond the document ending.",
      path = "scroll_past_end",
      type = settings.type.TOGGLE,
      default = true
    }
  }
)

settings.add("Image Viewer",
  {
    {
      label = "Background Mode",
      description = "The type of background to draw behind transparent images.",
      path = "images_background_mode",
      type = settings.type.SELECTION,
      default = "grid",
      values = {
        {"Grid", "grid"},
        {"Solid", "solid"},
        {"None", "none"}
      }
    },
    {
      label = "Background Color",
      description = "The color used when background mode is set to solid.",
      path = "images_background_color",
      type = settings.type.COLOR,
      default = table.pack(table.unpack(config.images_background_color))
    }
  }
)

settings.add("Audio Player",
  {
    {
      label = "Default Visualization",
      description = "Show waveform and meters in new tabs.",
      path = "audio_player.visualization",
      type = settings.type.TOGGLE,
      default = false
    },
    {
      label = "Default Repeat",
      description = "Repeat the playlist in new player tabs.",
      path = "audio_player.repeat_all",
      type = settings.type.TOGGLE,
      default = false
    },
    {
      label = "Default Shuffle",
      description = "Play tracks in random order in new player tabs.",
      path = "audio_player.shuffle",
      type = settings.type.TOGGLE,
      default = false
    },
    {
      label = "Default Directory",
      description = "Music folder to scan in new tabs. No autoplay.",
      path = "audio_player.directory",
      type = settings.type.DIRECTORY,
      exists = true,
      default = ""
    }
  }
)

settings.add("Markdown Preview",
  {
    {
      label = "Preview Mode",
      description = "How markdown previews opened from a document should be placed.",
      path = "markdown_preview_mode",
      type = settings.type.SELECTION,
      default = "right",
      values = {
        {"Right", "right"},
        {"New Tab", "newtab"},
        {"Bottom", "bottom"},
        {"Top", "top"},
        {"Left", "left"}
      }
    }
  }
)

settings.add("Development",
  {
    {
      label = "Core Log",
      description = "Open the list of logged messages.",
      type = settings.type.BUTTON,
      icon = "l",
      on_click = "core:open-log"
    },
    {
      label = "Log Items",
      description = "The maximum amount of entries to keep on the log UI.",
      path = "max_log_items",
      type = settings.type.NUMBER,
      default = 800,
      min = 150,
      max = 2000
    },
    {
      label = "Skip Plugins Version",
      description = "Do not verify the plugins required versions at startup.",
      path = "skip_plugins_version",
      type = settings.type.TOGGLE,
      default = false
    },
    {
      label = "Log Slow Coroutines",
      description = "Logs those taking more time than allowed.",
      path = "log_slow_threads",
      type = settings.type.TOGGLE,
      default = false
    },
    {
      label = "Native Tokenizer",
      description = "Provides up to 24X better performance, disable if working with Lua based one.",
      path = "native_tokenizer",
      type = settings.type.TOGGLE,
      default = true,
      on_apply = function(enabled)
        tokenizer.set_use_native(enabled)
        tokenizer.clear_native_cache()
        for _, doc in ipairs(core.docs) do
          doc.highlighter:soft_reset()
          doc:clear_cache(1, #doc.lines - 1)
        end
        core.redraw = true
      end
    },
    {
      label = "Draw Stats",
      description = "Draw the current FPS, the average frame time, and the "
        .. "maximum time that coroutines have to run per frame without "
        .. "affecting the rendering process plus the total amount of running "
        .. "coroutines. If set to 'uncapped' the system will draw at the "
        .. "maximum speed per second for benchmarking purposes.",
      path = "draw_stats",
      type = settings.type.SELECTION,
      default = false,
      values = {
        {"Off", false},
        {"On", true},
        {"Uncapped", "uncapped"}
      }
    },
    {
      label = "Draw Repainted Areas",
      description = "Toggles drawing debugging rectangles on the currently "
        .. "rendered sections of the window to help troubleshoot the "
        .. "renderer.",
      path = "draw_repaint",
      type = settings.type.TOGGLE,
      default = false,
      on_apply = function(value)
        renderer.show_debug(value)
      end
    }
  }
)

settings.add("Status Bar",
  {
    {
      label = "Enabled",
      description = "Toggle the default visibility of the status bar.",
      path = "statusbar.enabled",
      type = settings.type.TOGGLE,
      default = true,
      on_apply = function(enabled)
        if enabled then
          core.status_view:show()
        else
          core.status_view:hide()
        end
      end
    },
    {
      label = "Show Notifications",
      description = "Toggle the visibility of status messages.",
      path = "statusbar.messages",
      type = settings.type.TOGGLE,
      default = true,
      on_apply = function(enabled)
        core.status_view:display_messages(enabled)
      end
    },
    {
      label = "Messages Timeout",
      description = "The amount in seconds before a notification dissapears.",
      path = "message_timeout",
      type = settings.type.NUMBER,
      default = 5,
      min = 1,
      max = 30
    },
    {
      label = "Caret Column Mode",
      description = "Controls how the caret column is displayed in the status bar.",
      path = "caret_column_mode",
      type = settings.type.SELECTION,
      default = "char",
      values = {
        {"Character", "char"},
        {"Byte", "byte"}
      }
    }
  }
)

local dirmonitor_backends = {{"Auto", "auto"}}
for _, backend in ipairs(dirmonitor.backends()) do
  table.insert(dirmonitor_backends, {backend, backend})
end

settings.add("Advanced",
  {
    {
      label = "Directory Monitoring Backend",
      description = "The backend to monitor for file changes (restart required).",
      path = "dirmonitor_backend",
      type = settings.type.SELECTION,
      default = "auto",
      values = dirmonitor_backends,
      set_value = function(backend)
        if backend == "auto" then return nil end
        return backend
      end
    },
    {
      label = "Garbage Collector Pause",
      description = "How many times ram has to increase after last clean in order to reclean. Lower value makes GC more aggressive but may cause stuttering. (Ignored on Lua 5.4+)",
      path = "gc_pause",
      type = settings.type.NUMBER,
      default = 1.5,
      min = 1,
      max = 10,
      step = 0.1,
      set_value = function(value)
        return common.clamp(value, 1, 10)
      end,
      on_apply = function(value)
        if LUA_VERSION < 5.4 then
          collectgarbage("setpause", value*100)
        end
      end
    },
    {
      label = "Garbage Collector Step Multiplier",
      description = "How many times faster to run the collector in relation to allocations. Higher value makes GC more aggressive but may cause stuttering. (Ignored on Lua 5.4+)",
      path = "gc_step_multiplier",
      type = settings.type.NUMBER,
      default = 1.5,
      min = 1,
      max = 10,
      step = 0.1,
      set_value = function(value)
        return common.clamp(value, 1, 10)
      end,
      on_apply = function(value)
        if LUA_VERSION < 5.4 then
          collectgarbage("setstepmul", value*100)
        end
      end
    },
    {
      label = "Reload User Modules at Startup",
      description = "Reloads user and project modules after applying "
        .. "the graphically set configuration settings.",
      path = "reload_user_modules",
      type = settings.type.TOGGLE,
      default = false
    }
  }
)

---Retrieve from given config the associated value using the given path.
---@param conf table
---@param path string
---@param default any
---@return any | nil
local function get_config_value(conf, path, default)
  local sections = {};
  for match in (path.."."):gmatch("(.-)%.") do
    table.insert(sections, match);
  end

  local element = conf
  for _, section in ipairs(sections) do
    if type(element) == "table" and type(element[section]) ~= "nil" then
      element = element[section]
    else
      return default
    end
  end

  if type(element) == "nil" then
    return default
  end

  return element
end

---Loops the given config table using the given path and store the value.
---@param conf table
---@param path string
---@param value any
local function set_config_value(conf, path, value)
  local sections = {};
  for match in (path.."."):gmatch("(.-)%.") do
    table.insert(sections, match);
  end

  local sections_count = #sections

  if sections_count == 1 then
    conf[sections[1]] = value
    return
  elseif type(conf[sections[1]]) ~= "table" then
    conf[sections[1]] = {}
  end

  local element = conf
  for idx, section in ipairs(sections) do
    if type(element[section]) ~= "table" then
      element[section] = {}
      element = element[section]
    else
      element = element[section]
    end
    if idx + 1 == sections_count then break end
  end

  element[sections[sections_count]] = value
end

---Copy setting data without sharing mutable defaults or widget values.
---@param value any
---@return any copy
local function copy_setting_value(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = copy_setting_value(item) end
  return result
end

---Resolve a static or dynamic default without sharing mutable source tables.
---@param option settings.option
---@return any default
local function get_default_value(option)
  local value = option.default
  if type(value) == "function" then value = value() end
  return copy_setting_value(value)
end

---Remove a saved override and prune its empty parents, preserving siblings.
---@param conf table
---@param path string
local function remove_config_value(conf, path)
  local parents, keys = {}, {}
  local current = conf
  for key in path:gmatch("[^.]+") do
    if type(current) ~= "table" then return end
    parents[#parents + 1], keys[#keys + 1] = current, key
    current = current[key]
  end
  for index = #keys, 1, -1 do
    local parent, key = parents[index], keys[index]
    parent[key] = nil
    if next(parent) ~= nil then break end
  end
end

---Resolve a settings option path from a render context.
---@param option settings.option
---@param context? string|table
---@return string|nil
local function resolve_option_path(option, context)
  if type(option.path) ~= "string" then return nil end
  if type(context) == "string" then
    return "plugins." .. context .. "." .. option.path
  end
  if
    type(context) == "table"
    and type(context.path_prefix) == "string"
    and context.path_prefix ~= ""
  then
    return context.path_prefix .. "." .. option.path
  end
  return option.path
end

---Resolve a generated config path prefix against an inherited render context.
---@param path_prefix string
---@param context? string|table
---@return string
local function resolve_path_prefix(path_prefix, context)
  if path_prefix:find("^plugins%.") then return path_prefix end
  if type(context) == "string" and context ~= "" then
    return "plugins." .. context .. "." .. path_prefix
  end
  if
    type(context) == "table"
    and type(context.path_prefix) == "string"
    and context.path_prefix ~= ""
  then
    return context.path_prefix .. "." .. path_prefix
  end
  return path_prefix
end

---Get a list of system and user installed plugins.
---@return table<integer, string>
local function get_installed_plugins()
  local files, ordered = {}, {}
  for _, root_dir in ipairs {DATADIR, USERDIR} do
    local plugin_dir = root_dir .. "/plugins"
    for _, filename in ipairs(system.list_dir(plugin_dir) or {}) do
      local valid = false
      local file_info = system.get_file_info(plugin_dir .. "/" .. filename)
      if file_info then
        if
          file_info.type == "file"
          and
          filename:match("%.lua$")
          and
          not filename:match("^language_")
        then
          valid = true
          filename = filename:gsub("%.lua$", "")
        elseif file_info.type == "dir" then
          if system.get_file_info(plugin_dir .. "/" .. filename .. "/init.lua") then
            valid = true
          end
        end
      end
      if valid then
        if not files[filename] then table.insert(ordered, filename) end
        files[filename] = true
      end
    end
  end

  table.sort(ordered)

  return ordered
end

---Get a list of system and user installed colors.
---@return table<integer, table>
local function get_installed_colors()
  local files, ordered = {}, {}

  for _, root_dir in ipairs {DATADIR, USERDIR} do
    local dir = root_dir .. "/colors"
    for _, filename in ipairs(system.list_dir(dir) or {}) do
      local file_info = system.get_file_info(dir .. "/" .. filename)
      if
        file_info and file_info.type == "file"
        and
        filename:match("%.lua$")
      then
        -- read colors
        local file = io.open(dir .. "/" .. filename, "r")
        local contents = ""
        if file then
          contents = file:read("*a") or ""
          file:close()
        end
        local colors = {}
        for r, g, b in contents:gmatch("#(%x%x)(%x%x)(%x%x)") do
          r = tonumber(r, 16)
          g = tonumber(g, 16)
          b = tonumber(b, 16)
          table.insert(colors, { r, g, b, 0xff })
        end
        -- sort colors from darker to lighter
        table.sort(colors, function(a, b)
          return a[1] + a[2] + a[3] < b[1] + b[2] + b[3]
        end)
        -- remove duplicate colors
        local b = {}
        for i = #colors, 1, -1 do
          local a = colors[i]
          if a[1] == b[1] and a[2] == b[2] and a[3] == b[3] then
            table.remove(colors, i)
          else
            b = colors[i]
          end
        end
        -- insert color to ordered table if not duplicate
        filename = filename:gsub("%.lua$", "")
        if not files[filename] then
          table.insert(ordered, {name = filename, colors = colors})
        end
        files[filename] = true
      end
    end
  end

  table.sort(ordered, function(a, b) return a.name < b.name end)

  return ordered
end

---Capitalize first letter of every word.
---Taken from core.command.
---@param words string
---@return string
local function capitalize_first(words)
  return words:sub(1, 1):upper() .. words:sub(2)
end

---Similar to command prettify_name but also takes care of underscores.
---@param name string
---@return string
local function prettify_name(name)
  name = name:gsub("[%-_]", " "):gsub("%S+", capitalize_first)
  return name
end

---Load config options from the USERDIR user_settings.lua and store them on
---settings.config for later usage.
local function load_settings()
  local ok, t = pcall(dofile, USERDIR .. "/user_settings.lua")
  settings.config = ok and t.config or {}
  -- do not wait for settings plugin to merge user settings and
  -- prioritize this option to prevent plugins from using wrong backend
  if settings.config.dirmonitor_backend then
    config.dirmonitor_backend = settings.config.dirmonitor_backend
  end
  -- When performing a core restart the borderless mode gets reset on core.init
  -- to prevent possible issue of re-introducing system borders we manually set
  -- this flag from user stored settings.
  if settings.config.borderless ~= nil then
    config.borderless = settings.config.borderless
  end
end

---Save current config options into USERDIR/user_settings.lua and report errors.
---@return boolean saved Whether writing and closing the file succeeded
local function save_settings()
  local filename = USERDIR .. "/user_settings.lua"
  local fp, err = io.open(filename, "w")
  if fp then
    local output = "{\n  [\"config\"] = "
      .. common.serialize(
        settings.config,
        { pretty = true, escape = true, sort = true, initial_indent = 1 }
      ):gsub("^%s+", "")
      .. "\n}\n"
    local written, write_err = fp:write("return ", output)
    local closed, close_err = fp:close()
    if written and closed then return true end
    err = write_err or close_err
  end
  core.error("Could not save settings to %s: %s", filename, err)
  return false
end

---Apply a keybinding and optionally save it.
---@param cmd string
---@param bindings? table<integer, string>
---@param skip_save? boolean
---@return table | nil
local function apply_keybinding(cmd, bindings, skip_save)
  bindings = bindings or {}
  local row_value = nil
  local changed = false

  local original_bindings = { keymap.get_binding(cmd) }
  for _, binding in ipairs(original_bindings) do
    keymap.unbind(binding, cmd)
  end

  if #bindings > 0 then
    if
      not skip_save
      and
      settings.config.custom_keybindings
      and
      settings.config.custom_keybindings[cmd]
    then
      settings.config.custom_keybindings[cmd] = {}
    end
    local shortcuts = ""
    for _, binding in ipairs(bindings) do
      if not binding:match("%+$") and binding ~= "" and binding ~= "none" then
        keymap.add({[binding] = cmd})
        shortcuts = shortcuts .. binding .. "\n"
        if not skip_save then
          if not settings.config.custom_keybindings then
            settings.config.custom_keybindings = {}
            settings.config.custom_keybindings[cmd] = {}
          elseif not settings.config.custom_keybindings[cmd] then
            settings.config.custom_keybindings[cmd] = {}
          end
          table.insert(settings.config.custom_keybindings[cmd], binding)
          changed = true
        end
      end
    end
    if shortcuts ~= "" then
      local bindings_list = shortcuts:gsub("\n$", "")
      row_value = {
        style.text, cmd, ListBox.COLEND, style.dim, bindings_list
      }
    end
  elseif not skip_save then
    if not settings.config.custom_keybindings then
      settings.config.custom_keybindings = {}
    end
    settings.config.custom_keybindings[cmd] = {}
    changed = true
  end

  if changed then
    save_settings()
  end

  if not row_value then
    row_value = {
      style.text, cmd, ListBox.COLEND, style.dim, "none"
    }
  end

  return row_value
end

---Copy font metadata, fill missing options, and expand portable font paths.
---@param value table
---@return table metadata
local function prepare_font_settings(value)
  value = copy_setting_value(value)
  local font_options = value.options or {
    size = 15,
    antialiasing = "subpixel",
    hinting = "slight"
  }
  font_options.size = font_options.size or 15
  font_options.antialiasing = font_options.antialiasing or "subpixel"
  font_options.hinting = font_options.hinting or "slight"

  value.options = font_options
  for _, font in ipairs(value.fonts) do
    for token, directory in pairs { ["{datadir}"] = DATADIR, ["{userdir}"] = USERDIR } do
      if font.path:sub(1, #token) == token then
        font.path = directory .. font.path:sub(#token + 1)
        break
      end
    end
  end
  return value
end

---Load a font group before modifying live or saved configuration.
---@param value table
---@return renderer.font? group
---@return string? error
local function load_font_settings(value)
  local fonts = {}
  value = prepare_font_settings(value)
  for _, font in ipairs(value.fonts) do
    local ok, data = pcall(renderer.font.load,
      font.path, value.options.size * SCALE, value.options)
    if not ok then return nil, data end
    fonts[#fonts + 1] = data
  end
  return renderer.font.group(fonts)
end

---Keep saved font metadata portable without modifying the live control data.
---@param value table
---@return table saved
local function serialize_font_settings(value)
  value = copy_setting_value(value)
  for _, font in ipairs(value.fonts) do
    for token, directory in pairs { ["{datadir}"] = DATADIR, ["{userdir}"] = USERDIR } do
      if font.path:sub(1, #directory) == directory then
        font.path = token .. font.path:sub(#directory + 1)
        break
      end
    end
  end
  return value
end

---Load saved fonts into the config path or fonts_list table.
---@param option settings.option
---@param path string
---@param saved_value table
local function merge_font_settings(option, path, saved_value)
  local group, err = load_font_settings(saved_value)
  option.font_error = not group or nil
  if group then
    set_config_value(option.fonts_list or config,
      option.fonts_list and option.path or path, group)
  else
    core.error("Settings: could not load %s: %s", path, err)
  end
end

---Load the user_settings.lua stored options for a plugin into global config.
---@param plugin_name string
---@param options settings.option[]
---@param context? string|table
local function merge_plugin_settings(plugin_name, options, context)
  context = context or plugin_name

  local function merge_option(option)
    local otype = type(option.type) == "string" and option.type:lower() or ""
    if option.type == settings.type.SUBCONFIG or otype == "subconfig" then
      if type(option.spec) == "table" then
        local subcontext = context
        if type(option.spec.path_prefix) == "string" and option.spec.path_prefix ~= "" then
          subcontext = {
            path_prefix = resolve_path_prefix(option.spec.path_prefix, context)
          }
        end
        merge_plugin_settings(plugin_name, option.spec, subcontext)
      end
    else
      local path = resolve_option_path(option, context)
      if type(path) == "string" then
        local saved_value = get_config_value(settings.config, path)
        if type(saved_value) ~= "nil" then
          if option.type == settings.type.FONT or otype == "font" then
            merge_font_settings(option, path, saved_value)
          else
            set_config_value(config, path, saved_value)
          end
          if option.on_apply then
            option.on_apply(saved_value)
          end
        end
      end
    end
  end

  if type(options.sections) == "table" then
    for _, section in pairs(options.sections) do
      local section_options = section.options or section
      if type(section_options) == "table" then
        for _, option in ipairs(section_options) do
          merge_option(option)
        end
      end
    end
  else
    for _, option in ipairs(options) do
      merge_option(option)
    end
  end
end

---Merge previously saved settings without destroying the config table.
local function merge_settings()
  if type(settings.config) ~= "table" then return end

  -- merge core settings
  for _, section in ipairs(settings.sections) do
    local options = settings.core[section]
    for _, option in ipairs(options) do
      if type(option.path) == "string" then
        local saved_value = get_config_value(settings.config, option.path)
        if type(saved_value) ~= "nil" then
          local otype = type(option.type) == "string" and option.type:lower() or ""
          if option.type == settings.type.FONT or otype == "font" then
            merge_font_settings(option, option.path, saved_value)
          else
            set_config_value(config, option.path, saved_value)
          end
          if option.on_apply then
            option.on_apply(saved_value)
          end
        end
      end
    end
  end

  -- merge plugin settings
  table.sort(settings.plugin_sections)
  for _, section in ipairs(settings.plugin_sections) do
    local plugins = settings.plugins[section]
    for plugin_name, options in pairs(plugins) do
      merge_plugin_settings(plugin_name, options)
    end
  end

  -- apply custom keybindings
  if settings.config.custom_keybindings then
    for cmd, bindings in pairs(settings.config.custom_keybindings) do
      apply_keybinding(cmd, bindings, true)
    end
  end
end

---Scan all plugins to check if they define a config_spec and load it.
local function scan_plugins_spec()
  for plugin, conf in pairs(config.plugins) do
    if type(conf) == "table" and conf.config_spec then
      settings.add(
        conf.config_spec.name,
        conf.config_spec,
        plugin
      )
    end
  end
end

---Called at core first run to store the default keybindings.
local function store_default_keybindings()
  for name, _ in pairs(command.map) do
    local keys = { keymap.get_binding(name) }
    if #keys > 0 then
      settings.default_keybindings[name] = keys
    end
  end
end

---Widgets belonging to one searchable setting, kept together while filtering.
---@class plugins.settings.optiongroup
---@field text string Lowercase section, label, description and config path
---@field controls widget[] Existing controls, including the label and description
---@field reset plugins.settings.resetbutton?

---Search metadata for a section container.
---@class plugins.settings.section
---@field name string Lowercase section name
---@field options plugins.settings.optiongroup[]

---Match every query word literally, without treating punctuation as patterns.
---@param text string Lowercase searchable text
---@param words string[] Lowercase query words
---@return boolean matched
local function matches_settings(text, words)
  for _, word in ipairs(words) do
    if not text:find(word, 1, true) then return false end
  end
  return true
end

---Settings-owned section filtering using FoldingBook's existing pane registry.
---@class plugins.settings.sections : widget.foldingbook
---@overload fun(parent:widget, placeholder:string):plugins.settings.sections
---@field all_panes widget.foldingbook.pane[] Complete registry, including filtered panes
---@field entries table<widget, plugins.settings.section>
---@field expansion table<widget.foldingbook.pane, boolean> Expansion before searching
---@field filter_value string Normalized query, evaluated only when changed
---@field search widget.textbox Fixed search field above the scrolling sections
---@field empty widget.label Message displayed when the query has no matches
---@field installed_list widget.widgetlist? Plugin enable/disable rows
local SettingsSections = FoldingBook:extend()

---Create a scrolling section list with a fixed search field.
---@param parent widget
---@param placeholder string
function SettingsSections:new(parent, placeholder)
  SettingsSections.super.new(self, parent)
  self.border.width = 0
  self.all_panes, self.entries, self.expansion = self.panes, {}, {}
  self.filter_value = ""
  self.search = TextBox(parent, "", placeholder, { clearable = true })
  self.empty = Label(parent, "No settings match your search.", true)
  self.empty:hide()
  local sections = self
  ---Filter on text edits without evaluating queries during update or drawing.
  ---@param value string
  function self.search:on_change(value) sections:filter(value) end
end

---Look up sections even when they are excluded from the current search.
---@param name string
---@return widget.foldingbook.pane?
function SettingsSections:get_pane(name)
  for _, pane in ipairs(self.all_panes) do
    if pane.name == name then return pane end
  end
end

---Register a section in the complete list without disturbing filtered results.
---@param name string
---@param label string
---@return widget container
function SettingsSections:add_pane(name, label)
  local visible = self.panes
  self.panes = self.all_panes
  local container = SettingsSections.super.add_pane(self, name, label)
  self.panes = visible
  self.entries[container] = { name = label:lower(), options = {} }
  return container
end

---Remove a plugin section and refresh the active query without rebuilding others.
---@param name string
---@return boolean removed
function SettingsSections:delete_pane(name)
  local pane = self:get_pane(name)
  if not pane then return false end
  self.panes = self.all_panes
  local removed = SettingsSections.super.delete_pane(self, name)
  self.entries[pane.container], self.expansion[pane] = nil, nil
  self:filter(self.filter_value, true)
  return removed
end

---Filter existing option groups and plugin rows, restoring expansion on clear.
---@param value string Search words matched against cached option metadata
---@param force? boolean Reapply after registering or removing plugin options
function SettingsSections:filter(value, force)
  local query = value:lower():match("^%s*(.-)%s*$")
  if query == self.filter_value and not force then return end
  local words, visible = {}, {}
  for word in query:gmatch("%S+") do words[#words + 1] = word end
  for _, pane in ipairs(self.all_panes) do
    local entry = self.entries[pane.container]
    local found = query == ""
    for _, group in ipairs(entry.options) do
      local matched = matches_settings(group.text, words)
      found = found or matched
      for _, child in ipairs(group.controls) do
        local show = matched
        if child == group.reset then
          child.filter_matches = matched
          show = matched and child.enabled
          if child.visible ~= show then child.layout_width = nil end
        end
        if child.visible ~= show then
          if show then child:show() else child:hide() end
        end
      end
    end
    local list = self.installed_list
    if list and list.parent == pane.container then
      local matching, count = {}, 0
      local section_matches = matches_settings(entry.name, words)
      for _, item in ipairs(list.items) do
        local matched = section_matches or matches_settings(item.filter_text:lower(), words)
        matching[item.data] = matched
        found = found or matched
        if matched then count = count + 1 end
      end
      list:filter(function(data) return matching[data] end)
      list:set_visible_row_count(query == "" and 10 or math.max(1, math.min(10, count)))
    end
    if query ~= "" then
      if self.expansion[pane] == nil then self.expansion[pane] = pane.expanded end
      pane.expanded = found
    elseif self.expansion[pane] ~= nil then
      pane.expanded = self.expansion[pane]
    end
    -- Search updates are immediate; ordinary section clicks retain their slides.
    pane.container.animations = {}
    pane.container.animating = false
    pane.container.first_hide = true
    if found then
      visible[#visible + 1] = pane
      pane.tab:show()
      if pane.expanded then pane.container:show() else pane.container:hide() end
    else
      pane.tab:hide()
      pane.container:hide()
    end
    pane.tab:set_icon(pane.expanded and "-" or "+")
  end
  self.panes, self.filter_value = visible, query
  if query == "" then self.expansion = {} end
  self.scroll.y, self.scroll.to.y = 0, 0
  if #visible == 0 then self.empty:show() else self.empty:hide() end
  core.redraw = true
end

---Keep section separators inside the scrolling viewport below the search field.
---@return boolean drawn
function SettingsSections:draw()
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  local drawn = SettingsSections.super.draw(self)
  core.pop_clip_rect()
  return drawn
end

---@class settings.ui : widget
---@field private notebook widget.notebook
---@field private core widget
---@field private colors widget
---@field private plugins widget
---@field private keybinds widget
---@field private core_sections plugins.settings.sections
---@field private plugin_sections plugins.settings.sections
local Settings = Widget:extend()

---Constructor
function Settings:new()
  Settings.super.new(self, nil, false)

  self.name = "Settings"
  self.defer_draw = false
  self.border.width = 0
  self.draggable = false
  self.scrollable = false

  ---@type widget.notebook
  self.notebook = NoteBook(self)
  self.notebook.size.x = 250
  self.notebook.size.y = 300
  self.notebook.border.width = 0

  self.core = self.notebook:add_pane("core", "Core")
  self.colors = self.notebook:add_pane("colors", "Colors")
  self.plugins = self.notebook:add_pane("plugins", "Plugins")
  self.keybinds = self.notebook:add_pane("keybindings", "Keybindings")
  self.core.scrollable, self.plugins.scrollable = false, false

  self.notebook:set_pane_icon("core", "A")
  self.notebook:set_pane_icon("colors", "E")
  self.notebook:set_pane_icon("plugins", "p")
  self.notebook:set_pane_icon("keybindings", "k")

  self.core_sections = SettingsSections(self.core, "filter settings...")
  self.plugin_sections = SettingsSections(self.plugins, "filter plugins and settings...")

  if command.is_valid("plugin-manager:show") then
    ---@type widget.button
    self.plugin_button = Button(self.plugins)
    self.plugin_button:set_icon("p")
    self.plugin_button.border.width = 0
    self.plugin_button.padding = { x = style.padding.x / 2, y = style.padding.y / 2 }
    self.plugin_button:set_tooltip("Open Plugin Manager")
    function self.plugin_button:draw_background() end
    function self.plugin_button:on_click() command.perform("plugin-manager:show") end
  end

  self:load_core_settings()
  self:load_color_settings()
  self:load_plugin_settings()
  self:load_keymap_settings()
  self.core_sections:filter("", true)
  self.plugin_sections:filter("", true)
end

---Compact action beside a setting label, visible only for saved overrides.
---@class plugins.settings.resetbutton : widget.button
---@field enabled boolean Whether a saved override can be removed
---@field heading widget The option's label or toggle
---@field layout_width number? Last available width used to wrap the heading
---@field filter_matches boolean? Whether the option matches the active search
local ResetButton = Button:extend()

---Create a reset action without changing the general Widget button API.
---@param parent widget
---@param heading widget
---@param path string
function ResetButton:new(parent, heading, path)
  ResetButton.super.new(self, parent, "Reset")
  self.heading = heading
  self.border.width = 0
  self.padding.x, self.padding.y = style.padding.x / 2, 0
  self:toggle_background(false)
  self:set_label("Reset")
  self:set_tooltip("Restore default and remove saved override")
  self:set_enabled(get_config_value(settings.config, path) ~= nil)
end

---Refresh visibility after editing or resetting, including saved false values.
---@param enabled boolean
function ResetButton:set_enabled(enabled)
  if self.enabled == enabled then return end
  self.enabled = enabled
  self.layout_width = nil
  if enabled and self.filter_matches ~= false then
    self:show()
  else
    self.hover_text, self.hover_back = nil, nil
    self:hide()
  end
  core.redraw = true
end

---Rebuild only a custom setting list, retaining its filter and valid scroll.
---@param list widget.widgetlist
---@param option settings.option
---@param value any
local function populate_widget_list(list, option, value)
  local filter = list.filter_value
  local scroll, target = list.scroll.y, list.scroll.to.y
  list:clear()
  local items = type(option.items) == "function"
    and option.items(value) or option.items or {}
  for _, item in ipairs(items) do
    local text = option.item_text and option.item_text(item) or tostring(item)
    list:add_item(item, function(row, data)
      if option.build_item then
        option.build_item(row, data, value, function(new_value)
          list:on_change(new_value)
        end)
      end
    end, text)
  end
  list:filter(filter)
  list:set_visible_row_count(option.visible_rows or 8)
  local maximum = math.max(0, list:get_scrollable_size() - list.size.y)
  list.scroll.y, list.scroll.to.y = math.min(scroll, maximum), math.min(target, maximum)
end

---Helper function to add control for core, plugin, and standalone settings.
---@param pane widget
---@param option settings.option
---@param context? string|table Plugin name or standalone render context.
local function add_control(pane, option, context)
  local child_count = #pane.childs
  local found = false
  local path = resolve_option_path(option, context)
  local heading
  local default_value = get_default_value(option)
  local option_value = nil
  if type(path) ~= "nil" then
    option_value = copy_setting_value(get_config_value(config, path, default_value))
  end

  if option.get_value then
    option_value = option.get_value(option_value)
  end

  ---@type widget
  local widget = nil

  if type(option.type) == "string" then
    option.type = settings.type[option.type:upper()]
  end

  if option.type == settings.type.NUMBER then
    ---@type widget.label
    heading = Label(pane, option.label .. ":", true)
    ---@type widget.numberbox
    local number = NumberBox(
      pane, option_value, option.min, option.max, option.step
    )
    widget = number
    found = true

  elseif option.type == settings.type.TOGGLE then
    ---@type widget.toggle
    local toggle = Toggle(pane, option.label, option_value)
    heading = toggle
    widget = toggle
    found = true

  elseif option.type == settings.type.STRING then
    ---@type widget.label
    heading = Label(pane, option.label .. ":", true)
    ---@type widget.textbox
    local string = TextBox(pane, option_value or "")
    widget = string
    found = true

  elseif option.type == settings.type.SELECTION then
    ---@type widget.label
    heading = Label(pane, option.label .. ":", true)
    ---@type widget.selectbox
    local select = SelectBox(pane)
    for _, data in pairs(option.values) do
      select:add_option(data[1], data[2])
    end
    for idx, _ in ipairs(select.list.rows) do
      if select.list:get_row_data(idx) == option_value then
        select:set_selected(idx-1)
        break
      end
    end
    widget = select
    found = true

  elseif option.type == settings.type.BUTTON then
    ---@type widget.button
    local button = Button(pane, option.label)
    if option.icon then
      button:set_icon(option.icon)
    end
    if option.on_click then
      local command_type = type(option.on_click)
      if command_type == "string" then
        function button:on_click()
          command.perform(option.on_click)
        end
      elseif command_type == "function" then
        button.on_click = option.on_click
      end
    end
    widget = button
    found = true

  elseif option.type == settings.type.SUBCONFIG then
    ---@type widget.button
    local button = Button(pane, option.label)
    button:set_icon("P")
    function button:on_click()
      settings.show_config(option.title or option.label, option.spec, context)
    end
    widget = button
    found = true

  elseif option.type == settings.type.LIST_STRINGS then
    ---@type widget.label
    heading = Label(pane, option.label .. ":", true)
    ---@type widget.itemslist
    local list = ItemsList(pane)
    if type(option_value) == "table" then
      for _, value in ipairs(option_value) do
        list:add_item(value)
      end
    end
    widget = list
    found = true

  elseif option.type == settings.type.LIST_WIDGETS then
    ---@type widget.label
    heading = Label(pane, option.label .. ":", true)
    ---@type widget.textbox?
    local filter
    if option.filterable ~= false then
      filter = TextBox(
        pane,
        "",
        option.filter_placeholder or "filter items..."
      )
    end
    ---@type widget.widgetlist
    local list = WidgetList(pane)
    populate_widget_list(list, option, option_value)
    if filter then
      function filter:on_change(value)
        list:filter(value)
      end
    end
    widget = list
    found = true

  elseif option.type == settings.type.FONT then
    --get fonts without conversion to renderer.font
    if type(path) ~= "nil" then
      if not option.font_error then
        option_value = get_config_value(settings.config, path, default_value)
      else
        --fallback to default fonts if error loading user defined ones
        option_value = default_value
      end
    end
     ---@type widget.label
    heading = Label(pane, option.label .. ":", true)
    ---@type widget.fontslist
    local fonts = FontsList(pane)
    if type(option_value) == "table" then
      option_value = prepare_font_settings(option_value)
      for _, font in ipairs(option_value.fonts) do
        fonts:add_font(font)
      end

      fonts:set_options(option_value.options)
    end
    widget = fonts
    found = true

  elseif option.type == settings.type.FILE then
    ---@type widget.label
    heading = Label(pane, option.label .. ":", true)
    ---@type widget.filepicker
    local file = FilePicker(pane, option_value or "")
    if option.exists then
      file:set_mode(FilePicker.mode.FILE_EXISTS)
    else
      file:set_mode(FilePicker.mode.FILE)
    end
    file.filters = option.filters or {}
    widget = file
    found = true

  elseif option.type == settings.type.DIRECTORY then
    ---@type widget.label
    heading = Label(pane, option.label .. ":", true)
    ---@type widget.filepicker
    local file = FilePicker(pane, option_value or "")
    if option.exists then
      file:set_mode(FilePicker.mode.DIRECTORY_EXISTS)
    else
      file:set_mode(FilePicker.mode.DIRECTORY)
    end
    file.filters = option.filters or {}
    widget = file
    found = true

  elseif option.type == settings.type.COLOR then
    ---@type widget.label
    heading = Label(pane, option.label .. ":", true)
    ---@type widget.colorpicker
    local color = ColorPicker(pane, option_value)
    widget = color
    found = true
  end

  if widget and type(path) ~= "nil" then
    local previous_selection = widget:is(SelectBox) and widget:get_selected()
    local restoring = false
    local reset

    ---Refresh one setting without saving changes emitted by its widget setters.
    ---@param font_value? table Metadata for a font control instead of its runtime group
    local function refresh_control(font_value)
      local value = copy_setting_value(get_config_value(config, path, default_value))
      if widget:is(FontsList) then
        value = font_value and prepare_font_settings(font_value)
      elseif option.get_value then
        value = option.get_value(value)
      end
      restoring = true
      if widget:is(NumberBox) then widget:set_value(value)
      elseif widget:is(Toggle) then widget:set_toggle(value)
      elseif widget:is(TextBox) then widget:set_text(value or "")
      elseif widget:is(SelectBox) then
        widget:set_selected(0)
        for index in ipairs(widget.list.rows) do
          if widget.list:get_row_data(index) == value then
            widget:set_selected(index - 1)
            break
          end
        end
      elseif widget:is(ItemsList) then
        widget.list:clear()
        for _, item in ipairs(value or {}) do widget:add_item(item) end
      elseif widget:is(WidgetList) then
        populate_widget_list(widget, option, value)
      elseif widget:is(FontsList) then
        widget.list:clear()
        for _, font in ipairs(value and value.fonts or {}) do widget:add_font(font) end
        if value then widget:set_options(value.options) end
      elseif widget:is(FilePicker) then widget:set_path(value)
      elseif widget:is(ColorPicker) then widget:set_color(value)
      end
      restoring = false
      if widget:is(SelectBox) then previous_selection = widget:get_selected() end
      core.redraw = true
    end

    ---Apply edited values or a reset through the same conversions and callbacks.
    ---@param value any Value in the control's edit representation
    ---@param resetting? boolean Remove the saved override instead of saving the value
    ---@return boolean applied
    local function apply_value(value, resetting)
      if option.set_value then
        local ok, result, err = pcall(option.set_value, value)
        if not ok or result == nil and err then
          err = ok and err or result
          core.error("Could not save %s: %s", option.label, err)
          if widget:is(SelectBox) then
            restoring = true
            widget:set_selected(previous_selection)
            restoring = false
          end
          return false
        end
        value = result
      end

      local live_value = copy_setting_value(value)
      if widget:is(FontsList) and value ~= nil then
        local err
        live_value, err = load_font_settings(value)
        if not live_value then
          core.error("Could not load %s: %s", option.label, err)
          return false
        end
        value = serialize_font_settings(value)
      end

      local previous_saved = get_config_value(settings.config, path)
      if resetting or value == nil then
        remove_config_value(settings.config, path)
      else
        set_config_value(settings.config, path, copy_setting_value(value))
      end
      if not save_settings() then
        if previous_saved == nil then remove_config_value(settings.config, path)
        else set_config_value(settings.config, path, previous_saved) end
        return false
      end

      if widget:is(FontsList) then
        set_config_value(option.fonts_list or config,
          option.fonts_list and option.path or path, live_value)
        option.font_error = nil
      else
        set_config_value(config, path, live_value)
      end
      if option.on_apply then
        option.on_apply(value)
      end
      if resetting then refresh_control(value) end
      if widget:is(SelectBox) then previous_selection = widget:get_selected() end
      if reset then reset:set_enabled(get_config_value(settings.config, path) ~= nil) end
      return true
    end

    ---Save user edits while ignoring callbacks from a programmatic refresh.
    ---@param value any New widget value
    function widget:on_change(value)
      if restoring then return end
      if self:is(SelectBox) then value = self:get_selected_data()
      elseif self:is(ItemsList) then value = self:get_items()
      elseif self:is(FontsList) then
        value = { fonts = self:get_fonts(), options = self:get_options() }
      end
      apply_value(value)
    end

    if heading then
      reset = ResetButton(pane, heading, path)
      heading.settings_reset = reset
      widget.reset_button = reset
      ---Restore a fresh declared default and remove the persisted override.
      function reset:on_click()
        self:set_enabled(get_config_value(settings.config, path) ~= nil)
        if not self.enabled then return end
        local ok, value = pcall(get_default_value, option)
        if not ok then
          core.error("Could not reset %s: %s", option.label, value)
          return
        end
        default_value = value
        apply_value(copy_setting_value(default_value), true)
      end
    end
  end

  if (option.description or default_value ~= nil) and found then
    local text = option.description or ""
    local default = ""
    local default_type = type(default_value)
    if default_type ~= "table" and default_type ~= "nil" then
      if text ~= "" then
        text = text .. " "
      end
      default = string.format("(default: %s)", default_value)
    end
     ---@type widget.label
    local description = Label(pane, text .. default, true)
    description.desc = true
  end
  if pane.parent and pane.parent:is(SettingsSections) then
    local entry = pane.parent.entries[pane]
    ---@type plugins.settings.optiongroup
    local group = {
      text = table.concat({ entry.name, option.label, option.description or "", path or "" }, " "):lower(),
      controls = {}, reset = widget and widget.reset_button
    }
    for index = 1, #pane.childs - child_count do
      group.controls[#group.controls + 1] = pane.childs[index]
    end
    entry.options[#entry.options + 1] = group
  end
end

---Generate all the widgets for core settings.
function Settings:load_core_settings()
  for _, section in ipairs(settings.sections) do
    local options = settings.core[section]

    ---@type widget|widget.foldingbook.pane|nil
    local pane = self.core_sections:get_pane(section)
    if not pane then
      pane = self.core_sections:add_pane(section, section)
    else
      pane = pane.container
    end

    for _, opt in ipairs(options) do
      ---@type settings.option
      local option = opt
      add_control(pane, option)
    end
  end
end

---Function in charge of rendering the colors column of the color pane.
---@param self widget.listbox
---@oaram row integer
---@param x integer
---@param y integer
---@param font renderer.font
---@param color renderer.color
---@param only_calc boolean
---@return number width
---@return number height
local function on_color_draw(self, row, x, y, font, color, only_calc)
  local w = self:get_width() - (x - self.position.x) - style.padding.x
  local h = font:get_height()

  if not only_calc then
    local row_data = self:get_row_data(row)
    local width = w/#row_data.colors

    for i = 1, #row_data.colors do
      renderer.draw_rect(x + ((i - 1) * width), y, width, h, row_data.colors[i])
    end
  end

  return w, h
end

---Generate the list of all available colors with preview
function Settings:load_color_settings()
  self.colors.scrollable = false

  local colors = get_installed_colors()

  ---@type widget.textbox
  local textbox = TextBox(self.colors, "", "filter colors...", { clearable = true })

  ---@type widget.listbox
  local listbox = ListBox(self.colors)

  listbox.border.width = 0

  listbox:add_column("Theme")
  listbox:add_column("Colors")

  local current_theme = settings.config.theme or "default"

  for idx, details in ipairs(colors) do
    local name = details.name
    if current_theme == name then
      listbox:set_selected(idx)
    end
    listbox:add_row({
      {type = "color", container = style, name = "text"}, name,
      ListBox.COLEND,
      on_color_draw
    }, {name = name, colors = details.colors})
  end

  function textbox:on_change(value)
    listbox:filter(value)
  end

  function listbox:on_row_click(idx, data)
    core.reload_module("colors." .. data.name)
    settings.config.theme = data.name
    save_settings()
  end

  ---@param self widget
  function self.colors:update_positions()
    textbox:set_position(style.padding.x / 2, style.padding.y)
    textbox:set_size(math.max(0, self.size.x - style.padding.x))
    listbox:set_position(0, textbox:get_bottom())
    listbox:set_size(
      self:get_width() - self.border.width * 2,
      math.max(0, self.size.y - textbox:get_bottom())
    )
  end
end

---Unload a plugin settings from plugins section.
---@param plugin string
function Settings:disable_plugin(plugin)
  for _, section in ipairs(settings.plugin_sections) do
    local plugins = settings.plugins[section]

    for plugin_name, options in pairs(plugins) do
      if plugin_name == plugin then
        self.plugin_sections:delete_pane(section)
      end
    end
  end

  if
    type(settings.config.enabled_plugins) == "table"
    and
    settings.config.enabled_plugins[plugin]
  then
    settings.config.enabled_plugins[plugin] = nil
  end
  if type(settings.config.disabled_plugins) ~= "table" then
    settings.config.disabled_plugins = {}
  end

  settings.config.disabled_plugins[plugin] = true
  save_settings()
end

---Load plugin and append its settings to the plugins section.
---@param plugin string
function Settings:enable_plugin(plugin)
  local loaded = false
  local config_type = type(config.plugins[plugin])
  if config_type == "boolean" or config_type == "nil" then
    config.plugins[plugin] = {}
    loaded = true
  end

  require("plugins." .. plugin)

  if config.plugins[plugin] and config.plugins[plugin].config_spec then
    local conf = config.plugins[plugin].config_spec
    settings.add(conf.name, conf, plugin, true)
  end

  for _, section in ipairs(settings.plugin_sections) do
    local plugins = settings.plugins[section]

    for plugin_name, options in pairs(plugins) do
      if plugin_name == plugin then
        ---@type widget|widget.foldingbook.pane|nil
        local pane = self.plugin_sections:get_pane(section)
        if not pane then
          pane = self.plugin_sections:add_pane(section, section)
        else
          pane = pane.container
        end

        merge_plugin_settings(plugin, options)

        for _, opt in ipairs(options) do
          ---@type settings.option
          local option = opt
          add_control(pane, option, plugin_name)
        end
      end
    end
  end

  if
    type(settings.config.disabled_plugins) == "table"
    and
    settings.config.disabled_plugins[plugin]
  then
    settings.config.disabled_plugins[plugin] = nil
  end
  if type(settings.config.enabled_plugins) ~= "table" then
    settings.config.enabled_plugins = {}
  end

  settings.config.enabled_plugins[plugin] = true
  save_settings()

  if loaded then
    core.log("Loaded '%s' plugin", plugin)
  end
  self.plugin_sections:filter(self.plugin_sections.search:get_text(), true)
end

---Generate all the widgets for plugin settings.
function Settings:load_plugin_settings()
  ---@type widget|widget.foldingbook.pane|nil
  local pane = self.plugin_sections:get_pane("enable_disable")
  if not pane then
    pane = self.plugin_sections:add_pane("enable_disable", "Installed")
  else
    pane = pane.container
  end

  -- requires earlier access to startup process
  Label(
    pane,
    "Notice: disabling plugins will not take effect until next restart",
    true
  )

  Line(pane, 2, 10)

  local list = WidgetList(pane)
  self.plugin_sections.installed_list = list

  local plugins = get_installed_plugins()
  for _, plugin in ipairs(plugins) do
    if plugin ~= "settings" then
      local enabled = false

      if
        (
          type(config.plugins[plugin]) ~= "nil"
          and
          config.plugins[plugin] ~= false
        )
        or
        (
          settings.config.enabled_plugins
          and
          settings.config.enabled_plugins[plugin]
          and
          --ensure plugin is not disabled on user or project module
          config.plugins[plugin] ~= false
        )
      then
        enabled = true
      end

      local this = self

      local name
      if
        config.plugins[plugin]
        and config.plugins[plugin].config_spec
        and config.plugins[plugin].config_spec.name
      then
        name = config.plugins[plugin].config_spec.name
      else
        name = prettify_name(plugin)
      end

      list:add_item({
        enabled = enabled,
        name = name,
        plugin = plugin
      }, function(row, item)
        local label = Label(row, item.name)
        row:set_child_properties(label, { stretch = 1 })

        ---@type widget.toggle
        local toggle = Toggle(row, "", item.enabled)
        function toggle:on_change(value)
          if value then
            this:enable_plugin(item.plugin)
          else
            this:disable_plugin(item.plugin)
          end
        end
      end, name .. " " .. plugin)
    end
  end
  list:set_visible_row_count(10)

  table.sort(settings.plugin_sections)

  for _, section in ipairs(settings.plugin_sections) do
    local plugins = settings.plugins[section]

    for plugin_name, options in pairs(plugins) do
      ---@type widget|widget.foldingbook.pane|nil
      local pane = self.plugin_sections:get_pane(section)
      if not pane then
        pane = self.plugin_sections:add_pane(section, section)
      else
        pane = pane.container
      end

      for _, opt in ipairs(options) do
        ---@type settings.option
        local option = opt
        add_control(pane, option, plugin_name)
      end
    end
  end
end

---@type widget.keybinddialog
local keymap_dialog = KeybindingDialog()

function keymap_dialog:on_save(bindings)
  local row_value = apply_keybinding(self.command, bindings)
  if row_value then
    self.listbox:set_row(self.row_id, row_value)
  end
end

function keymap_dialog:on_reset()
  local default_bindings = settings.default_keybindings[self.command]
  local row_value = apply_keybinding(self.command, default_bindings, true)
  if row_value then
    self.listbox:set_row(self.row_id, row_value)
  end
  if
    settings.config.custom_keybindings
    and
    settings.config.custom_keybindings[self.command]
  then
    settings.config.custom_keybindings[self.command] = nil
    save_settings()
  end
end

---Generate the list of all available commands and allow editing their keymaps.
function Settings:load_keymap_settings()
  self.keybinds.scrollable = false

  local ordered = {}
  for name, _ in pairs(command.map) do
    table.insert(ordered, name)
  end
  table.sort(ordered)

  ---@type widget.textbox
  local textbox = TextBox(self.keybinds, "", "filter bindings...", { clearable = true })

  ---@type widget.listbox
  local listbox = ListBox(self.keybinds)

  listbox.border.width = 0

  listbox:add_column("Command")
  listbox:add_column("Bindings")

  for _, name in ipairs(ordered) do
    local keys = { keymap.get_binding(name) }
    local binding = ""
    if #keys == 1 then
      binding = keys[1]
    elseif #keys > 1 then
      binding = keys[1]
      for idx, key in ipairs(keys) do
        if idx ~= 1 then
          binding = binding .. "\n" .. key
        end
      end
    elseif #keys < 1 then
      binding = "none"
    end
    listbox:add_row({
      {type = "color", container = style, name = "text"}, name,
      ListBox.COLEND,
      {type = "color", container = style, name = "dim"}, binding
    }, name)
  end

  function textbox:on_change(value)
    listbox:filter(value)
  end

  function listbox:on_mouse_pressed(button, x, y, clicks)
    listbox.super.on_mouse_pressed(self, button, x, y, clicks)
    local idx = listbox:get_selected()
    local data = listbox:get_row_data(idx)
    if clicks == 2 and not keymap_dialog:is_visible() then
      local bindings = { keymap.get_binding(data) }
      keymap_dialog:set_bindings(bindings)
      keymap_dialog.row_id = idx
      keymap_dialog.command = data
      keymap_dialog.listbox = self
      keymap_dialog:show()
    end
  end

  ---@param self widget
  function self.keybinds:update_positions()
    textbox:set_position(style.padding.x / 2, style.padding.y)
    textbox:set_size(math.max(0, self.size.x - style.padding.x))
    listbox:set_position(0, textbox:get_bottom())
    listbox:set_size(
      self:get_width() - self.border.width * 2,
      math.max(0, self.size.y - textbox:get_bottom())
    )
  end
end

---Layout settings controls inside a widget.
---@param childs widget[]
---@param width number
local function layout_settings_childs(childs, width)
  local prev_child = nil
  for pos=#childs, 1, -1 do
    local child = childs[pos]
    if child:is(ResetButton) then
      if child.visible then
        local heading = child.heading
        local x = heading:get_right() + style.padding.x / 2
        local y = heading.position.ry
        if x + child:get_width() > width - 10 then
          x, y = 10, heading:get_bottom() + 5 * SCALE
          prev_child = child
        end
        child:set_position(x, y)
      end
    elseif child.visible then
      local x, y = 10, (10 * SCALE)
      if prev_child then
        if
          (prev_child:is(Label) and not prev_child.desc)
          or
          (child:is(Label) and child.desc)
          or
          (prev_child:is(TextBox) and child:is(WidgetList))
        then
          y = prev_child:get_bottom() + (10 * SCALE)
        elseif not child:is(Line) then
          y = prev_child:get_bottom() + (30 * SCALE)
        end
      end
      if child:is(Line) then
        x = 0
      elseif
        child:is(ItemsList) or child:is(WidgetList) or child:is(FilePicker)
        or
        child:is(TextBox) or child:is(Container)
      then
        child:set_size(width - 20)
      end
      if child:is(Label) and child.settings_reset then
        local reset, font = child.settings_reset, child:get_font()
        if reset.layout_width ~= width or child.last_wrap_font ~= font
          or child.last_wrap_font_size ~= font:get_size()
        then
          local reserved = reset.visible and (reset:get_width() + style.padding.x / 2) or 0
          local available = math.max(1, width - 20 - reserved)
          child:set_size(math.min(font:get_width(child.original_label), available))
          child:wrap_text()
          reset.layout_width = width
        end
      end
      child:set_position(x, y)
      prev_child = child
    end
  end
end

---Layout settings controls inside a folding book.
---@param section widget.foldingbook
---@param top? number Top edge below a fixed search field
local function layout_settings_section(section, top)
  local height = top and math.max(0, section.parent.size.y - top) or section:get_real_height()
  section:set_size(
    section.parent.size.x - style.padding.x,
    height
  )
  section:set_position(style.padding.x / 2, top or 0)

  for _, pane in ipairs(section.panes) do
    local width = pane.container:get_width()
    if top then
      -- Keep nested controls outside the section scrollbar's expanded hit area.
      width = width - math.max(
        style.scrollbar_size + style.contracted_scrollbar_margin,
        style.expanded_scrollbar_size + style.expanded_scrollbar_margin
      )
    end
    layout_settings_childs(pane.container.childs, width)
  end
end

---@class settings.configview : widget
---@field private sections widget.foldingbook?
---@field private config_spec settings.config_spec
local ConfigView = Widget:extend()

---Return whether a table looks like a settings option.
---@param value any
---@return boolean
local function is_option(value)
  return type(value) == "table" and type(value.label) == "string"
end

---Return standalone config sections from a spec.
---@param title string
---@param spec settings.config_spec|settings.option[]
---@return table[]
local function config_spec_sections(title, spec)
  if type(spec.sections) ~= "table" then
    return {
      {
        name = spec.name or title,
        options = spec
      }
    }
  end

  local result = {}
  if #spec.sections > 0 then
    for index, section in ipairs(spec.sections) do
      if type(section) == "table" then
        table.insert(result, {
          name = section.name or section.label or tostring(index),
          options = section.options or section
        })
      end
    end
  else
    local names = {}
    for name in pairs(spec.sections) do table.insert(names, name) end
    table.sort(names)
    for _, name in ipairs(names) do
      table.insert(result, {
        name = tostring(name),
        options = spec.sections[name]
      })
    end
  end
  return result
end

---Create a generated settings view from a config spec.
---@param title string
---@param spec settings.config_spec|settings.option[]
---@param context? string|table Plugin name or standalone render context inherited from the opener.
function ConfigView:new(title, spec, context)
  ConfigView.super.new(self, nil, false)
  self.name = title
  self.defer_draw = false
  self.border.width = 0
  self.draggable = false
  self.scrollable = true
  self.config_spec = spec

  context = type(context) == "table" and common.merge({}, context) or context
  if type(spec.path_prefix) == "string" and spec.path_prefix ~= "" then
    context = { path_prefix = resolve_path_prefix(spec.path_prefix, context) }
  end

  if type(spec.sections) == "table" then
    self.sections = FoldingBook(self)
    self.sections.border.width = 0
    self.sections.scrollable = false
    for _, section in ipairs(config_spec_sections(title, spec)) do
      local pane = self.sections:add_pane(section.name, section.name)
      for _, option in ipairs(section.options or {}) do
        if is_option(option) then
          add_control(pane, option, context)
        end
      end
    end
  else
    for _, option in ipairs(spec) do
      if is_option(option) then
        add_control(self, option, context)
      end
    end
  end
end

function ConfigView:draw_background()
  ConfigView.super.draw_background(self, style.background)
end

---Reposition generated settings controls.
function ConfigView:update()
  if not ConfigView.super.update(self) then return end
  if self.sections then
    layout_settings_section(self.sections)
  else
    layout_settings_childs(self.childs, self:get_width())
  end
  if self.size.x == 0 and self.size.y == 0 then
    self:schedule_update(true)
  end
end

---Reposition and resize core and plugin widgets.
function Settings:update()
  if not Settings.super.update(self) then return end

  self.notebook:set_size(self.size.x, self.size.y)

  for _, section in ipairs({self.core_sections, self.plugin_sections}) do
    if section.parent:is_visible() then
      local margin = style.padding.x / 2
      local width = section.parent.size.x - margin * 2
      if section == self.plugin_sections and self.plugin_button then
        width = width - self.plugin_button:get_width() - style.padding.x
        self.plugin_button:set_position(
          section.parent.size.x - self.plugin_button:get_width() - margin,
          style.padding.y + (section.search:get_height() - self.plugin_button:get_height()) / 2
        )
      end
      section.search:set_position(margin, style.padding.y)
      section.search:set_size(math.max(0, width))
      local top = section.search:get_bottom() + style.padding.y
      section.empty:set_position(style.padding.x, top + style.padding.y)
      section.empty:set_size(math.max(0, section.parent.size.x - style.padding.x * 2))
      layout_settings_section(section, top)
    end
  end

  if self.colors:is_visible() then
    self.colors:update_positions()
  end

  if self.keybinds:is_visible() then
    self.keybinds:update_positions()
  end

  if self.size.x == 0 and self.size.y == 0 then
    -- we need this since sometimes when adding a view to a node
    -- it isn't initially given any size, needed for calculations
    self:schedule_update(true)
  end
end

---Hide the widget when the node is removed.
function Settings:try_close(do_close)
  self.super.try_close(self, do_close)
  self:hide()
end

---Open a settings view in the active node.
---@param view widget
local function open_settings_view(view)
  view:show()
  local node = core.root_view:get_active_node_default()
  node:add_view(view)
  node:set_active_view(view)
end

---Show a generated configuration view.
---@param title string
---@param spec settings.config_spec|settings.option[]
---@param context? string|table Plugin name or standalone render context inherited from the opener.
---@return settings.configview|nil view
function settings.show_config(title, spec, context)
  if type(title) ~= "string" or title == "" then
    core.error("Settings: show_config requires a title")
    return nil
  end
  if type(spec) ~= "table" then
    core.error("Settings: show_config requires a config spec table")
    return nil
  end
  local view = ConfigView(title, spec, context)
  open_settings_view(view)
  return view
end

--------------------------------------------------------------------------------
-- overwrite core run to inject previously saved settings
--------------------------------------------------------------------------------
local core_run = core.run
function core.run()
  store_default_keybindings()

  -- load plugins disabled by default and enabled by user
  if settings.config.enabled_plugins then
    for name, _ in pairs(settings.config.enabled_plugins) do
      if config.plugins[name] == nil then
        require("plugins." .. name)
      end
    end
  end

  -- append all settings defined in the plugins spec
  scan_plugins_spec()

  -- merge custom settings into config
  merge_settings()

  ---@type settings.ui
  settings.ui = Settings()

  -- apply user chosen color theme
  if settings.config.theme and settings.config.theme ~= "default" then
    core.try(function()
      core.reload_module("colors." .. settings.config.theme)
    end)
  end

  -- re-apply user settings
  -- TODO: come up with a better solution for this that doesn't requires
  -- reloading these user modules, got an idea time ago and forgot it :(
  if settings.config.reload_user_modules then
    local modules = {
      USERDIR .. PATHSEP .. "init.lua"
    }
    if core.is_project_trusted(core.root_project()) then
      table.insert(
        modules,
        core.root_project().path .. PATHSEP .. ".pragtical_project.lua"
      )
    end
    for _, module in ipairs(modules) do
      core.reload_absolute_module(module)
    end
  end

  core_run()
end

--------------------------------------------------------------------------------
-- Disable plugins at startup, only works if this file is the first
-- required on user module, or priority tag is obeyed by pragtical.
--------------------------------------------------------------------------------
-- load custom user settings that include list of disabled plugins
load_settings()

-- only disable non already loaded plugins
if settings.config.disabled_plugins then
  for name, _ in pairs(settings.config.disabled_plugins) do
    if not package.loaded[name] then
      config.plugins[name] = false
    end
  end
end

-- properly apply skip_plugins_version before other plugins are loaded
if settings.config.skip_plugins_version then
  config.skip_plugins_version = true
else
  config.skip_plugins_version = false
end

--------------------------------------------------------------------------------
-- Add command and keymap to load settings view
--------------------------------------------------------------------------------
command.add(nil, {
  ["ui:settings"] = function()
    settings.ui:show()
    local node = core.root_view:get_active_node_default()
    local found = false
    for _, view in ipairs(node.views) do
      if view == settings.ui then
        found = true
        node:set_active_view(view)
        break
      end
    end
    if not found then
      node:add_view(settings.ui)
    end
  end,
})

keymap.add {
  ["ctrl+alt+p"] = "ui:settings"
}

core.menu_view:register({ "tools" }, {
  { id = "settings", text = "Settings…", command = "ui:settings" }
}, "settings")

--------------------------------------------------------------------------------
-- Overwrite toolbar preferences command to open the settings gui
--------------------------------------------------------------------------------
if config.plugins.toolbarview ~= false then
  local ToolbarView = require "plugins.toolbarview"
  local toolbarview_on_mouse_moved = ToolbarView.on_mouse_moved
  function ToolbarView:on_mouse_moved(px, py, ...)
    toolbarview_on_mouse_moved(self, px, py, ...)
    if
      self.hovered_item
      and
      self.hovered_item.command == "core:open-user-module"
    then
      self.hovered_item.command = "ui:settings"
    end
  end
end

--------------------------------------------------------------------------------
-- Overwrite View:new to allow setting force scrollbar status globally
--------------------------------------------------------------------------------
local view_new = View.new
function View:new()
  view_new(self)
  local mode = config.force_scrollbar_status_mode or "global"
  local globally = mode == "global"
  if globally then
    self.v_scrollbar:set_forced_status(config.force_scrollbar_status)
    self.h_scrollbar:set_forced_status(config.force_scrollbar_status)
  end
end

local widget_new = Widget.new
function Widget:new(parent, floating)
  widget_new(self, parent, floating)
  if not parent then
    self.init_scrollbars_status = true
  end
end

local widget_draw = Widget.draw
function Widget:draw()
  if self.init_scrollbars_status then
    local mode = config.force_scrollbar_status_mode or "global"
    local globally = mode == "global"
    if globally then
      --This is delayed to allow widgets to also apply it to child views/widgets
      self.v_scrollbar:set_forced_status(config.force_scrollbar_status)
      self.h_scrollbar:set_forced_status(config.force_scrollbar_status)
    end
    self.init_scrollbars_status = nil
  end
  return widget_draw(self)
end

return settings;

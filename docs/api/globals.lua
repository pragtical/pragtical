---@meta

---The command line arguments given to pragtical.
---@type table<integer, string>
ARGS = {}

---The current platform tuple used for native modules loading,
---for example: "x86_64-linux", "x86_64-darwin", "x86_64-windows", etc...
---@type string
ARCH = "Architecture-OperatingSystem"

---The current operating system.
---@type string | "Windows" | "Mac OS X" | "Linux" | "iOS" | "Android"
PLATFORM = "Operating System"

---The current text or ui scale.
---@type number
SCALE = 1.0

---Full path of pragtical executable.
---@type string
EXEFILE = "/path/to/pragtical"

---Path to the users home directory.
---@type string
HOME = "/path/to/user/dir"

---This is set to true if pragtical was compiled with luajit.
---@type boolean
LUAJIT = false

---Directory that holds the editor lua sources and other data files.
---@type string
DATADIR = "/usr/share/pragtical"

---Directory that holds the user configuration files, plugins, colors, etc...
---@type string
USERDIR = "/home/user/.config/pragtical"

---Directory where the editor executable resides.
---@type string
EXEDIR = "/usr/bin"

---Default system scale.
---@type number
DEFAULT_SCALE = 1.0

---Current platform path separator, usually `/` or `\` on windows.
---@type string
PATHSEP = "/"

---Same as application major version.
---@type integer
MOD_VERSION_MAJOR = 3

---Same as application minor version.
---@type integer
MOD_VERSION_MINOR = 0

---Same as application patch version.
---@type integer
MOD_VERSION_PATCH = 0

---Same as application version.
---@type string
MOD_VERSION_STRING = "3.0.0"

---The application version.
---@type string
VERSION = "3.0.0"

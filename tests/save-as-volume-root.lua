-- Exercise the real command handler with small UI stubs, without a renderer.
local file = assert(io.open(arg[1] or 'data/core/commands/doc.lua'))
local source = file:read('*a'); file:close()
local body = assert(source:match('%["doc:save%-as"%] = (function%(dv%).-)\n  end,')) .. '\nend'
local cases = {
  { 'AROS', 'SYS:previous.txt', 'SYS:' },
  { 'AROS', 'Work:docs/previous.txt', 'Work:docs/' },
  { 'Linux', '/home/editor/previous.txt', '/home/editor/' },
  { 'Windows', 'C:\\docs\\previous.txt', 'C:\\docs\\' },
  { 'AROS', 'previous.txt', '' },
}
for _, case in ipairs(cases) do
  local platform, previous, expected = table.unpack(case)
  local entered
  local core = {
    last_active_view = {doc = {filename = previous, abs_filename = previous}},
    normalize_to_project_dir = function(path) return path end,
    root_project = function() return {path = 'Unrelated:project/'} end,
    command_view = { enter = function(_, name, options) entered = options.text end }
  }
  local env = {core=core, common={}, PLATFORM=platform, PATHSEP=platform=='Windows' and '\\' or '/'}
  local handler = assert(load('return '..body, 'actual-save-as', 't', env))()
  handler({doc={}})
  assert(entered==expected, previous..': expected '..expected..', got '..tostring(entered))
end
print('Save As directory defaults: 5 cases passed')

local base=arg[1] or 'data/core/'
local f=assert(io.open(base..'common.lua'));local src=f:read('*a');f:close()
local body=assert(src:match('function common.dirname%(path%)(.-)\nend'))
local common={dirname=assert(load('return function(path)'..body..'\nend','actual-dirname','t',{PLATFORM='AROS',PATHSEP='/'}))()}
f=assert(io.open(base..'init.lua'));src=f:read('*a');f:close()
local expr=assert(src:match('table.insert%(files, file_abs%)%s+project_dir = ([^\n]+)'))
local select_project=assert(load('return function(file_abs, project_dir) return '..expr..' end','actual-project-selection','t',{common=common}))()
for _,c in ipairs({{'SYS:file.txt','SYS:'},{'Work:docs/file.txt','Work:docs'},{'relative.txt','Work:project'}}) do
 assert(select_project(c[1],'Work:project')==c[2],c[1]..': incorrect project directory')
end
print('File argument project directories: 3 cases passed')

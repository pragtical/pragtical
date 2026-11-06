local f=assert(io.open(arg[1] or 'data/core/common.lua'))
local source=f:read('*a');f:close()
local body=assert(source:match('function common.dirname%(path%)(.-)\nend'))
local cases={
 {'AROS','SYS:note.txt','SYS:'}, {'AROS','SYS:','SYS:'},
 {'AROS','Work:docs/note.txt','Work:docs'},
 {'Linux','/tmp/note.txt','/tmp'}, {'Linux','/note.txt','/'},
 {'Windows','C:\\docs\\note.txt','C:\\docs'}, {'Linux','note.txt',nil},
}
for _,c in ipairs(cases) do
 local env={PLATFORM=c[1],PATHSEP=c[1]=='Windows' and '\\' or '/'}
 local fn=assert(load('return function(path)'..body..'\nend','actual-dirname','t',env))()
 assert(fn(c[2])==c[3],c[2]..': expected '..tostring(c[3])..', got '..tostring(fn(c[2])))
end
print('Directory roots: 7 cases passed')

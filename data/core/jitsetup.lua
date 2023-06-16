--
-- Borrowed from the LÖVE project.
-- Source: https://github.com/love2d/love/blob/main/src/modules/love/jitsetup.lua
--
-- Flags documented on bottom of http://luajit.org/running.html
--
-- Flags pasted here for convenience:
-- maxtrace    1000  Max. number of traces in the cache
-- maxrecord   4000  Max. number of recorded IR instructions
-- maxirconst  500   Max. number of IR constants of a trace
-- maxside     100   Max. number of side traces of a root trace
-- maxsnap     500   Max. number of snapshots for a trace
-- hotloop     56    Number of iterations to detect a hot loop or hot call
-- hotexit     10    Number of taken exits to start a side trace
-- tryside     4     Number of attempts to compile a side trace
-- instunroll  4     Max. unroll factor for instable loops
-- loopunroll  15    Max. unroll factor for loop ops in side traces
-- callunroll  3     Max. unroll factor for pseudo-recursive calls
-- recunroll   2     Min. unroll factor for true recursion
-- sizemcode   32    Size of each machine code area in KBytes (Windows: 64K)
-- maxmcode    512   Max. total size of all machine code areas in KBytes
--

local jit = LUAJIT and require("jit")

if not jit or not LUAJIT or not jit.status() then
  return
end

jit.opt.start(
  -- Double the defaults.
  "maxtrace=2000", "maxrecord=8000",
  -- Reduced to jit earlier
  "hotloop=10", "hotexit=2",
  -- Somewhat arbitrary value. Needs to be higher than the combined sizes below,
  -- and higher than the default (512) because that's already too low.
  "maxmcode=16384"
)

if jit.arch == "arm64" then
  -- https://github.com/LuaJIT/LuaJIT/issues/285
  -- LuaJIT 2.1 on arm64 currently (as of commit b4b2dce) can only use memory
  -- for JIT compilation within a certain short range. Other libraries such as
  -- SDL can take all the usable space in that range and cause attempts at JIT
  -- compilation to both fail and take a long time.
  -- This is a very hacky attempt at a workaround. LuaJIT allocates executable
  -- code in pools. We'll try "reserving" pools before any external code is
  -- executed, by causing JIT compilation via a small loop. We can't easily
  -- tell if JIT compilation succeeded, so we do several successively smaller
  -- pool allocations in case previous ones fail.
  -- This is a really hacky hack and by no means foolproof - there are a lot of
  -- potential situations (especially when threads are used) where previously
  -- executed external code will still take up space that LuaJIT needed for itself.

  jit.opt.start("sizemcode=2048")
  for i=1, 100 do end

  jit.opt.start("sizemcode=1024")
  for i=1, 100 do end

  jit.opt.start("sizemcode=512")
  for i=1, 100 do end

  jit.opt.start("sizemcode=256")
  for i=1, 100 do end

  jit.opt.start("sizemcode=128")
  for i=1, 100 do end
else
  -- Somewhat arbitrary value (>= the default).
  jit.opt.start("sizemcode=128")
end

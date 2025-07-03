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

-- ffi overrides for faster rendering calls
local ffi = require("ffi")

ffi.cdef [[
  void* ren_get_target_window_ffi(void);
  void rencache_set_clip_rect_ffi(void *window_renderer, float x, float y, float w, float h);
  void rencache_draw_rect_ffi(void *window_renderer, float x, float y, float w, float h, unsigned char r, unsigned char g, unsigned char b, unsigned char a);
  double rencache_draw_text_ffi(void *window_renderer, void **font, const char *text, size_t len, double x, double y, unsigned char r, unsigned char g, unsigned char b, unsigned char a, double tab_offset);
  void rencache_begin_frame_ffi(void *window_renderer);
  void rencache_end_frame_ffi();
  double system_get_time_ffi();
  bool system_wait_event_ffi(double n);
  void SDL_Delay(unsigned int);
]]

renderer.draw_rect_lua = renderer.draw_rect
function renderer.draw_rect(x, y, w, h, color, tab)
  ffi.C.rencache_draw_rect_ffi(
    ffi.C.ren_get_target_window_ffi(),
    x, y, w, h,
    color[1], color[2], color[3], color[4]
  )
end

renderer.draw_text_lua = renderer.draw_text
local fonts_pointer_cache = setmetatable({}, { __mode = "k" })
function renderer.draw_text(font, text, x, y, color, tab)
  if not fonts_pointer_cache[font] then
    local fonts_list = font
    if type(font) ~= "table" then
      fonts_list = {font}
    end
    local fonts = ffi.new("void*[10]")
    for i, f in pairs(fonts_list) do
      fonts[i-1] = ffi.cast("void**", f)[0]
    end
    fonts[#fonts_list] = nil
    fonts_pointer_cache[font] = fonts
  end
  local text = type(text) == "string" and text or tostring(text)
  if not color then color = {255, 255, 255, 255} end
  return ffi.C.rencache_draw_text_ffi(
    ffi.C.ren_get_target_window_ffi(),
    fonts_pointer_cache[font], text, #text, x, y,
    color[1], color[2], color[3], color[4] or 255,
    tab and tab.tab_offset or -1
  );
end

renderer.begin_frame_lua = renderer.begin_frame
local windows_pointer_cache = setmetatable({}, { __mode = "k" })
function renderer.begin_frame(window)
  if not windows_pointer_cache[window] then
    windows_pointer_cache[window] = ffi.cast("void**", window)[0]
  end
  ffi.C.rencache_begin_frame_ffi(windows_pointer_cache[window])
end

renderer.end_frame_lua = renderer.end_frame
function renderer.end_frame()
  ffi.C.rencache_end_frame_ffi()
end

renderer.set_clip_rect_lua = renderer.set_clip_rect
function renderer.set_clip_rect(x, y, w, h)
  ffi.C.rencache_set_clip_rect_ffi(ffi.C.ren_get_target_window_ffi(), x, y, w, h)
end

system.sleep_lua = system.sleep
function system.sleep(n)
  ffi.C.SDL_Delay(n * 1000);
end

system.get_time_lua = system.get_time
system.get_time = ffi.C.system_get_time_ffi

system.get_wait_event_lua = system.wait_event
function system.wait_event(timeout)
  return ffi.C.system_wait_event_ffi(timeout or 0)
end

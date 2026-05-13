#include "renbackend_sdlgpu.h"
#include "renwindow.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#include "shaders/gpu_canvas.frag.dxbc.h"
#include "shaders/gpu_canvas.frag.msl.h"
#include "shaders/gpu_canvas.frag.spv.h"
#include "shaders/gpu_canvas.vert.dxbc.h"
#include "shaders/gpu_canvas.vert.msl.h"
#include "shaders/gpu_canvas.vert.spv.h"
#include "shaders/gpu_poly.frag.dxbc.h"
#include "shaders/gpu_poly.frag.msl.h"
#include "shaders/gpu_poly.frag.spv.h"
#include "shaders/gpu_poly.vert.dxbc.h"
#include "shaders/gpu_poly.vert.msl.h"
#include "shaders/gpu_poly.vert.spv.h"
#include "shaders/gpu_text.frag.dxbc.h"
#include "shaders/gpu_text.frag.msl.h"
#include "shaders/gpu_text.frag.spv.h"
#include "shaders/gpu_text.vert.dxbc.h"
#include "shaders/gpu_text.vert.msl.h"
#include "shaders/gpu_text.vert.spv.h"

#define GPU_SUPPORTED_SHADER_FORMATS (SDL_GPU_SHADERFORMAT_SPIRV | SDL_GPU_SHADERFORMAT_DXBC | SDL_GPU_SHADERFORMAT_DXIL | SDL_GPU_SHADERFORMAT_MSL)
#define GPU_DIRTY_UPLOAD_FULL_THRESHOLD 64
#define GPU_TEXTURE_ROW_ALIGNMENT 256
#define GPU_TEXTURE_OFFSET_ALIGNMENT 512
#define GPU_NATIVE_TEXT_ENABLED false
#define GPU_NATIVE_CANVAS_ENABLED false
#define GPU_NATIVE_RECT_ENABLED false
#define GPU_NATIVE_RECT_BATCH_SIZE 1024

typedef struct {
  SDL_Surface *surface;
  SDL_GPUTexture *texture;
  SDL_GPUTransferBuffer *transfer;
  SDL_GPUBuffer *poly_vertex_buffer;
  SDL_GPUTransferBuffer *poly_transfer;
  Uint32 transfer_size;
  Uint32 poly_vertex_buffer_size;
  Uint32 poly_transfer_size;
  SDL_PixelFormat texture_pixel_format;
  int texture_w, texture_h;
  bool needs_full_upload;
  RenRect dirty_rects[GPU_DIRTY_UPLOAD_FULL_THRESHOLD];
  int dirty_count;
} GpuFrameBridge;

typedef struct {
  SDL_Rect rect;
  RenColor color;
} GpuNativeRect;

typedef struct {
  RenAtlas *atlas;
  GlyphMetric metric;
  RenColor color;
  int dst_x, dst_y;
  int src_x, src_y;
  int width, height;
  unsigned char format;
} GpuQueuedGlyph;

typedef struct {
  SDL_GPUDevice *device;
  SDL_GPUCommandBuffer *command_buffer;
  GpuFrameBridge frame;
  SDL_GPUTexture *pixels_texture;
  SDL_GPUTransferBuffer *pixels_transfer;
  Uint32 pixels_transfer_size;
  int pixels_texture_w;
  int pixels_texture_h;
  GpuNativeRect pending_native_rects[GPU_NATIVE_RECT_BATCH_SIZE];
  GpuQueuedGlyph *pending_text_glyphs;
  SDL_GPUTransferBuffer *validation_transfer;
  Uint32 validation_transfer_size;
  SDL_Rect validation_text_rect;
  SDL_Rect validation_probe_rect;
  int pending_native_rect_count;
  int pending_text_glyph_count;
  int pending_text_glyph_capacity;
  Uint64 stats_frames;
  Uint64 stats_native_rects;
  Uint64 stats_native_rect_batches;
  Uint64 stats_native_canvases;
  Uint64 stats_native_canvas_texture_draws;
  Uint64 stats_native_canvas_missing_state;
  Uint64 stats_native_canvas_clip_rejects;
  Uint64 stats_native_pixels;
  Uint64 stats_native_polys;
  bool native_region;
  bool frame_synced_during_replay;
  bool native_text_used;
  bool validation_text_pending;
  bool validation_probe_pending;
  bool validation_reported;
  bool sampled_canvas_this_frame;
} GpuWindowData;

typedef struct {
  SDL_Rect rect;
  Uint32 offset;
  Uint32 size;
  Uint32 row_stride;
} GpuUploadRegion;

typedef struct {
  SDL_GPUDevice *device;
  GpuFrameBridge frame;
  bool surface_valid;
  bool texture_valid;
} GpuCanvasData;

typedef struct {
  unsigned char format;
  unsigned short atlas_idx;
  unsigned short surface_idx;
  unsigned int x1;
  unsigned int y0;
  unsigned int y1;
  SDL_GPUTexture *texture;
  SDL_GPUTransferBuffer *transfer;
  Uint32 transfer_size;
  int texture_w;
  int texture_h;
} GpuAtlasTexture;

typedef struct {
  SDL_GPUDevice *device;
  RenAtlas surface_atlas;
  GpuAtlasTexture *textures;
  size_t texture_count;
  size_t texture_capacity;
} GpuAtlasData;

static SDL_GPUDevice *gpu_device = NULL;
static int gpu_device_ref_count = 0;
static SDL_GPUGraphicsPipeline *gpu_canvas_blend_pipeline = NULL;
static SDL_GPUSampler *gpu_canvas_sampler = NULL;
static bool gpu_canvas_pipeline_failed = false;
static SDL_GPUGraphicsPipeline *gpu_poly_pipeline = NULL;
static bool gpu_poly_pipeline_failed = false;
static SDL_GPUGraphicsPipeline *gpu_text_pipeline = NULL;
static SDL_GPUGraphicsPipeline *gpu_text_replace_pipeline = NULL;
static SDL_GPUSampler *gpu_text_sampler = NULL;
static bool gpu_text_pipeline_failed = false;
static SDL_GPUTexture *gpu_solid_white_texture = NULL;
static SDL_GPUTransferBuffer *gpu_solid_white_transfer = NULL;
static bool gpu_solid_white_failed = false;
static bool gpu_atlas_validation_reported = false;
static SDL_GPUDevice *gpu_active_frame_device = NULL;
static SDL_GPUCommandBuffer *gpu_active_frame_command_buffer = NULL;
static GpuWindowData *gpu_active_frame_window_data = NULL;

static RenRect gpu_clip_surface_rect(SDL_Surface *surface, RenRect rect);
static SDL_GPUDevice *gpu_retain_device(void);
static void gpu_release_device(void);
static bool gpu_flush_window_native_rects(GpuWindowData *data, SDL_GPUCommandBuffer *cmd);
static bool gpu_ensure_canvas_pipeline(SDL_GPUDevice *device);
static bool gpu_ensure_poly_pipeline(SDL_GPUDevice *device);
static bool gpu_submit_and_wait(SDL_GPUDevice *device, SDL_GPUCommandBuffer *cmd);
static bool gpu_flush_queued_text(
  GpuWindowData *data,
  SDL_GPUCommandBuffer *cmd,
  UNUSED const RenRect *uploaded_cpu_rects,
  UNUSED int uploaded_cpu_count,
  UNUSED bool uploaded_cpu_full
);
static bool gpu_draw_solid_rect_to_bridge(
  SDL_GPUDevice *device, SDL_GPUCommandBuffer *cmd, GpuFrameBridge *frame,
  SDL_Surface *surface, RenRect rect, RenColor color, bool replace
);
static bool gpu_upload_pixels_to_bridge(
  SDL_GPUDevice *device, SDL_GPUCommandBuffer *cmd, GpuFrameBridge *frame,
  SDL_Surface *surface, RenRect rect, const char *bytes, size_t len
);

static void gpu_flush_pending_text_barrier(GpuWindowData *data) {
  if (data && data->command_buffer && data->pending_text_glyph_count > 0)
    gpu_flush_queued_text(data, data->command_buffer, NULL, 0, false);
}

static bool gpu_env_flag(const char *name, bool fallback) {
  const char *value = SDL_getenv(name);
  if (!value || !*value)
    return fallback;
  return SDL_strcasecmp(value, "0") != 0
      && SDL_strcasecmp(value, "false") != 0
      && SDL_strcasecmp(value, "no") != 0
      && SDL_strcasecmp(value, "off") != 0;
}

static bool gpu_native_text_enabled(void) {
  return GPU_NATIVE_TEXT_ENABLED
      || gpu_env_flag("PRAGTICAL_SDLGPU_NATIVE_TEXT", false)
      || gpu_env_flag("PRAGTICAL_SDLGPU_DIRECT_REPLAY", true)
      || gpu_env_flag("PRAGTICAL_SDLGPU_VALIDATE_TEXT", false);
}

static bool gpu_native_rect_enabled(void) {
  return GPU_NATIVE_RECT_ENABLED
      || gpu_env_flag("PRAGTICAL_SDLGPU_NATIVE_RECTS", false)
      || gpu_env_flag("PRAGTICAL_SDLGPU_DIRECT_REPLAY", true);
}

static bool gpu_native_canvas_enabled(void) {
  return GPU_NATIVE_CANVAS_ENABLED
      || gpu_env_flag("PRAGTICAL_SDLGPU_NATIVE_CANVAS", false)
      || gpu_env_flag("PRAGTICAL_SDLGPU_DIRECT_REPLAY", true);
}

static bool gpu_stats_enabled(void) {
  return gpu_env_flag("PRAGTICAL_SDLGPU_STATS", false);
}

static bool gpu_direct_replay_enabled(void) {
  return gpu_env_flag("PRAGTICAL_SDLGPU_DIRECT_REPLAY", true);
}

static bool gpu_native_text_supported(SDL_GPUDevice *device) {
  SDL_GPUShaderFormat formats = device ? SDL_GetGPUShaderFormats(device) : 0;
  return gpu_native_text_enabled()
      && device
      && (formats & (SDL_GPU_SHADERFORMAT_SPIRV | SDL_GPU_SHADERFORMAT_DXBC | SDL_GPU_SHADERFORMAT_MSL));
}

static bool gpu_validate_text_enabled(void) {
  return gpu_env_flag("PRAGTICAL_SDLGPU_VALIDATE_TEXT", false);
}

typedef struct {
  float dst[4];
  float uv[4];
  float target[4];
} GpuTextVertexUniforms;

typedef struct {
  float color[4];
  Uint32 format;
  Uint32 padding[3];
} GpuTextFragmentUniforms;

typedef struct {
  float target[4];
} GpuPolyVertexUniforms;

typedef struct {
  float color[4];
} GpuPolyFragmentUniforms;

typedef struct {
  float x, y;
} GpuPolyVertex;

typedef struct {
  GpuWindowData *window_data;
  SDL_GPUDevice *device;
  SDL_GPUCommandBuffer *command_buffer;
  GpuFrameBridge *target_frame;
  GpuQueuedGlyph *glyphs;
  RenRect dirty_rect;
  int glyph_count;
  int glyph_capacity;
  bool attempted_native;
  bool have_dirty_rect;
  bool collect_overlay;
} GpuTextDrawContext;

typedef struct {
  bool native_text;
} GpuTextNativeCheck;

static RenRect gpu_merge_rects(RenRect a, RenRect b) {
  int x1 = SDL_min(a.x, b.x);
  int y1 = SDL_min(a.y, b.y);
  int x2 = SDL_max(a.x + a.width, b.x + b.width);
  int y2 = SDL_max(a.y + a.height, b.y + b.height);
  return (RenRect) { x1, y1, x2 - x1, y2 - y1 };
}

static void gpu_abort(const char *message) {
  fprintf(stderr, "%s: %s\n", message, SDL_GetError());
  exit(1);
}

static GpuWindowData *gpu_window_data(RenWindow *ren) {
  if (!ren->backend_data) {
    ren->backend_data = SDL_calloc(1, sizeof(GpuWindowData));
    if (!ren->backend_data) {
      fprintf(stderr, "Error allocating SDL GPU window data\n");
      exit(1);
    }
  }
  return ren->backend_data;
}

static void gpu_destroy_bridge_surface(GpuFrameBridge *frame) {
  if (frame->surface) {
    SDL_DestroySurface(frame->surface);
    frame->surface = NULL;
  }
}

static void gpu_destroy_surface(GpuWindowData *data) {
  gpu_destroy_bridge_surface(&data->frame);
}

static void gpu_force_surface_alpha_opaque(SDL_Surface *surface) {
  if (!surface || !SDL_ISPIXELFORMAT_ALPHA(surface->format))
    return;

  const SDL_PixelFormatDetails *details = SDL_GetPixelFormatDetails(surface->format);
  if (!details || !details->Amask || SDL_BYTESPERPIXEL(surface->format) != 4)
    return;

  if (!SDL_LockSurface(surface))
    gpu_abort("SDL_LockSurface failed");

  Uint32 alpha = ((Uint32) 0xff << details->Ashift) & details->Amask;
  for (int y = 0; y < surface->h; y++) {
    Uint32 *pixel = (Uint32 *) ((Uint8 *) surface->pixels + y * surface->pitch);
    for (int x = 0; x < surface->w; x++)
      pixel[x] = (pixel[x] & ~details->Amask) | alpha;
  }
  SDL_UnlockSurface(surface);
}

static void gpu_print_stats(GpuWindowData *data) {
  if (!data || !gpu_stats_enabled() || data->stats_frames == 0)
    return;

  fprintf(
    stderr,
    "sdlgpu stats: frames=%llu native_rects=%llu native_rect_batches=%llu native_canvases=%llu native_canvas_texture_draws=%llu native_canvas_missing_state=%llu native_canvas_clip_rejects=%llu native_pixels=%llu native_polys=%llu\n",
    (unsigned long long) data->stats_frames,
    (unsigned long long) data->stats_native_rects,
    (unsigned long long) data->stats_native_rect_batches,
    (unsigned long long) data->stats_native_canvases,
    (unsigned long long) data->stats_native_canvas_texture_draws,
    (unsigned long long) data->stats_native_canvas_missing_state,
    (unsigned long long) data->stats_native_canvas_clip_rejects,
    (unsigned long long) data->stats_native_pixels,
    (unsigned long long) data->stats_native_polys
  );
}

static void gpu_destroy_bridge_resources(SDL_GPUDevice *device, GpuFrameBridge *frame) {
  if (frame->texture) {
    if (device)
      SDL_ReleaseGPUTexture(device, frame->texture);
    frame->texture = NULL;
  }
  if (frame->transfer) {
    if (device)
      SDL_ReleaseGPUTransferBuffer(device, frame->transfer);
    frame->transfer = NULL;
  }
  if (frame->poly_vertex_buffer) {
    if (device)
      SDL_ReleaseGPUBuffer(device, frame->poly_vertex_buffer);
    frame->poly_vertex_buffer = NULL;
  }
  if (frame->poly_transfer) {
    if (device)
      SDL_ReleaseGPUTransferBuffer(device, frame->poly_transfer);
    frame->poly_transfer = NULL;
  }
  frame->transfer_size = 0;
  frame->poly_vertex_buffer_size = 0;
  frame->poly_transfer_size = 0;
  frame->texture_w = 0;
  frame->texture_h = 0;
  frame->needs_full_upload = true;
  frame->dirty_count = 0;
}

static void gpu_mark_bridge_full_upload(GpuFrameBridge *frame) {
  frame->needs_full_upload = true;
  frame->dirty_count = 0;
}

static void gpu_mark_bridge_dirty_rects(GpuFrameBridge *frame, RenRect *rects, int count) {
  if (count <= 0 || frame->needs_full_upload)
    return;

  SDL_Surface *surface = frame->surface;
  if (!surface) {
    gpu_mark_bridge_full_upload(frame);
    return;
  }

  if (frame->dirty_count + count > GPU_DIRTY_UPLOAD_FULL_THRESHOLD) {
    gpu_mark_bridge_full_upload(frame);
    return;
  }

  for (int i = 0; i < count; i++) {
    RenRect rect = gpu_clip_surface_rect(surface, rects[i]);
    if (rect.width == 0 || rect.height == 0)
      continue;

    frame->dirty_rects[frame->dirty_count++] = rect;
  }
}

static bool gpu_bridge_has_pending_upload(GpuFrameBridge *frame) {
  return frame->needs_full_upload || !frame->texture || frame->dirty_count > 0;
}

static void gpu_mark_canvas_surface_modified(GpuCanvasData *data, RenRect *rects, int count) {
  if (!data)
    return;

  data->surface_valid = true;
  data->texture_valid = false;
  if (rects && count > 0)
    gpu_mark_bridge_dirty_rects(&data->frame, rects, count);
  else
    gpu_mark_bridge_full_upload(&data->frame);
}

static void gpu_query_surface_scale(RenWindow *ren, float *scale_x, float *scale_y) {
  int w_pixels, h_pixels;
  int w_points, h_points;
  SDL_GetWindowSizeInPixels(ren->window, &w_pixels, &h_pixels);
  SDL_GetWindowSize(ren->window, &w_points, &h_points);
  if (w_points < 1) w_points = 1;
  if (h_points < 1) h_points = 1;

  float scaleX = (float) w_pixels / (float) w_points;
  float scaleY = (float) h_pixels / (float) h_points;
  if (scale_x)
    *scale_x = round(scaleX * 100) / 100;
  if (scale_y)
    *scale_y = round(scaleY * 100) / 100;
}

static void gpu_create_surface(RenWindow *ren) {
  GpuWindowData *data = gpu_window_data(ren);
  gpu_destroy_surface(data);

  int w, h;
  SDL_GetWindowSizeInPixels(ren->window, &w, &h);
  if (w < 1) w = 1;
  if (h < 1) h = 1;

  data->frame.surface = SDL_CreateSurface(w, h, SDL_PIXELFORMAT_BGRA32);
  if (!data->frame.surface)
    gpu_abort("Error creating SDL GPU compatibility surface");

  ren->cache.rensurface.surface = data->frame.surface;
  gpu_query_surface_scale(ren, &ren->cache.rensurface.scale_x, &ren->cache.rensurface.scale_y);
  ren->scale_x = ren->scale_y = 1;
  rencache_invalidate(&ren->cache);
  gpu_mark_bridge_full_upload(&data->frame);
}

static void gpu_ensure_bridge_texture(SDL_GPUDevice *device, GpuFrameBridge *frame, int w, int h) {
  SDL_PixelFormat pixel_format = frame->surface ? frame->surface->format : SDL_PIXELFORMAT_BGRA32;
  SDL_GPUTextureFormat texture_format = SDL_GetGPUTextureFormatFromPixelFormat(pixel_format);
  if (texture_format == SDL_GPU_TEXTUREFORMAT_INVALID) {
    pixel_format = SDL_PIXELFORMAT_RGBA32;
    texture_format = SDL_GetGPUTextureFormatFromPixelFormat(pixel_format);
  }

  if (frame->texture &&
      frame->texture_w == w &&
      frame->texture_h == h &&
      frame->texture_pixel_format == pixel_format)
    return;

  if (frame->texture)
    SDL_ReleaseGPUTexture(device, frame->texture);

  SDL_GPUTextureCreateInfo createinfo;
  SDL_zero(createinfo);
  createinfo.format = texture_format;
  createinfo.usage = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | SDL_GPU_TEXTUREUSAGE_SAMPLER;
  createinfo.width = w;
  createinfo.height = h;
  createinfo.layer_count_or_depth = 1;
  createinfo.num_levels = 1;
  createinfo.sample_count = SDL_GPU_SAMPLECOUNT_1;

  frame->texture = SDL_CreateGPUTexture(device, &createinfo);
  if (!frame->texture)
    gpu_abort("SDL_CreateGPUTexture failed");

  frame->texture_w = w;
  frame->texture_h = h;
  frame->texture_pixel_format = pixel_format;
  gpu_mark_bridge_full_upload(frame);
}

static void gpu_ensure_bridge_transfer_buffer(SDL_GPUDevice *device, GpuFrameBridge *frame, Uint32 size) {
  if (frame->transfer && frame->transfer_size >= size)
    return;

  if (frame->transfer)
    SDL_ReleaseGPUTransferBuffer(device, frame->transfer);

  SDL_GPUTransferBufferCreateInfo createinfo;
  SDL_zero(createinfo);
  createinfo.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
  createinfo.size = size;

  frame->transfer = SDL_CreateGPUTransferBuffer(device, &createinfo);
  if (!frame->transfer)
    gpu_abort("SDL_CreateGPUTransferBuffer failed");

  frame->transfer_size = size;
}

static void gpu_ensure_bridge_poly_buffers(SDL_GPUDevice *device, GpuFrameBridge *frame, Uint32 size) {
  if (frame->poly_vertex_buffer && frame->poly_transfer &&
      frame->poly_vertex_buffer_size >= size && frame->poly_transfer_size >= size)
    return;

  if (frame->poly_vertex_buffer)
    SDL_ReleaseGPUBuffer(device, frame->poly_vertex_buffer);
  if (frame->poly_transfer)
    SDL_ReleaseGPUTransferBuffer(device, frame->poly_transfer);
  frame->poly_vertex_buffer = NULL;
  frame->poly_transfer = NULL;
  frame->poly_vertex_buffer_size = 0;
  frame->poly_transfer_size = 0;

  SDL_GPUBufferCreateInfo buffer_info;
  SDL_zero(buffer_info);
  buffer_info.usage = SDL_GPU_BUFFERUSAGE_VERTEX;
  buffer_info.size = size;
  frame->poly_vertex_buffer = SDL_CreateGPUBuffer(device, &buffer_info);
  if (!frame->poly_vertex_buffer)
    gpu_abort("SDL_CreateGPUBuffer failed for polygon vertices");

  SDL_GPUTransferBufferCreateInfo transfer_info;
  SDL_zero(transfer_info);
  transfer_info.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
  transfer_info.size = size;
  frame->poly_transfer = SDL_CreateGPUTransferBuffer(device, &transfer_info);
  if (!frame->poly_transfer)
    gpu_abort("SDL_CreateGPUTransferBuffer failed for polygon vertices");

  frame->poly_vertex_buffer_size = size;
  frame->poly_transfer_size = size;
}

static Uint32 gpu_align_u32(Uint32 value, Uint32 alignment) {
  return (value + alignment - 1) & ~(alignment - 1);
}

static RenRect gpu_clip_surface_rect(SDL_Surface *surface, RenRect rect) {
  int x1 = SDL_clamp(rect.x, 0, surface->w);
  int y1 = SDL_clamp(rect.y, 0, surface->h);
  int x2 = SDL_clamp(rect.x + rect.width, x1, surface->w);
  int y2 = SDL_clamp(rect.y + rect.height, y1, surface->h);
  return (RenRect) { x1, y1, x2 - x1, y2 - y1 };
}

static SDL_Rect gpu_pixel_rect_from_ren_rect(SDL_Surface *surface, RenRect rect) {
  RenRect clipped = gpu_clip_surface_rect(surface, rect);
  const int x1 = SDL_clamp((int) floor(clipped.x), 0, surface->w);
  const int y1 = SDL_clamp((int) floor(clipped.y), 0, surface->h);
  const int x2 = SDL_clamp((int) ceil(clipped.x + clipped.width), x1, surface->w);
  const int y2 = SDL_clamp((int) ceil(clipped.y + clipped.height), y1, surface->h);
  return (SDL_Rect) {.x = x1, .y = y1, .w = x2 - x1, .h = y2 - y1};
}

static int gpu_collect_upload_regions(
  SDL_Surface *surface, RenRect *rects, int count, GpuUploadRegion *regions, int max_regions
) {
  int region_count = 0;
  Uint32 offset = 0;
  const int bytes_per_pixel = SDL_BYTESPERPIXEL(surface->format);
  for (int i = 0; i < count && region_count < max_regions; i++) {
    SDL_Rect rect = gpu_pixel_rect_from_ren_rect(surface, rects[i]);
    if (rect.w == 0 || rect.h == 0)
      continue;

    Uint32 row_size = (Uint32) rect.w * bytes_per_pixel;
    Uint32 row_stride = gpu_align_u32(row_size, GPU_TEXTURE_ROW_ALIGNMENT);
    offset = gpu_align_u32(offset, GPU_TEXTURE_OFFSET_ALIGNMENT);
    Uint32 size = row_stride * rect.h;
    regions[region_count++] = (GpuUploadRegion) {
      .rect = rect,
      .offset = offset,
      .size = size,
      .row_stride = row_stride,
    };
    offset += size;
  }
  return region_count;
}

static Uint32 gpu_upload_regions_size(GpuUploadRegion *regions, int count) {
  if (count <= 0)
    return 0;
  GpuUploadRegion *last = &regions[count - 1];
  return last->offset + last->size;
}

static void gpu_copy_surface_region_to_transfer(
  SDL_Surface *surface, uint8_t *transfer, GpuUploadRegion *region
) {
  const int bytes_per_pixel = SDL_BYTESPERPIXEL(surface->format);
  const Uint32 row_size = (Uint32) region->rect.w * bytes_per_pixel;
  const uint8_t *src = (uint8_t *) surface->pixels
    + (region->rect.y * surface->pitch)
    + (region->rect.x * bytes_per_pixel);
  uint8_t *dst = transfer + region->offset;
  for (int y = 0; y < region->rect.h; y++) {
    SDL_memcpy(dst, src, row_size);
    src += surface->pitch;
    dst += region->row_stride;
  }
}

static bool gpu_upload_bridge_surface_regions(
  SDL_GPUDevice *device,
  GpuFrameBridge *frame,
  SDL_GPUCommandBuffer *cmd,
  RenRect *rects,
  int count,
  bool cycle_texture
) {
  SDL_Surface *surface = frame->surface;
  if (!surface)
    return false;

  gpu_ensure_bridge_texture(device, frame, surface->w, surface->h);
  GpuUploadRegion regions[GPU_DIRTY_UPLOAD_FULL_THRESHOLD];
  int region_count = gpu_collect_upload_regions(
    surface, rects, count, regions, GPU_DIRTY_UPLOAD_FULL_THRESHOLD
  );
  if (region_count == 0)
    return false;

  gpu_ensure_bridge_transfer_buffer(device, frame, gpu_upload_regions_size(regions, region_count));

  if (!SDL_LockSurface(surface))
    gpu_abort("SDL_LockSurface failed");

  void *map = SDL_MapGPUTransferBuffer(device, frame->transfer, true);
  if (!map) {
    SDL_UnlockSurface(surface);
    gpu_abort("SDL_MapGPUTransferBuffer failed");
  }

  for (int i = 0; i < region_count; i++)
    gpu_copy_surface_region_to_transfer(surface, map, &regions[i]);
  SDL_UnmapGPUTransferBuffer(device, frame->transfer);
  SDL_UnlockSurface(surface);

  SDL_GPUCopyPass *copy_pass = SDL_BeginGPUCopyPass(cmd);
  for (int i = 0; i < region_count; i++) {
    SDL_GPUTextureTransferInfo source;
    SDL_zero(source);
    source.transfer_buffer = frame->transfer;
    source.offset = regions[i].offset;
    source.pixels_per_row = regions[i].row_stride / SDL_BYTESPERPIXEL(surface->format);
    source.rows_per_layer = regions[i].rect.h;

    SDL_GPUTextureRegion destination;
    SDL_zero(destination);
    destination.texture = frame->texture;
    destination.x = regions[i].rect.x;
    destination.y = regions[i].rect.y;
    destination.w = regions[i].rect.w;
    destination.h = regions[i].rect.h;
    destination.d = 1;

    SDL_UploadToGPUTexture(copy_pass, &source, &destination, cycle_texture);
  }
  SDL_EndGPUCopyPass(copy_pass);
  frame->needs_full_upload = false;
  frame->dirty_count = 0;
  return true;
}

static bool gpu_upload_bridge_pending(
  SDL_GPUDevice *device,
  GpuFrameBridge *frame,
  SDL_GPUCommandBuffer *cmd,
  RenRect *rects,
  int count,
  bool force_full_upload
) {
  if (!frame->surface)
    return false;

  if (force_full_upload || frame->needs_full_upload || !frame->texture) {
    RenRect rect = {
      .x = 0,
      .y = 0,
      .width = frame->surface->w,
      .height = frame->surface->h,
    };
    return gpu_upload_bridge_surface_regions(device, frame, cmd, &rect, 1, true);
  } else if (rects && count > 0) {
    return gpu_upload_bridge_surface_regions(device, frame, cmd, rects, count, false);
  } else if (frame->dirty_count > 0) {
    return gpu_upload_bridge_surface_regions(device, frame, cmd, frame->dirty_rects, frame->dirty_count, false);
  }
  return false;
}

static void gpu_atlas_update_bytesize(RenAtlas *atlas) {
  GpuAtlasData *data = atlas->data;
  if (!data) {
    atlas->bytesize = 0;
    return;
  }

  size_t bytesize = sizeof(GpuAtlasData) + data->surface_atlas.bytesize
    + data->texture_capacity * sizeof(GpuAtlasTexture);
  for (size_t i = 0; i < data->texture_count; i++) {
    GpuAtlasTexture *texture = &data->textures[i];
    bytesize += texture->transfer_size;
    bytesize += texture->texture_w * texture->texture_h * ren_glyphformat_bytes_per_pixel(EGlyphFormatColor);
  }
  atlas->bytesize = bytesize;
}

static GpuAtlasData *gpu_atlas_data(RenAtlas *atlas) {
  GpuAtlasData *data = atlas->data;
  if (!data) {
    data = SDL_calloc(1, sizeof(GpuAtlasData));
    if (!data) {
      fprintf(stderr, "Error allocating SDL GPU atlas data\n");
      exit(1);
    }
    renatlas_surface_init(&data->surface_atlas);
    atlas->data = data;
    gpu_atlas_update_bytesize(atlas);
  }
  return data;
}

static Uint32 gpu_atlas_upload_size(SDL_Surface *surface, GlyphMetric *metric, Uint32 *row_stride) {
  Uint32 row_size = metric->x1 * ren_glyphformat_bytes_per_pixel(EGlyphFormatColor);
  *row_stride = gpu_align_u32(row_size, GPU_TEXTURE_ROW_ALIGNMENT);
  return *row_stride * (metric->y1 - metric->y0);
}

static GpuAtlasTexture *gpu_atlas_find_texture(GpuAtlasData *data, GlyphMetric *metric) {
  for (size_t i = 0; i < data->texture_count; i++) {
    GpuAtlasTexture *texture = &data->textures[i];
    if (texture->format == metric->format
        && texture->atlas_idx == metric->atlas_idx
        && texture->surface_idx == metric->surface_idx
        && texture->x1 == metric->x1
        && texture->y0 == metric->y0
        && texture->y1 == metric->y1)
      return texture;
  }

  if (data->texture_count == data->texture_capacity) {
    size_t capacity = data->texture_capacity ? data->texture_capacity * 2 : 8;
    GpuAtlasTexture *textures = SDL_realloc(data->textures, capacity * sizeof(GpuAtlasTexture));
    if (!textures) {
      fprintf(stderr, "Error allocating SDL GPU atlas texture records\n");
      exit(1);
    }
    SDL_memset(&textures[data->texture_capacity], 0, (capacity - data->texture_capacity) * sizeof(GpuAtlasTexture));
    data->textures = textures;
    data->texture_capacity = capacity;
  }

  GpuAtlasTexture *texture = &data->textures[data->texture_count++];
  texture->format = metric->format;
  texture->atlas_idx = metric->atlas_idx;
  texture->surface_idx = metric->surface_idx;
  texture->x1 = metric->x1;
  texture->y0 = metric->y0;
  texture->y1 = metric->y1;
  return texture;
}

static GpuAtlasTexture *gpu_atlas_lookup_texture(RenAtlas *atlas, GlyphMetric *metric) {
  GpuAtlasData *data = atlas->data;
  if (!data)
    return NULL;
  for (size_t i = 0; i < data->texture_count; i++) {
    GpuAtlasTexture *texture = &data->textures[i];
    if (texture->format == metric->format
        && texture->atlas_idx == metric->atlas_idx
        && texture->surface_idx == metric->surface_idx
        && texture->x1 == metric->x1
        && texture->y0 == metric->y0
        && texture->y1 == metric->y1)
      return texture;
  }
  return NULL;
}

static void gpu_atlas_ensure_texture(SDL_GPUDevice *device, GpuAtlasTexture *texture, GlyphMetric *metric) {
  int width = metric->x1;
  int height = metric->y1 - metric->y0;
  if (texture->texture && texture->texture_w == width && texture->texture_h == height)
    return;

  if (texture->texture)
    SDL_ReleaseGPUTexture(device, texture->texture);

  SDL_GPUTextureCreateInfo createinfo;
  SDL_zero(createinfo);
  createinfo.format = SDL_GetGPUTextureFormatFromPixelFormat(SDL_PIXELFORMAT_BGRA32);
  createinfo.usage = SDL_GPU_TEXTUREUSAGE_SAMPLER;
  createinfo.width = width;
  createinfo.height = height;
  createinfo.layer_count_or_depth = 1;
  createinfo.num_levels = 1;
  createinfo.sample_count = SDL_GPU_SAMPLECOUNT_1;

  texture->texture = SDL_CreateGPUTexture(device, &createinfo);
  if (!texture->texture)
    gpu_abort("SDL_CreateGPUTexture failed");

  texture->texture_w = width;
  texture->texture_h = height;
}

static void gpu_atlas_ensure_transfer(SDL_GPUDevice *device, GpuAtlasTexture *texture, Uint32 size) {
  if (texture->transfer && texture->transfer_size >= size)
    return;

  if (texture->transfer)
    SDL_ReleaseGPUTransferBuffer(device, texture->transfer);

  SDL_GPUTransferBufferCreateInfo createinfo;
  SDL_zero(createinfo);
  createinfo.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
  createinfo.size = size;

  texture->transfer = SDL_CreateGPUTransferBuffer(device, &createinfo);
  if (!texture->transfer)
    gpu_abort("SDL_CreateGPUTransferBuffer failed");

  texture->transfer_size = size;
}

static void gpu_atlas_copy_glyph_to_transfer(SDL_Surface *surface, GlyphMetric *metric, uint8_t *transfer, Uint32 row_stride) {
  const int src_bytes_per_pixel = SDL_BYTESPERPIXEL(surface->format);
  const uint8_t *src = (uint8_t *) surface->pixels + metric->y0 * surface->pitch;
  uint8_t *dst = transfer;

  for (unsigned int y = metric->y0; y < metric->y1; y++) {
    const uint8_t *src_pixel = src;
    uint8_t *dst_pixel = dst;
    for (unsigned int x = 0; x < metric->x1; x++) {
      if (metric->format == EGlyphFormatColor) {
        dst_pixel[0] = src_pixel[0];
        dst_pixel[1] = src_pixel[1];
        dst_pixel[2] = src_pixel[2];
        dst_pixel[3] = src_pixel[3];
      } else if (metric->format == EGlyphFormatSubpixel) {
        Uint8 coverage = SDL_max(src_pixel[0], SDL_max(src_pixel[1], src_pixel[2]));
        dst_pixel[0] = src_pixel[2];
        dst_pixel[1] = src_pixel[1];
        dst_pixel[2] = src_pixel[0];
        dst_pixel[3] = coverage;
      } else {
        dst_pixel[0] = src_pixel[0];
        dst_pixel[1] = src_pixel[0];
        dst_pixel[2] = src_pixel[0];
        dst_pixel[3] = src_pixel[0];
      }
      src_pixel += src_bytes_per_pixel;
      dst_pixel += ren_glyphformat_bytes_per_pixel(EGlyphFormatColor);
    }
    src += surface->pitch;
    dst += row_stride;
  }
}

static bool gpu_validate_atlas_upload(
  SDL_GPUDevice *device,
  SDL_GPUTexture *texture,
  SDL_Surface *surface,
  GlyphMetric *metric,
  SDL_GPUCommandBuffer *cmd,
  Uint32 row_stride
) {
  if (!gpu_validate_text_enabled() || gpu_atlas_validation_reported)
    return false;
  if (!device || !texture || !surface || !metric || !cmd || metric->x1 == 0 || metric->y1 <= metric->y0)
    return false;

  Uint32 height = metric->y1 - metric->y0;
  Uint32 download_stride = gpu_align_u32(metric->x1 * ren_glyphformat_bytes_per_pixel(EGlyphFormatColor), GPU_TEXTURE_ROW_ALIGNMENT);
  Uint32 download_size = download_stride * height;

  SDL_GPUTransferBufferCreateInfo transfer_info;
  SDL_zero(transfer_info);
  transfer_info.usage = SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
  transfer_info.size = download_size;
  SDL_GPUTransferBuffer *download = SDL_CreateGPUTransferBuffer(device, &transfer_info);
  if (!download)
    return false;

  SDL_GPUCopyPass *copy_pass = SDL_BeginGPUCopyPass(cmd);
  SDL_GPUTextureRegion source;
  SDL_zero(source);
  source.texture = texture;
  source.x = 0;
  source.y = 0;
  source.w = metric->x1;
  source.h = height;
  source.d = 1;

  SDL_GPUTextureTransferInfo destination;
  SDL_zero(destination);
  destination.transfer_buffer = download;
  destination.pixels_per_row = download_stride / ren_glyphformat_bytes_per_pixel(EGlyphFormatColor);
  destination.rows_per_layer = height;
  SDL_DownloadFromGPUTexture(copy_pass, &source, &destination);
  SDL_EndGPUCopyPass(copy_pass);

  SDL_GPUFence *fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
  if (!fence) {
    SDL_ReleaseGPUTransferBuffer(device, download);
    return false;
  }
  SDL_WaitForGPUFences(device, true, &fence, 1);
  SDL_ReleaseGPUFence(device, fence);

  const Uint8 *download_pixels = SDL_MapGPUTransferBuffer(device, download, false);
  if (!download_pixels) {
    SDL_ReleaseGPUTransferBuffer(device, download);
    return true;
  }

  int nonzero = 0;
  int mismatched = 0;
  int sampled = 0;
  for (Uint32 y = 0; y < height; y++) {
    const Uint8 *gpu_row = download_pixels + y * download_stride;
    const Uint8 *cpu_row = ((const Uint8 *) surface->pixels) + (metric->y0 + y) * surface->pitch;
    for (Uint32 x = 0; x < metric->x1; x++) {
      const Uint8 *gpu_px = gpu_row + x * ren_glyphformat_bytes_per_pixel(EGlyphFormatColor);
      Uint8 expected_b = 0xff;
      Uint8 expected_g = 0xff;
      Uint8 expected_r = 0xff;
      Uint8 expected_a = 0;
      if (metric->format == EGlyphFormatColor) {
        const Uint8 *cpu_px = cpu_row + x * SDL_BYTESPERPIXEL(surface->format);
        expected_b = cpu_px[0];
        expected_g = cpu_px[1];
        expected_r = cpu_px[2];
        expected_a = cpu_px[3];
      } else if (metric->format == EGlyphFormatSubpixel) {
        const Uint8 *cpu_px = cpu_row + x * SDL_BYTESPERPIXEL(surface->format);
        Uint8 coverage = SDL_max(cpu_px[0], SDL_max(cpu_px[1], cpu_px[2]));
        expected_b = cpu_px[2];
        expected_g = cpu_px[1];
        expected_r = cpu_px[0];
        expected_a = coverage;
      } else {
        expected_b = cpu_row[x * SDL_BYTESPERPIXEL(surface->format)];
        expected_g = expected_b;
        expected_r = expected_b;
        expected_a = expected_b;
      }
      if (gpu_px[3] != 0)
        nonzero++;
      if (abs((int) gpu_px[0] - (int) expected_b) > 2 ||
          abs((int) gpu_px[1] - (int) expected_g) > 2 ||
          abs((int) gpu_px[2] - (int) expected_r) > 2 ||
          abs((int) gpu_px[3] - (int) expected_a) > 2)
        mismatched++;
      sampled++;
    }
  }

  SDL_UnmapGPUTransferBuffer(device, download);
  SDL_ReleaseGPUTransferBuffer(device, download);
  fprintf(
    stderr,
    "sdlgpu atlas validation: %s format=%u glyph=%ux%u y=%u nonzero_alpha=%d/%d mismatch=%d row_stride=%u\n",
    mismatched == 0 && nonzero > 0 ? "PASS" : "FAIL",
    metric->format,
    metric->x1,
    height,
    metric->y0,
    nonzero,
    sampled,
    mismatched,
    row_stride
  );
  gpu_atlas_validation_reported = true;
  return true;
}

static SDL_Surface *gpu_atlas_allocate_glyph_surface(RenAtlas *atlas, RenAtlasGlyphRequest request, int bitmap_idx, GlyphMetric *metric) {
  GpuAtlasData *data = gpu_atlas_data(atlas);
  SDL_Surface *surface = ren_atlas_allocate_glyph_surface(&data->surface_atlas, request, bitmap_idx, metric);
  gpu_atlas_update_bytesize(atlas);
  return surface;
}

static SDL_Surface *gpu_atlas_get_glyph_surface(RenAtlas *atlas, GlyphMetric *metric) {
  GpuAtlasData *data = atlas->data;
  if (!data)
    return NULL;
  return ren_atlas_get_glyph_surface(&data->surface_atlas, metric);
}

static void gpu_atlas_glyph_updated(RenAtlas *atlas, GlyphMetric *metric) {
  GpuAtlasData *data = gpu_atlas_data(atlas);
  SDL_Surface *surface = ren_atlas_get_glyph_surface(&data->surface_atlas, metric);
  if (!surface)
    return;

  if (!data->device)
    data->device = gpu_retain_device();

  GpuAtlasTexture *texture = gpu_atlas_find_texture(data, metric);
  gpu_atlas_ensure_texture(data->device, texture, metric);

  Uint32 row_stride = 0;
  Uint32 upload_size = gpu_atlas_upload_size(surface, metric, &row_stride);
  if (upload_size == 0)
    return;
  gpu_atlas_ensure_transfer(data->device, texture, upload_size);

  if (!SDL_LockSurface(surface))
    gpu_abort("SDL_LockSurface failed");

  void *map = SDL_MapGPUTransferBuffer(data->device, texture->transfer, true);
  if (!map) {
    SDL_UnlockSurface(surface);
    gpu_abort("SDL_MapGPUTransferBuffer failed");
  }

  gpu_atlas_copy_glyph_to_transfer(surface, metric, map, row_stride);
  SDL_UnmapGPUTransferBuffer(data->device, texture->transfer);
  SDL_UnlockSurface(surface);

  SDL_GPUCommandBuffer *cmd = NULL;
  bool submit_upload = false;
  bool sync_upload = false;
  if (gpu_native_text_supported(data->device) && gpu_active_frame_device == data->device && gpu_active_frame_command_buffer) {
    cmd = SDL_AcquireGPUCommandBuffer(data->device);
    if (!cmd)
      gpu_abort("SDL_AcquireGPUCommandBuffer failed");
    submit_upload = true;
    sync_upload = true;
  } else if (gpu_active_frame_device == data->device && gpu_active_frame_command_buffer) {
    cmd = gpu_active_frame_command_buffer;
  } else {
    cmd = SDL_AcquireGPUCommandBuffer(data->device);
    if (!cmd)
      gpu_abort("SDL_AcquireGPUCommandBuffer failed");
    submit_upload = true;
  }

  SDL_GPUCopyPass *copy_pass = SDL_BeginGPUCopyPass(cmd);
  SDL_GPUTextureTransferInfo source;
  SDL_zero(source);
  source.transfer_buffer = texture->transfer;
  source.pixels_per_row = row_stride / ren_glyphformat_bytes_per_pixel(EGlyphFormatColor);
  source.rows_per_layer = metric->y1 - metric->y0;

  SDL_GPUTextureRegion destination;
  SDL_zero(destination);
  destination.texture = texture->texture;
  destination.x = 0;
  destination.y = 0;
  destination.w = metric->x1;
  destination.h = metric->y1 - metric->y0;
  destination.d = 1;

  SDL_UploadToGPUTexture(copy_pass, &source, &destination, false);
  SDL_EndGPUCopyPass(copy_pass);

  if (submit_upload) {
    bool submitted = gpu_validate_atlas_upload(
      data->device, texture->texture, surface, metric, cmd, row_stride
    );
    if (!submitted) {
      if (sync_upload) {
        SDL_GPUFence *fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
        if (!fence)
          gpu_abort("SDL_SubmitGPUCommandBufferAndAcquireFence failed");
        if (!SDL_WaitForGPUFences(data->device, true, &fence, 1))
          gpu_abort("SDL_WaitForGPUFences failed");
        SDL_ReleaseGPUFence(data->device, fence);
      } else if (!SDL_SubmitGPUCommandBuffer(cmd)) {
        gpu_abort("SDL_SubmitGPUCommandBuffer failed");
      }
    }
  }

  gpu_atlas_update_bytesize(atlas);
}

static void gpu_atlas_clear(RenAtlas *atlas) {
  GpuAtlasData *data = atlas->data;
  if (!data) {
    atlas->bytesize = 0;
    return;
  }

  if (gpu_active_frame_device == data->device && gpu_active_frame_window_data)
    gpu_flush_pending_text_barrier(gpu_active_frame_window_data);

  for (size_t i = 0; i < data->texture_count; i++) {
    if (data->textures[i].texture)
      SDL_ReleaseGPUTexture(data->device, data->textures[i].texture);
    if (data->textures[i].transfer)
      SDL_ReleaseGPUTransferBuffer(data->device, data->textures[i].transfer);
  }
  SDL_free(data->textures);
  data->textures = NULL;
  data->texture_count = 0;
  data->texture_capacity = 0;

  ren_atlas_free(&data->surface_atlas);
  if (data->device) {
    gpu_release_device();
    data->device = NULL;
  }
  gpu_atlas_update_bytesize(atlas);
}

#ifdef RENDERER_DEBUG
static void gpu_atlas_dump(RenAtlas *atlas, const char *family_name) {
  GpuAtlasData *data = atlas->data;
  if (data)
    ren_atlas_dump(&data->surface_atlas, family_name);
}
#endif

static const RenAtlasOps gpu_atlas_ops = {
  .allocate_glyph_surface = gpu_atlas_allocate_glyph_surface,
  .get_glyph_surface = gpu_atlas_get_glyph_surface,
  .glyph_updated = gpu_atlas_glyph_updated,
  .clear = gpu_atlas_clear,
#ifdef RENDERER_DEBUG
  .dump = gpu_atlas_dump,
#endif
};

static void gpu_init_atlas(RenAtlas *atlas) {
  atlas->ops = &gpu_atlas_ops;
}

static void gpu_sync_canvas_texture(GpuCanvasData *data, SDL_GPUCommandBuffer *cmd) {
  GpuFrameBridge *frame = &data->frame;
  if (!cmd)
    return;

  if (data->texture_valid && !gpu_bridge_has_pending_upload(frame))
    return;

  if (!data->surface_valid) {
    if (data->texture_valid)
      return;
    gpu_abort("SDLGPU canvas has no valid surface or texture");
  }

  if (!frame->surface)
    gpu_abort("SDLGPU canvas surface missing for texture upload");

  if (!data->device)
    data->device = gpu_retain_device();

  if (gpu_upload_bridge_pending(data->device, frame, cmd, NULL, 0, !data->texture_valid))
    data->texture_valid = true;
  else if (frame->texture)
    data->texture_valid = true;
}

static bool gpu_sync_canvas_texture_immediate(GpuCanvasData *data) {
  if (!data)
    return false;
  if (data->texture_valid && !gpu_bridge_has_pending_upload(&data->frame))
    return true;

  if (!data->device)
    data->device = gpu_retain_device();

  SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(data->device);
  if (!cmd)
    gpu_abort("SDL_AcquireGPUCommandBuffer failed");
  gpu_sync_canvas_texture(data, cmd);
  if (!gpu_submit_and_wait(data->device, cmd))
    gpu_abort("SDL_SubmitGPUCommandBufferAndAcquireFence failed");
  return data->texture_valid && data->frame.texture;
}

static bool gpu_window_region_is_native(RenCache *rc) {
  if (!rc->window_target)
    return false;

  RenWindow *ren = rc->target;
  GpuWindowData *data = ren->backend_data;
  return data && data->native_region;
}

static bool gpu_queue_window_native_rect(RenCache *rc, RenSurface *surface, RenRect rect, RenColor color) {
  if (!rc->window_target || !surface->surface)
    return false;

  RenWindow *ren = rc->target;
  GpuWindowData *data = ren->backend_data;
  if (!data || !data->command_buffer)
    return false;

  SDL_Rect dst = gpu_pixel_rect_from_ren_rect(surface->surface, rect);
  if (dst.w == 0 || dst.h == 0)
    return true;

  SDL_Rect clip;
  if (!SDL_GetSurfaceClipRect(surface->surface, &clip))
    return false;

  if (!SDL_GetRectIntersection(&dst, &clip, &dst) || dst.w == 0 || dst.h == 0)
    return true;

  if (data->pending_native_rect_count >= GPU_NATIVE_RECT_BATCH_SIZE) {
    if (!gpu_flush_window_native_rects(data, data->command_buffer))
      gpu_abort("SDLGPU native rect batch flush failed");
  }

  data->pending_native_rects[data->pending_native_rect_count++] = (GpuNativeRect) {
    .rect = dst,
    .color = color,
  };
  data->stats_native_rects++;
  return true;
}

static bool gpu_ensure_pixels_texture(GpuWindowData *data, int w, int h) {
  if (!data || w <= 0 || h <= 0)
    return false;

  if (data->pixels_texture && data->pixels_texture_w >= w && data->pixels_texture_h >= h)
    return true;

  if (data->pixels_texture)
    SDL_ReleaseGPUTexture(data->device, data->pixels_texture);

  SDL_GPUTextureCreateInfo createinfo;
  SDL_zero(createinfo);
  createinfo.format = SDL_GetGPUTextureFormatFromPixelFormat(SDL_PIXELFORMAT_RGBA32);
  createinfo.usage = SDL_GPU_TEXTUREUSAGE_SAMPLER;
  createinfo.width = w;
  createinfo.height = h;
  createinfo.layer_count_or_depth = 1;
  createinfo.num_levels = 1;
  createinfo.sample_count = SDL_GPU_SAMPLECOUNT_1;

  data->pixels_texture = SDL_CreateGPUTexture(data->device, &createinfo);
  if (!data->pixels_texture) {
    data->pixels_texture_w = 0;
    data->pixels_texture_h = 0;
    return false;
  }

  data->pixels_texture_w = w;
  data->pixels_texture_h = h;
  return true;
}

static bool gpu_ensure_pixels_transfer(GpuWindowData *data, Uint32 size) {
  if (!data || size == 0)
    return false;
  if (data->pixels_transfer && data->pixels_transfer_size >= size)
    return true;

  if (data->pixels_transfer)
    SDL_ReleaseGPUTransferBuffer(data->device, data->pixels_transfer);

  SDL_GPUTransferBufferCreateInfo createinfo;
  SDL_zero(createinfo);
  createinfo.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
  createinfo.size = size;

  data->pixels_transfer = SDL_CreateGPUTransferBuffer(data->device, &createinfo);
  if (!data->pixels_transfer) {
    data->pixels_transfer_size = 0;
    return false;
  }

  data->pixels_transfer_size = size;
  return true;
}

static bool gpu_draw_pixels_native(
  RenCache *rc, RenSurface *surface, RenRect rect, const char *bytes, size_t len
) {
  if (!rc->window_target || !surface->surface || !bytes || rect.width <= 0 || rect.height <= 0)
    return false;

  RenWindow *ren = rc->target;
  GpuWindowData *data = ren->backend_data;
  if (!data || !data->command_buffer || !data->frame.texture)
    return false;

  SDL_Rect dst = gpu_pixel_rect_from_ren_rect(surface->surface, rect);
  if (dst.w <= 0 || dst.h <= 0)
    return true;

  SDL_Rect clip;
  if (!SDL_GetSurfaceClipRect(surface->surface, &clip))
    return false;
  if (!SDL_GetRectIntersection(&dst, &clip, &dst) || dst.w <= 0 || dst.h <= 0)
    return true;

  const int bytes_per_pixel = 4;
  const Uint64 source_pitch = (Uint64) rect.width * bytes_per_pixel;
  const Uint64 required = source_pitch * (Uint64) rect.height;
  if ((Uint64) len < required)
    return false;

  if (!gpu_ensure_pixels_texture(data, dst.w, dst.h))
    return false;

  Uint32 row_size = (Uint32) dst.w * bytes_per_pixel;
  Uint32 row_stride = gpu_align_u32(row_size, GPU_TEXTURE_ROW_ALIGNMENT);
  Uint32 upload_size = row_stride * (Uint32) dst.h;
  if (!gpu_ensure_pixels_transfer(data, upload_size))
    return false;

  Uint8 *map = SDL_MapGPUTransferBuffer(data->device, data->pixels_transfer, true);
  if (!map)
    return false;

  const int src_x = dst.x - rect.x;
  const int src_y = dst.y - rect.y;
  const Uint8 *src = (const Uint8 *) bytes + (Uint64) src_y * source_pitch + (Uint64) src_x * bytes_per_pixel;
  Uint8 *out = map;
  for (int y = 0; y < dst.h; y++) {
    SDL_memcpy(out, src, row_size);
    src += source_pitch;
    out += row_stride;
  }
  SDL_UnmapGPUTransferBuffer(data->device, data->pixels_transfer);

  SDL_GPUCopyPass *copy_pass = SDL_BeginGPUCopyPass(data->command_buffer);
  SDL_GPUTextureTransferInfo source_info;
  SDL_zero(source_info);
  source_info.transfer_buffer = data->pixels_transfer;
  source_info.pixels_per_row = row_stride / bytes_per_pixel;
  source_info.rows_per_layer = dst.h;

  SDL_GPUTextureRegion destination;
  SDL_zero(destination);
  destination.texture = data->pixels_texture;
  destination.w = dst.w;
  destination.h = dst.h;
  destination.d = 1;
  SDL_UploadToGPUTexture(copy_pass, &source_info, &destination, false);
  SDL_EndGPUCopyPass(copy_pass);

  if (!gpu_flush_window_native_rects(data, data->command_buffer))
    gpu_abort("SDLGPU native rect flush before pixels failed");
  if (data->pending_text_glyph_count > 0)
    gpu_flush_queued_text(data, data->command_buffer, NULL, 0, false);

  SDL_GPUBlitInfo blit_info;
  SDL_zero(blit_info);
  blit_info.source.texture = data->pixels_texture;
  blit_info.source.w = dst.w;
  blit_info.source.h = dst.h;
  blit_info.destination.texture = data->frame.texture;
  blit_info.destination.x = dst.x;
  blit_info.destination.y = dst.y;
  blit_info.destination.w = dst.w;
  blit_info.destination.h = dst.h;
  blit_info.load_op = SDL_GPU_LOADOP_LOAD;
  blit_info.filter = SDL_GPU_FILTER_NEAREST;
  SDL_BlitGPUTexture(data->command_buffer, &blit_info);
  data->frame_synced_during_replay = true;
  data->stats_native_pixels++;
  return true;
}

static double gpu_poly_area(RenPoint *points, int *indices, int count) {
  double area = 0.0;
  for (int i = 0; i < count; i++) {
    RenPoint *a = &points[indices[i]];
    RenPoint *b = &points[indices[(i + 1) % count]];
    area += (double) a->x * (double) b->y - (double) b->x * (double) a->y;
  }
  return area * 0.5;
}

static double gpu_poly_cross(RenPoint *a, RenPoint *b, RenPoint *c) {
  return ((double) b->x - a->x) * ((double) c->y - a->y)
       - ((double) b->y - a->y) * ((double) c->x - a->x);
}

static bool gpu_poly_point_in_triangle(RenPoint *p, RenPoint *a, RenPoint *b, RenPoint *c) {
  double c1 = gpu_poly_cross(a, b, p);
  double c2 = gpu_poly_cross(b, c, p);
  double c3 = gpu_poly_cross(c, a, p);
  bool has_neg = c1 < 0 || c2 < 0 || c3 < 0;
  bool has_pos = c1 > 0 || c2 > 0 || c3 > 0;
  return !(has_neg && has_pos);
}

static bool gpu_append_flat_poly_point(RenPoint **points, int *count, int *capacity, float x, float y) {
  if (*count > 0) {
    RenPoint *last = &(*points)[*count - 1];
    if (last->x == (int) lroundf(x) && last->y == (int) lroundf(y))
      return true;
  }

  if (*count == *capacity) {
    int next_capacity = *capacity ? *capacity * 2 : 32;
    RenPoint *next = SDL_realloc(*points, next_capacity * sizeof(RenPoint));
    if (!next)
      return false;
    *points = next;
    *capacity = next_capacity;
  }

  (*points)[*count] = (RenPoint) {
    .x = (int) lroundf(x),
    .y = (int) lroundf(y),
    .tag = POLY_NORMAL,
  };
  (*count)++;
  return true;
}

static bool gpu_flatten_poly(RenPoint *points, unsigned short npoints, RenPoint **flat, unsigned short *flat_count) {
  *flat = NULL;
  *flat_count = 0;
  if (npoints < 3 || points[0].tag != POLY_NORMAL)
    return false;

  int count = 0;
  int capacity = 0;
  if (!gpu_append_flat_poly_point(flat, &count, &capacity, points[0].x, points[0].y))
    return false;

  const int segments = 12;
  for (unsigned short i = 1; i < npoints; i++) {
    RenPoint p0 = (*flat)[count - 1];
    RenPoint p1 = points[i];

    if (p1.tag == POLY_NORMAL) {
      if (!gpu_append_flat_poly_point(flat, &count, &capacity, p1.x, p1.y))
        goto error;
      continue;
    }

    if (p1.tag == POLY_CONTROL_CONIC) {
      if (i + 1 >= npoints || points[i + 1].tag != POLY_NORMAL)
        goto error;
      RenPoint p2 = points[++i];
      for (int s = 1; s <= segments; s++) {
        float t = (float) s / (float) segments;
        float mt = 1.0f - t;
        float x = mt * mt * p0.x + 2.0f * mt * t * p1.x + t * t * p2.x;
        float y = mt * mt * p0.y + 2.0f * mt * t * p1.y + t * t * p2.y;
        if (!gpu_append_flat_poly_point(flat, &count, &capacity, x, y))
          goto error;
      }
      continue;
    }

    if (p1.tag == POLY_CONTROL_CUBIC) {
      if (i + 2 >= npoints || points[i + 1].tag != POLY_CONTROL_CUBIC ||
          points[i + 2].tag != POLY_NORMAL)
        goto error;
      RenPoint p2 = points[++i];
      RenPoint p3 = points[++i];
      for (int s = 1; s <= segments; s++) {
        float t = (float) s / (float) segments;
        float mt = 1.0f - t;
        float x = mt * mt * mt * p0.x
          + 3.0f * mt * mt * t * p1.x
          + 3.0f * mt * t * t * p2.x
          + t * t * t * p3.x;
        float y = mt * mt * mt * p0.y
          + 3.0f * mt * mt * t * p1.y
          + 3.0f * mt * t * t * p2.y
          + t * t * t * p3.y;
        if (!gpu_append_flat_poly_point(flat, &count, &capacity, x, y))
          goto error;
      }
      continue;
    }

    goto error;
  }

  if (count > 1 && (*flat)[0].x == (*flat)[count - 1].x && (*flat)[0].y == (*flat)[count - 1].y)
    count--;
  if (count < 3 || count > MAX_POLY_POINTS)
    goto error;

  *flat_count = (unsigned short) count;
  return true;

error:
  SDL_free(*flat);
  *flat = NULL;
  *flat_count = 0;
  return false;
}

static int gpu_triangulate_line_poly(RenPoint *points, unsigned short npoints, GpuPolyVertex *vertices, float scale_x, float scale_y) {
  if (npoints < 3)
    return 0;

  int *indices = SDL_malloc(npoints * sizeof(int));
  if (!indices)
    gpu_abort("Error allocating polygon triangulation indices");
  for (unsigned short i = 0; i < npoints; i++)
    indices[i] = i;

  int count = npoints;
  int vertex_count = 0;
  bool ccw = gpu_poly_area(points, indices, count) > 0.0;
  int guard = 0;

  while (count > 3 && guard++ < npoints * npoints) {
    bool clipped = false;
    for (int i = 0; i < count; i++) {
      int prev_i = (i + count - 1) % count;
      int next_i = (i + 1) % count;
      RenPoint *a = &points[indices[prev_i]];
      RenPoint *b = &points[indices[i]];
      RenPoint *c = &points[indices[next_i]];
      double cross = gpu_poly_cross(a, b, c);
      if ((ccw && cross <= 0.0) || (!ccw && cross >= 0.0))
        continue;

      bool contains = false;
      for (int j = 0; j < count; j++) {
        if (j == prev_i || j == i || j == next_i)
          continue;
        if (gpu_poly_point_in_triangle(&points[indices[j]], a, b, c)) {
          contains = true;
          break;
        }
      }
      if (contains)
        continue;

      vertices[vertex_count++] = (GpuPolyVertex) { a->x * scale_x, a->y * scale_y };
      vertices[vertex_count++] = (GpuPolyVertex) { b->x * scale_x, b->y * scale_y };
      vertices[vertex_count++] = (GpuPolyVertex) { c->x * scale_x, c->y * scale_y };
      SDL_memmove(&indices[i], &indices[i + 1], (count - i - 1) * sizeof(int));
      count--;
      clipped = true;
      break;
    }
    if (!clipped) {
      SDL_free(indices);
      return 0;
    }
  }

  if (count == 3) {
    RenPoint *a = &points[indices[0]];
    RenPoint *b = &points[indices[1]];
    RenPoint *c = &points[indices[2]];
    vertices[vertex_count++] = (GpuPolyVertex) { a->x * scale_x, a->y * scale_y };
    vertices[vertex_count++] = (GpuPolyVertex) { b->x * scale_x, b->y * scale_y };
    vertices[vertex_count++] = (GpuPolyVertex) { c->x * scale_x, c->y * scale_y };
  }

  SDL_free(indices);
  return vertex_count;
}

static bool gpu_draw_poly_vertices_to_bridge(
  SDL_GPUDevice *device, SDL_GPUCommandBuffer *cmd, GpuFrameBridge *frame,
  SDL_Surface *surface, GpuPolyVertex *vertices, int vertex_count, RenRect bounds, RenColor color
) {
  if (!device || !cmd || !frame || !surface || !vertices || vertex_count <= 0)
    return false;
  if (!gpu_ensure_poly_pipeline(device))
    return false;

  gpu_ensure_bridge_texture(device, frame, surface->w, surface->h);
  if (!frame->texture)
    return false;

  Uint32 upload_size = vertex_count * sizeof(GpuPolyVertex);
  gpu_ensure_bridge_poly_buffers(device, frame, upload_size);

  GpuPolyVertex *map = SDL_MapGPUTransferBuffer(device, frame->poly_transfer, true);
  if (!map)
    return false;
  SDL_memcpy(map, vertices, upload_size);
  SDL_UnmapGPUTransferBuffer(device, frame->poly_transfer);

  SDL_GPUCopyPass *copy_pass = SDL_BeginGPUCopyPass(cmd);
  SDL_GPUTransferBufferLocation source;
  SDL_zero(source);
  source.transfer_buffer = frame->poly_transfer;
  SDL_GPUBufferRegion destination;
  SDL_zero(destination);
  destination.buffer = frame->poly_vertex_buffer;
  destination.size = upload_size;
  SDL_UploadToGPUBuffer(copy_pass, &source, &destination, true);
  SDL_EndGPUCopyPass(copy_pass);

  SDL_Rect scissor = gpu_pixel_rect_from_ren_rect(surface, bounds);
  SDL_Rect clip;
  if (!SDL_GetSurfaceClipRect(surface, &clip))
    return false;
  if (!SDL_GetRectIntersection(&scissor, &clip, &scissor) || scissor.w <= 0 || scissor.h <= 0)
    return true;

  SDL_GPUColorTargetInfo color_target;
  SDL_zero(color_target);
  color_target.texture = frame->texture;
  color_target.load_op = SDL_GPU_LOADOP_LOAD;
  color_target.store_op = SDL_GPU_STOREOP_STORE;

  SDL_GPUViewport viewport;
  SDL_zero(viewport);
  viewport.w = frame->texture_w;
  viewport.h = frame->texture_h;
  viewport.max_depth = 1;

  SDL_GPURenderPass *pass = SDL_BeginGPURenderPass(cmd, &color_target, 1, NULL);
  SDL_SetGPUViewport(pass, &viewport);
  SDL_SetGPUScissor(pass, &scissor);
  SDL_BindGPUGraphicsPipeline(pass, gpu_poly_pipeline);

  SDL_GPUBufferBinding binding;
  SDL_zero(binding);
  binding.buffer = frame->poly_vertex_buffer;
  SDL_BindGPUVertexBuffers(pass, 0, &binding, 1);

  GpuPolyVertexUniforms vertex_uniforms = {
    .target = { frame->texture_w, frame->texture_h, 0, 0 },
  };
  GpuPolyFragmentUniforms fragment_uniforms = {
    .color = {
      (float) color.r / 255.0f,
      (float) color.g / 255.0f,
      (float) color.b / 255.0f,
      (float) color.a / 255.0f,
    },
  };
  SDL_PushGPUVertexUniformData(cmd, 0, &vertex_uniforms, sizeof(vertex_uniforms));
  SDL_PushGPUFragmentUniformData(cmd, 0, &fragment_uniforms, sizeof(fragment_uniforms));
  SDL_DrawGPUPrimitives(pass, vertex_count, 1, 0, 0);
  SDL_EndGPURenderPass(pass);
  return true;
}

static bool gpu_draw_poly_native(
  RenCache *rc, RenSurface *surface, RenPoint *points, unsigned short npoints, RenColor color
) {
  if (!rc->window_target || !surface->surface || npoints < 3)
    return false;

  RenRect bounds;
  if (ren_poly_cbox(points, npoints, &bounds) != 0 || bounds.width <= 0 || bounds.height <= 0)
    return false;

  SDL_Rect dst = gpu_pixel_rect_from_ren_rect(surface->surface, bounds);
  if (dst.w <= 0 || dst.h <= 0)
    return true;

  SDL_Rect clip;
  if (!SDL_GetSurfaceClipRect(surface->surface, &clip))
    return false;
  if (!SDL_GetRectIntersection(&dst, &clip, &dst) || dst.w <= 0 || dst.h <= 0)
    return true;

  RenWindow *ren = rc->target;
  GpuWindowData *data = ren->backend_data;
  if (!data || !data->command_buffer || !data->frame.texture)
    return false;

  RenPoint *flat_points = NULL;
  unsigned short flat_count = 0;
  if (!gpu_flatten_poly(points, npoints, &flat_points, &flat_count))
    return false;

  GpuPolyVertex *vertices = SDL_malloc((flat_count - 2) * 3 * sizeof(GpuPolyVertex));
  if (!vertices)
    gpu_abort("Error allocating polygon vertices");
  int vertex_count = gpu_triangulate_line_poly(
    flat_points, flat_count, vertices,
    surface->scale_x > 0 ? surface->scale_x : 1.0f,
    surface->scale_y > 0 ? surface->scale_y : 1.0f
  );
  if (vertex_count == 0) {
    SDL_free(flat_points);
    SDL_free(vertices);
    return false;
  }

  if (!gpu_flush_window_native_rects(data, data->command_buffer))
    gpu_abort("SDLGPU native rect flush before poly failed");
  if (data->pending_text_glyph_count > 0)
    gpu_flush_queued_text(data, data->command_buffer, NULL, 0, false);

  bool drawn = gpu_draw_poly_vertices_to_bridge(
    data->device, data->command_buffer, &data->frame, surface->surface,
    vertices, vertex_count, bounds, color
  );
  SDL_free(flat_points);
  SDL_free(vertices);
  if (!drawn)
    return false;

  data->frame_synced_during_replay = true;
  data->stats_native_polys++;
  return true;
}

static SDL_GPUShader *gpu_create_canvas_shader(SDL_GPUDevice *device, bool vertex) {
  SDL_GPUShaderCreateInfo createinfo;
  SDL_zero(createinfo);
  createinfo.num_samplers = vertex ? 0 : 1;
  createinfo.num_uniform_buffers = vertex ? 1 : 0;
  createinfo.stage = vertex ? SDL_GPU_SHADERSTAGE_VERTEX : SDL_GPU_SHADERSTAGE_FRAGMENT;

  SDL_GPUShaderFormat format = SDL_GetGPUShaderFormats(device);
  if (format & SDL_GPU_SHADERFORMAT_DXBC) {
    createinfo.format = SDL_GPU_SHADERFORMAT_DXBC;
    createinfo.code = vertex ? gpu_canvas_vert_dxbc : gpu_canvas_frag_dxbc;
    createinfo.code_size = vertex ? gpu_canvas_vert_dxbc_len : gpu_canvas_frag_dxbc_len;
  } else if (format & SDL_GPU_SHADERFORMAT_MSL) {
    createinfo.format = SDL_GPU_SHADERFORMAT_MSL;
    createinfo.code = vertex ? gpu_canvas_vert_msl : gpu_canvas_frag_msl;
    createinfo.code_size = vertex ? gpu_canvas_vert_msl_len : gpu_canvas_frag_msl_len;
  } else if (format & SDL_GPU_SHADERFORMAT_SPIRV) {
    createinfo.format = SDL_GPU_SHADERFORMAT_SPIRV;
    createinfo.code = vertex ? gpu_canvas_vert_spv : gpu_canvas_frag_spv;
    createinfo.code_size = vertex ? gpu_canvas_vert_spv_len : gpu_canvas_frag_spv_len;
  } else {
    return NULL;
  }

  return SDL_CreateGPUShader(device, &createinfo);
}

static SDL_GPUShader *gpu_create_poly_shader(SDL_GPUDevice *device, bool vertex) {
  SDL_GPUShaderCreateInfo createinfo;
  SDL_zero(createinfo);
  createinfo.num_uniform_buffers = 1;
  createinfo.stage = vertex ? SDL_GPU_SHADERSTAGE_VERTEX : SDL_GPU_SHADERSTAGE_FRAGMENT;

  SDL_GPUShaderFormat format = SDL_GetGPUShaderFormats(device);
  if (format & SDL_GPU_SHADERFORMAT_DXBC) {
    createinfo.format = SDL_GPU_SHADERFORMAT_DXBC;
    createinfo.code = vertex ? gpu_poly_vert_dxbc : gpu_poly_frag_dxbc;
    createinfo.code_size = vertex ? gpu_poly_vert_dxbc_len : gpu_poly_frag_dxbc_len;
  } else if (format & SDL_GPU_SHADERFORMAT_MSL) {
    createinfo.format = SDL_GPU_SHADERFORMAT_MSL;
    createinfo.code = vertex ? gpu_poly_vert_msl : gpu_poly_frag_msl;
    createinfo.code_size = vertex ? gpu_poly_vert_msl_len : gpu_poly_frag_msl_len;
  } else if (format & SDL_GPU_SHADERFORMAT_SPIRV) {
    createinfo.format = SDL_GPU_SHADERFORMAT_SPIRV;
    createinfo.code = vertex ? gpu_poly_vert_spv : gpu_poly_frag_spv;
    createinfo.code_size = vertex ? gpu_poly_vert_spv_len : gpu_poly_frag_spv_len;
  } else {
    return NULL;
  }

  return SDL_CreateGPUShader(device, &createinfo);
}

static bool gpu_ensure_poly_pipeline(SDL_GPUDevice *device) {
  if (gpu_poly_pipeline)
    return true;
  if (gpu_poly_pipeline_failed)
    return false;

  SDL_GPUShader *vertex_shader = gpu_create_poly_shader(device, true);
  SDL_GPUShader *fragment_shader = gpu_create_poly_shader(device, false);
  if (!vertex_shader || !fragment_shader) {
    if (vertex_shader) SDL_ReleaseGPUShader(device, vertex_shader);
    if (fragment_shader) SDL_ReleaseGPUShader(device, fragment_shader);
    gpu_poly_pipeline_failed = true;
    return false;
  }

  SDL_GPUVertexBufferDescription vertex_buffer;
  SDL_zero(vertex_buffer);
  vertex_buffer.slot = 0;
  vertex_buffer.pitch = sizeof(GpuPolyVertex);
  vertex_buffer.input_rate = SDL_GPU_VERTEXINPUTRATE_VERTEX;

  SDL_GPUVertexAttribute vertex_attribute;
  SDL_zero(vertex_attribute);
  vertex_attribute.location = 0;
  vertex_attribute.buffer_slot = 0;
  vertex_attribute.format = SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2;
  vertex_attribute.offset = 0;

  SDL_GPUColorTargetDescription color_target;
  SDL_zero(color_target);
  color_target.format = SDL_GetGPUTextureFormatFromPixelFormat(SDL_PIXELFORMAT_BGRA32);
  color_target.blend_state.enable_blend = true;
  color_target.blend_state.enable_color_write_mask = true;
  color_target.blend_state.color_write_mask =
    SDL_GPU_COLORCOMPONENT_R | SDL_GPU_COLORCOMPONENT_G |
    SDL_GPU_COLORCOMPONENT_B | SDL_GPU_COLORCOMPONENT_A;
  color_target.blend_state.color_blend_op = SDL_GPU_BLENDOP_ADD;
  color_target.blend_state.alpha_blend_op = SDL_GPU_BLENDOP_ADD;
  color_target.blend_state.src_color_blendfactor = SDL_GPU_BLENDFACTOR_SRC_ALPHA;
  color_target.blend_state.dst_color_blendfactor = SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
  color_target.blend_state.src_alpha_blendfactor = SDL_GPU_BLENDFACTOR_ONE;
  color_target.blend_state.dst_alpha_blendfactor = SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;

  SDL_GPUGraphicsPipelineCreateInfo pipeline_info;
  SDL_zero(pipeline_info);
  pipeline_info.vertex_shader = vertex_shader;
  pipeline_info.fragment_shader = fragment_shader;
  pipeline_info.primitive_type = SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
  pipeline_info.rasterizer_state.enable_depth_clip = true;
  pipeline_info.vertex_input_state.vertex_buffer_descriptions = &vertex_buffer;
  pipeline_info.vertex_input_state.num_vertex_buffers = 1;
  pipeline_info.vertex_input_state.vertex_attributes = &vertex_attribute;
  pipeline_info.vertex_input_state.num_vertex_attributes = 1;
  pipeline_info.target_info.num_color_targets = 1;
  pipeline_info.target_info.color_target_descriptions = &color_target;

  gpu_poly_pipeline = SDL_CreateGPUGraphicsPipeline(device, &pipeline_info);
  SDL_ReleaseGPUShader(device, vertex_shader);
  SDL_ReleaseGPUShader(device, fragment_shader);
  if (!gpu_poly_pipeline) {
    gpu_poly_pipeline_failed = true;
    return false;
  }

  return true;
}

static void gpu_destroy_poly_pipeline(SDL_GPUDevice *device) {
  if (gpu_poly_pipeline) {
    SDL_ReleaseGPUGraphicsPipeline(device, gpu_poly_pipeline);
    gpu_poly_pipeline = NULL;
  }
  gpu_poly_pipeline_failed = false;
}

static SDL_GPUGraphicsPipeline *gpu_create_canvas_graphics_pipeline(
  SDL_GPUDevice *device, SDL_GPUTextureFormat target_format, bool blend
) {
  SDL_GPUShader *vertex_shader = gpu_create_canvas_shader(device, true);
  SDL_GPUShader *fragment_shader = gpu_create_canvas_shader(device, false);
  if (!vertex_shader || !fragment_shader) {
    if (vertex_shader) SDL_ReleaseGPUShader(device, vertex_shader);
    if (fragment_shader) SDL_ReleaseGPUShader(device, fragment_shader);
    return NULL;
  }

  SDL_GPUColorTargetDescription color_target;
  SDL_zero(color_target);
  color_target.format = target_format;
  color_target.blend_state.enable_blend = blend;
  color_target.blend_state.enable_color_write_mask = true;
  color_target.blend_state.color_write_mask =
    SDL_GPU_COLORCOMPONENT_R | SDL_GPU_COLORCOMPONENT_G |
    SDL_GPU_COLORCOMPONENT_B | SDL_GPU_COLORCOMPONENT_A;
  color_target.blend_state.color_blend_op = SDL_GPU_BLENDOP_ADD;
  color_target.blend_state.alpha_blend_op = SDL_GPU_BLENDOP_ADD;
  color_target.blend_state.src_color_blendfactor = blend ? SDL_GPU_BLENDFACTOR_SRC_ALPHA : SDL_GPU_BLENDFACTOR_ONE;
  color_target.blend_state.dst_color_blendfactor = blend ? SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA : SDL_GPU_BLENDFACTOR_ZERO;
  color_target.blend_state.src_alpha_blendfactor = SDL_GPU_BLENDFACTOR_ONE;
  color_target.blend_state.dst_alpha_blendfactor = blend ? SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA : SDL_GPU_BLENDFACTOR_ZERO;

  SDL_GPUGraphicsPipelineCreateInfo pipeline_info;
  SDL_zero(pipeline_info);
  pipeline_info.vertex_shader = vertex_shader;
  pipeline_info.fragment_shader = fragment_shader;
  pipeline_info.primitive_type = SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
  pipeline_info.rasterizer_state.enable_depth_clip = true;
  pipeline_info.target_info.num_color_targets = 1;
  pipeline_info.target_info.color_target_descriptions = &color_target;

  SDL_GPUGraphicsPipeline *pipeline = SDL_CreateGPUGraphicsPipeline(device, &pipeline_info);
  SDL_ReleaseGPUShader(device, vertex_shader);
  SDL_ReleaseGPUShader(device, fragment_shader);
  return pipeline;
}

static bool gpu_ensure_canvas_pipeline(SDL_GPUDevice *device) {
  if (gpu_canvas_blend_pipeline && gpu_canvas_sampler)
    return true;
  if (gpu_canvas_pipeline_failed)
    return false;

  gpu_canvas_blend_pipeline = gpu_create_canvas_graphics_pipeline(
    device,
    SDL_GetGPUTextureFormatFromPixelFormat(SDL_PIXELFORMAT_BGRA32),
    true
  );
  if (!gpu_canvas_blend_pipeline) {
    gpu_canvas_pipeline_failed = true;
    return false;
  }

  SDL_GPUSamplerCreateInfo sampler_info;
  SDL_zero(sampler_info);
  sampler_info.min_filter = SDL_GPU_FILTER_NEAREST;
  sampler_info.mag_filter = SDL_GPU_FILTER_NEAREST;
  sampler_info.mipmap_mode = SDL_GPU_SAMPLERMIPMAPMODE_NEAREST;
  sampler_info.address_mode_u = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
  sampler_info.address_mode_v = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
  sampler_info.address_mode_w = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
  gpu_canvas_sampler = SDL_CreateGPUSampler(device, &sampler_info);
  if (!gpu_canvas_sampler) {
    SDL_ReleaseGPUGraphicsPipeline(device, gpu_canvas_blend_pipeline);
    gpu_canvas_blend_pipeline = NULL;
    gpu_canvas_pipeline_failed = true;
    return false;
  }

  return true;
}

static void gpu_destroy_canvas_pipeline(SDL_GPUDevice *device) {
  if (gpu_canvas_sampler) {
    SDL_ReleaseGPUSampler(device, gpu_canvas_sampler);
    gpu_canvas_sampler = NULL;
  }
  if (gpu_canvas_blend_pipeline) {
    SDL_ReleaseGPUGraphicsPipeline(device, gpu_canvas_blend_pipeline);
    gpu_canvas_blend_pipeline = NULL;
  }
  gpu_canvas_pipeline_failed = false;
}

static SDL_GPUShader *gpu_create_text_shader(SDL_GPUDevice *device, bool vertex) {
  SDL_GPUShaderCreateInfo createinfo;
  SDL_zero(createinfo);
  createinfo.stage = vertex ? SDL_GPU_SHADERSTAGE_VERTEX : SDL_GPU_SHADERSTAGE_FRAGMENT;
  createinfo.num_samplers = vertex ? 0 : 1;
  createinfo.num_uniform_buffers = 1;

  SDL_GPUShaderFormat format = SDL_GetGPUShaderFormats(device);
  if (format & SDL_GPU_SHADERFORMAT_DXBC) {
    createinfo.format = SDL_GPU_SHADERFORMAT_DXBC;
    createinfo.code = vertex ? gpu_text_vert_dxbc : gpu_text_frag_dxbc;
    createinfo.code_size = vertex ? gpu_text_vert_dxbc_len : gpu_text_frag_dxbc_len;
  } else if (format & SDL_GPU_SHADERFORMAT_MSL) {
    createinfo.format = SDL_GPU_SHADERFORMAT_MSL;
    createinfo.code = vertex ? gpu_text_vert_msl : gpu_text_frag_msl;
    createinfo.code_size = vertex ? gpu_text_vert_msl_len : gpu_text_frag_msl_len;
  } else if (format & SDL_GPU_SHADERFORMAT_SPIRV) {
    createinfo.format = SDL_GPU_SHADERFORMAT_SPIRV;
    createinfo.code = vertex ? gpu_text_vert_spv : gpu_text_frag_spv;
    createinfo.code_size = vertex ? gpu_text_vert_spv_len : gpu_text_frag_spv_len;
  } else {
    return NULL;
  }

  return SDL_CreateGPUShader(device, &createinfo);
}

static SDL_GPUGraphicsPipeline *gpu_create_text_graphics_pipeline(SDL_GPUDevice *device, bool blend) {
  SDL_GPUShader *vertex_shader = gpu_create_text_shader(device, true);
  SDL_GPUShader *fragment_shader = gpu_create_text_shader(device, false);
  if (!vertex_shader || !fragment_shader) {
    if (vertex_shader) SDL_ReleaseGPUShader(device, vertex_shader);
    if (fragment_shader) SDL_ReleaseGPUShader(device, fragment_shader);
    return NULL;
  }

  SDL_GPUColorTargetDescription color_target;
  SDL_zero(color_target);
  color_target.format = SDL_GetGPUTextureFormatFromPixelFormat(SDL_PIXELFORMAT_BGRA32);
  color_target.blend_state.enable_blend = blend;
  color_target.blend_state.enable_color_write_mask = true;
  color_target.blend_state.color_write_mask =
    SDL_GPU_COLORCOMPONENT_R | SDL_GPU_COLORCOMPONENT_G |
    SDL_GPU_COLORCOMPONENT_B | SDL_GPU_COLORCOMPONENT_A;
  color_target.blend_state.color_blend_op = SDL_GPU_BLENDOP_ADD;
  color_target.blend_state.alpha_blend_op = SDL_GPU_BLENDOP_ADD;
  color_target.blend_state.src_color_blendfactor = blend ? SDL_GPU_BLENDFACTOR_SRC_ALPHA : SDL_GPU_BLENDFACTOR_ONE;
  color_target.blend_state.dst_color_blendfactor = blend ? SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA : SDL_GPU_BLENDFACTOR_ZERO;
  color_target.blend_state.src_alpha_blendfactor = SDL_GPU_BLENDFACTOR_ONE;
  color_target.blend_state.dst_alpha_blendfactor = blend ? SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA : SDL_GPU_BLENDFACTOR_ZERO;

  SDL_GPUGraphicsPipelineCreateInfo pipeline_info;
  SDL_zero(pipeline_info);
  pipeline_info.vertex_shader = vertex_shader;
  pipeline_info.fragment_shader = fragment_shader;
  pipeline_info.primitive_type = SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
  pipeline_info.rasterizer_state.enable_depth_clip = true;
  pipeline_info.target_info.num_color_targets = 1;
  pipeline_info.target_info.color_target_descriptions = &color_target;

  SDL_GPUGraphicsPipeline *pipeline = SDL_CreateGPUGraphicsPipeline(device, &pipeline_info);
  SDL_ReleaseGPUShader(device, vertex_shader);
  SDL_ReleaseGPUShader(device, fragment_shader);
  return pipeline;
}

static bool gpu_ensure_text_pipeline(SDL_GPUDevice *device) {
  if (gpu_text_pipeline && gpu_text_sampler)
    return true;
  if (gpu_text_pipeline_failed)
    return false;

  gpu_text_pipeline = gpu_create_text_graphics_pipeline(device, true);
  if (!gpu_text_pipeline) {
    gpu_text_pipeline_failed = true;
    return false;
  }

  SDL_GPUSamplerCreateInfo sampler_info;
  SDL_zero(sampler_info);
  sampler_info.min_filter = SDL_GPU_FILTER_NEAREST;
  sampler_info.mag_filter = SDL_GPU_FILTER_NEAREST;
  sampler_info.mipmap_mode = SDL_GPU_SAMPLERMIPMAPMODE_NEAREST;
  sampler_info.address_mode_u = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
  sampler_info.address_mode_v = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
  sampler_info.address_mode_w = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
  gpu_text_sampler = SDL_CreateGPUSampler(device, &sampler_info);
  if (!gpu_text_sampler) {
    SDL_ReleaseGPUGraphicsPipeline(device, gpu_text_pipeline);
    gpu_text_pipeline = NULL;
    gpu_text_pipeline_failed = true;
    return false;
  }

  return true;
}

static bool gpu_ensure_text_replace_pipeline(SDL_GPUDevice *device) {
  if (gpu_text_replace_pipeline)
    return true;
  if (gpu_text_pipeline_failed)
    return false;
  if (!gpu_ensure_text_pipeline(device))
    return false;

  gpu_text_replace_pipeline = gpu_create_text_graphics_pipeline(device, false);
  if (!gpu_text_replace_pipeline) {
    gpu_text_pipeline_failed = true;
    return false;
  }

  return true;
}

static void gpu_destroy_text_pipeline(SDL_GPUDevice *device) {
  if (gpu_solid_white_transfer) {
    SDL_ReleaseGPUTransferBuffer(device, gpu_solid_white_transfer);
    gpu_solid_white_transfer = NULL;
  }
  if (gpu_solid_white_texture) {
    SDL_ReleaseGPUTexture(device, gpu_solid_white_texture);
    gpu_solid_white_texture = NULL;
  }
  gpu_solid_white_failed = false;

  if (gpu_text_sampler) {
    SDL_ReleaseGPUSampler(device, gpu_text_sampler);
    gpu_text_sampler = NULL;
  }
  if (gpu_text_pipeline) {
    SDL_ReleaseGPUGraphicsPipeline(device, gpu_text_pipeline);
    gpu_text_pipeline = NULL;
  }
  if (gpu_text_replace_pipeline) {
    SDL_ReleaseGPUGraphicsPipeline(device, gpu_text_replace_pipeline);
    gpu_text_replace_pipeline = NULL;
  }
  gpu_text_pipeline_failed = false;
}

static bool gpu_ensure_solid_white_texture(SDL_GPUDevice *device, SDL_GPUCommandBuffer *cmd) {
  if (gpu_solid_white_texture)
    return true;
  if (gpu_solid_white_failed || !cmd)
    return false;

  SDL_GPUTextureCreateInfo texture_info;
  SDL_zero(texture_info);
  texture_info.format = SDL_GetGPUTextureFormatFromPixelFormat(SDL_PIXELFORMAT_BGRA32);
  texture_info.usage = SDL_GPU_TEXTUREUSAGE_SAMPLER;
  texture_info.width = 1;
  texture_info.height = 1;
  texture_info.layer_count_or_depth = 1;
  texture_info.num_levels = 1;
  texture_info.sample_count = SDL_GPU_SAMPLECOUNT_1;

  gpu_solid_white_texture = SDL_CreateGPUTexture(device, &texture_info);
  if (!gpu_solid_white_texture) {
    gpu_solid_white_failed = true;
    return false;
  }

  SDL_GPUTransferBufferCreateInfo transfer_info;
  SDL_zero(transfer_info);
  transfer_info.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
  transfer_info.size = 4;
  gpu_solid_white_transfer = SDL_CreateGPUTransferBuffer(device, &transfer_info);
  if (!gpu_solid_white_transfer) {
    SDL_ReleaseGPUTexture(device, gpu_solid_white_texture);
    gpu_solid_white_texture = NULL;
    gpu_solid_white_failed = true;
    return false;
  }

  Uint8 *map = SDL_MapGPUTransferBuffer(device, gpu_solid_white_transfer, true);
  if (!map) {
    SDL_ReleaseGPUTransferBuffer(device, gpu_solid_white_transfer);
    SDL_ReleaseGPUTexture(device, gpu_solid_white_texture);
    gpu_solid_white_transfer = NULL;
    gpu_solid_white_texture = NULL;
    gpu_solid_white_failed = true;
    return false;
  }
  map[0] = 0xff;
  map[1] = 0xff;
  map[2] = 0xff;
  map[3] = 0xff;
  SDL_UnmapGPUTransferBuffer(device, gpu_solid_white_transfer);

  bool submit_upload = gpu_active_frame_device == device && gpu_active_frame_command_buffer == cmd;
  SDL_GPUCommandBuffer *upload_cmd = cmd;
  if (submit_upload) {
    upload_cmd = SDL_AcquireGPUCommandBuffer(device);
    if (!upload_cmd) {
      gpu_solid_white_failed = true;
      return false;
    }
  }

  SDL_GPUCopyPass *copy_pass = SDL_BeginGPUCopyPass(upload_cmd);
  SDL_GPUTextureTransferInfo source;
  SDL_zero(source);
  source.transfer_buffer = gpu_solid_white_transfer;
  source.pixels_per_row = 1;
  source.rows_per_layer = 1;

  SDL_GPUTextureRegion destination;
  SDL_zero(destination);
  destination.texture = gpu_solid_white_texture;
  destination.w = 1;
  destination.h = 1;
  destination.d = 1;
  SDL_UploadToGPUTexture(copy_pass, &source, &destination, true);
  SDL_EndGPUCopyPass(copy_pass);

  if (submit_upload) {
    SDL_GPUFence *fence = SDL_SubmitGPUCommandBufferAndAcquireFence(upload_cmd);
    if (!fence) {
      gpu_solid_white_failed = true;
      return false;
    }
    if (!SDL_WaitForGPUFences(device, true, &fence, 1)) {
      SDL_ReleaseGPUFence(device, fence);
      gpu_solid_white_failed = true;
      return false;
    }
    SDL_ReleaseGPUFence(device, fence);
  }

  return true;
}

static bool gpu_flush_window_native_rects(GpuWindowData *data, SDL_GPUCommandBuffer *cmd) {
  if (!data || data->pending_native_rect_count == 0)
    return true;
  if (!cmd || !data->frame.texture)
    return false;
  if (!gpu_ensure_text_pipeline(data->device))
    return false;
  if (!gpu_ensure_solid_white_texture(data->device, cmd))
    return false;

  SDL_GPUColorTargetInfo color_target;
  SDL_zero(color_target);
  color_target.texture = data->frame.texture;
  color_target.load_op = SDL_GPU_LOADOP_LOAD;
  color_target.store_op = SDL_GPU_STOREOP_STORE;

  SDL_GPURenderPass *pass = SDL_BeginGPURenderPass(cmd, &color_target, 1, NULL);
  SDL_GPUViewport viewport;
  SDL_zero(viewport);
  viewport.w = data->frame.texture_w;
  viewport.h = data->frame.texture_h;
  viewport.max_depth = 1;
  SDL_SetGPUViewport(pass, &viewport);

  SDL_GPUTextureSamplerBinding binding;
  SDL_zero(binding);
  binding.texture = gpu_solid_white_texture;
  binding.sampler = gpu_text_sampler;

  SDL_BindGPUGraphicsPipeline(pass, gpu_text_pipeline);
  SDL_BindGPUFragmentSamplers(pass, 0, &binding, 1);

  for (int i = 0; i < data->pending_native_rect_count; i++) {
    GpuNativeRect *native = &data->pending_native_rects[i];
    if (native->rect.w <= 0 || native->rect.h <= 0)
      continue;

    SDL_SetGPUScissor(pass, &native->rect);

    GpuTextVertexUniforms vertex_uniforms = {
      .dst = { native->rect.x, native->rect.y, native->rect.w, native->rect.h },
      .uv = { 0, 0, 1, 1 },
      .target = { data->frame.texture_w, data->frame.texture_h, 0, 0 },
    };
    GpuTextFragmentUniforms fragment_uniforms = {
      .color = {
        (float) native->color.r / 255.0f,
        (float) native->color.g / 255.0f,
        (float) native->color.b / 255.0f,
        (float) native->color.a / 255.0f,
      },
      .format = EGlyphFormatGrayscale,
    };

    SDL_PushGPUVertexUniformData(cmd, 0, &vertex_uniforms, sizeof(vertex_uniforms));
    SDL_PushGPUFragmentUniformData(cmd, 0, &fragment_uniforms, sizeof(fragment_uniforms));
    SDL_DrawGPUPrimitives(pass, 6, 1, 0, 0);
  }

  SDL_EndGPURenderPass(pass);
  data->pending_native_rect_count = 0;
  data->stats_native_rect_batches++;
  return true;
}

static bool gpu_draw_solid_rect_to_bridge(
  SDL_GPUDevice *device, SDL_GPUCommandBuffer *cmd, GpuFrameBridge *frame,
  SDL_Surface *surface, RenRect rect, RenColor color, bool replace
) {
  if (!device || !cmd || !frame || !surface || rect.width <= 0 || rect.height <= 0)
    return false;

  gpu_ensure_bridge_texture(device, frame, surface->w, surface->h);
  if (!frame->texture)
    return false;
  if (!gpu_ensure_text_pipeline(device))
    return false;
  if (replace && !gpu_ensure_text_replace_pipeline(device))
    return false;
  if (!gpu_ensure_solid_white_texture(device, cmd))
    return false;

  SDL_Rect dst = gpu_pixel_rect_from_ren_rect(surface, rect);
  if (dst.w <= 0 || dst.h <= 0)
    return true;

  SDL_Rect clip;
  if (!SDL_GetSurfaceClipRect(surface, &clip))
    return false;
  if (!SDL_GetRectIntersection(&dst, &clip, &dst) || dst.w <= 0 || dst.h <= 0)
    return true;

  SDL_GPUColorTargetInfo color_target;
  SDL_zero(color_target);
  color_target.texture = frame->texture;
  color_target.load_op = SDL_GPU_LOADOP_LOAD;
  color_target.store_op = SDL_GPU_STOREOP_STORE;

  SDL_GPURenderPass *pass = SDL_BeginGPURenderPass(cmd, &color_target, 1, NULL);

  SDL_GPUViewport viewport;
  SDL_zero(viewport);
  viewport.w = frame->texture_w;
  viewport.h = frame->texture_h;
  viewport.max_depth = 1;
  SDL_SetGPUViewport(pass, &viewport);
  SDL_SetGPUScissor(pass, &dst);

  SDL_GPUTextureSamplerBinding binding;
  SDL_zero(binding);
  binding.texture = gpu_solid_white_texture;
  binding.sampler = gpu_text_sampler;

  GpuTextVertexUniforms vertex_uniforms = {
    .dst = { dst.x, dst.y, dst.w, dst.h },
    .uv = { 0, 0, 1, 1 },
    .target = { frame->texture_w, frame->texture_h, 0, 0 },
  };
  GpuTextFragmentUniforms fragment_uniforms = {
    .color = {
      (float) color.r / 255.0f,
      (float) color.g / 255.0f,
      (float) color.b / 255.0f,
      (float) color.a / 255.0f,
    },
    .format = EGlyphFormatGrayscale,
  };

  SDL_BindGPUGraphicsPipeline(pass, replace ? gpu_text_replace_pipeline : gpu_text_pipeline);
  SDL_PushGPUVertexUniformData(cmd, 0, &vertex_uniforms, sizeof(vertex_uniforms));
  SDL_PushGPUFragmentUniformData(cmd, 0, &fragment_uniforms, sizeof(fragment_uniforms));
  SDL_BindGPUFragmentSamplers(pass, 0, &binding, 1);
  SDL_DrawGPUPrimitives(pass, 6, 1, 0, 0);
  SDL_EndGPURenderPass(pass);
  return true;
}

static bool gpu_upload_pixels_to_bridge(
  SDL_GPUDevice *device, SDL_GPUCommandBuffer *cmd, GpuFrameBridge *frame,
  SDL_Surface *surface, RenRect rect, const char *bytes, size_t len
) {
  if (!device || !cmd || !frame || !surface || !bytes || rect.width <= 0 || rect.height <= 0)
    return false;

  SDL_Rect dst = gpu_pixel_rect_from_ren_rect(surface, rect);
  if (dst.w <= 0 || dst.h <= 0)
    return true;

  SDL_Rect clip;
  if (!SDL_GetSurfaceClipRect(surface, &clip))
    return false;
  if (!SDL_GetRectIntersection(&dst, &clip, &dst) || dst.w <= 0 || dst.h <= 0)
    return true;

  const int bytes_per_pixel = 4;
  const Uint64 source_pitch = (Uint64) rect.width * bytes_per_pixel;
  const Uint64 required = source_pitch * (Uint64) rect.height;
  if ((Uint64) len < required)
    return false;

  gpu_ensure_bridge_texture(device, frame, surface->w, surface->h);
  if (!frame->texture)
    return false;

  Uint32 row_size = (Uint32) dst.w * bytes_per_pixel;
  Uint32 row_stride = gpu_align_u32(row_size, GPU_TEXTURE_ROW_ALIGNMENT);
  Uint32 upload_size = row_stride * (Uint32) dst.h;
  gpu_ensure_bridge_transfer_buffer(device, frame, upload_size);

  Uint8 *map = SDL_MapGPUTransferBuffer(device, frame->transfer, true);
  if (!map)
    return false;

  const int src_x = dst.x - rect.x;
  const int src_y = dst.y - rect.y;
  const Uint8 *src = (const Uint8 *) bytes + (Uint64) src_y * source_pitch + (Uint64) src_x * bytes_per_pixel;
  Uint8 *out = map;
  for (int y = 0; y < dst.h; y++) {
    for (int x = 0; x < dst.w; x++) {
      const Uint8 *p = src + x * bytes_per_pixel;
      Uint8 *q = out + x * bytes_per_pixel;
      if (frame->texture_pixel_format == SDL_PIXELFORMAT_BGRA32) {
        q[0] = p[2];
        q[1] = p[1];
        q[2] = p[0];
        q[3] = p[3];
      } else {
        q[0] = p[0];
        q[1] = p[1];
        q[2] = p[2];
        q[3] = p[3];
      }
    }
    src += source_pitch;
    out += row_stride;
  }
  SDL_UnmapGPUTransferBuffer(device, frame->transfer);

  SDL_GPUCopyPass *copy_pass = SDL_BeginGPUCopyPass(cmd);
  SDL_GPUTextureTransferInfo source_info;
  SDL_zero(source_info);
  source_info.transfer_buffer = frame->transfer;
  source_info.pixels_per_row = row_stride / bytes_per_pixel;
  source_info.rows_per_layer = dst.h;

  SDL_GPUTextureRegion destination;
  SDL_zero(destination);
  destination.texture = frame->texture;
  destination.x = dst.x;
  destination.y = dst.y;
  destination.w = dst.w;
  destination.h = dst.h;
  destination.d = 1;
  SDL_UploadToGPUTexture(copy_pass, &source_info, &destination, false);
  SDL_EndGPUCopyPass(copy_pass);
  return true;
}

static bool gpu_draw_validation_probe(GpuWindowData *data, SDL_GPUCommandBuffer *cmd) {
  if (!data || !cmd || data->validation_probe_pending || data->validation_reported)
    return true;
  if (!data->frame.texture || !data->frame.surface)
    return false;
  if (!gpu_ensure_text_pipeline(data->device))
    return false;
  if (!gpu_ensure_solid_white_texture(data->device, cmd))
    return false;

  SDL_Rect rect = data->validation_text_rect;
  if (rect.w <= 0 || rect.h <= 0)
    rect = (SDL_Rect) { .x = 8, .y = 8, .w = 32, .h = 32 };
  rect.w = SDL_min(rect.w, 32);
  rect.h = SDL_min(rect.h, 32);

  SDL_Rect bounds = { .x = 0, .y = 0, .w = data->frame.surface->w, .h = data->frame.surface->h };
  if (!SDL_GetRectIntersection(&rect, &bounds, &rect) || rect.w <= 0 || rect.h <= 0)
    return false;

  SDL_GPUColorTargetInfo color_target;
  SDL_zero(color_target);
  color_target.texture = data->frame.texture;
  color_target.load_op = SDL_GPU_LOADOP_LOAD;
  color_target.store_op = SDL_GPU_STOREOP_STORE;

  SDL_GPURenderPass *pass = SDL_BeginGPURenderPass(cmd, &color_target, 1, NULL);

  SDL_GPUViewport viewport;
  SDL_zero(viewport);
  viewport.w = data->frame.texture_w;
  viewport.h = data->frame.texture_h;
  viewport.max_depth = 1;
  SDL_SetGPUViewport(pass, &viewport);
  SDL_SetGPUScissor(pass, &rect);

  SDL_GPUTextureSamplerBinding binding;
  SDL_zero(binding);
  binding.texture = gpu_solid_white_texture;
  binding.sampler = gpu_text_sampler;

  GpuTextVertexUniforms vertex_uniforms = {
    .dst = { rect.x, rect.y, rect.w, rect.h },
    .uv = { 0, 0, 1, 1 },
    .target = { data->frame.texture_w, data->frame.texture_h, 0, 0 },
  };
  GpuTextFragmentUniforms fragment_uniforms = {
    .color = { 1.0f, 0.0f, 1.0f, 1.0f },
    .format = EGlyphFormatGrayscale,
  };

  SDL_PushGPUVertexUniformData(cmd, 0, &vertex_uniforms, sizeof(vertex_uniforms));
  SDL_PushGPUFragmentUniformData(cmd, 0, &fragment_uniforms, sizeof(fragment_uniforms));
  SDL_BindGPUGraphicsPipeline(pass, gpu_text_pipeline);
  SDL_BindGPUFragmentSamplers(pass, 0, &binding, 1);
  SDL_DrawGPUPrimitives(pass, 6, 1, 0, 0);
  SDL_EndGPURenderPass(pass);

  data->validation_probe_rect = rect;
  data->validation_probe_pending = true;
  return true;
}

static bool gpu_collect_text_glyph(void *userdata, const RenGlyphDraw *glyph) {
  GpuTextDrawContext *ctx = userdata;
  RenRect glyph_rect = {
    .x = glyph->dst_x,
    .y = glyph->dst_y,
    .width = glyph->width,
    .height = glyph->height,
  };
  if (glyph_rect.width > 0 && glyph_rect.height > 0) {
    if (ctx->have_dirty_rect)
      ctx->dirty_rect = gpu_merge_rects(ctx->dirty_rect, glyph_rect);
    else {
      ctx->dirty_rect = glyph_rect;
      ctx->have_dirty_rect = true;
    }
  }

  if (!ctx->collect_overlay) {
    gpu_abort("SDLGPU native text collection unavailable");
  }

  GpuWindowData *data = ctx->window_data;
  SDL_GPUDevice *device = ctx->device;
  SDL_GPUCommandBuffer *cmd = ctx->command_buffer;
  GpuFrameBridge *frame = ctx->target_frame;
  if (data) {
    device = data->device;
    cmd = data->command_buffer;
    frame = &data->frame;
  }
  if (!device || !cmd || !frame || !frame->texture)
    gpu_abort("SDLGPU native text target unavailable");
  if (!gpu_ensure_text_pipeline(device))
    gpu_abort("SDLGPU native text pipeline unavailable");

  GpuAtlasTexture *texture = gpu_atlas_lookup_texture(glyph->atlas, glyph->metric);
  if (!texture || !texture->texture || texture->texture_w <= 0 || texture->texture_h <= 0)
    gpu_abort("SDLGPU native glyph texture unavailable");

  if (ctx->glyph_count >= ctx->glyph_capacity) {
    int capacity = ctx->glyph_capacity ? ctx->glyph_capacity * 2 : 128;
    GpuQueuedGlyph *glyphs = SDL_realloc(ctx->glyphs, capacity * sizeof(GpuQueuedGlyph));
    if (!glyphs) {
      fprintf(stderr, "Error allocating SDL GPU text glyph batch\n");
      exit(1);
    }
    ctx->glyphs = glyphs;
    ctx->glyph_capacity = capacity;
  }

  ctx->glyphs[ctx->glyph_count++] = (GpuQueuedGlyph) {
    .atlas = glyph->atlas,
    .metric = *glyph->metric,
    .color = glyph->color,
    .dst_x = glyph->dst_x,
    .dst_y = glyph->dst_y,
    .src_x = glyph->src_x,
    .src_y = glyph->src_y,
    .width = glyph->width,
    .height = glyph->height,
    .format = glyph->format,
  };
  ctx->attempted_native = true;
  return true;
}

static bool gpu_check_native_text_glyph(void *userdata, const RenGlyphDraw *glyph) {
  GpuTextNativeCheck *check = userdata;
  if (glyph->format >= EGlyphFormatSize)
    check->native_text = false;
  return true;
}

static bool gpu_queue_text_batch(GpuTextDrawContext *ctx) {
  GpuWindowData *data = ctx->window_data;
  if (!data || !data->command_buffer || !data->frame.texture || ctx->glyph_count == 0)
    return false;
  if (!gpu_ensure_text_pipeline(data->device))
    return false;

  if (data->pending_text_glyph_count + ctx->glyph_count > data->pending_text_glyph_capacity) {
    int capacity = data->pending_text_glyph_capacity ? data->pending_text_glyph_capacity * 2 : 512;
    while (capacity < data->pending_text_glyph_count + ctx->glyph_count)
      capacity *= 2;
    GpuQueuedGlyph *glyphs = SDL_realloc(data->pending_text_glyphs, capacity * sizeof(GpuQueuedGlyph));
    if (!glyphs) {
      fprintf(stderr, "Error allocating SDL GPU pending text glyphs\n");
      exit(1);
    }
    data->pending_text_glyphs = glyphs;
    data->pending_text_glyph_capacity = capacity;
  }

  SDL_memcpy(
    data->pending_text_glyphs + data->pending_text_glyph_count,
    ctx->glyphs,
    ctx->glyph_count * sizeof(GpuQueuedGlyph)
  );
  data->pending_text_glyph_count += ctx->glyph_count;
  data->native_text_used = true;
  return true;
}

static bool gpu_draw_text_glyphs_to_bridge(
  SDL_GPUDevice *device, SDL_GPUCommandBuffer *cmd, GpuFrameBridge *frame,
  SDL_Surface *surface, GpuQueuedGlyph *glyphs, int glyph_count
) {
  if (!device || !cmd || !frame || !surface || glyph_count == 0)
    return true;
  if (!frame->texture)
    return false;
  if (!gpu_ensure_text_pipeline(device))
    return false;

  SDL_Rect clip;
  if (!SDL_GetSurfaceClipRect(surface, &clip))
    return false;

  SDL_GPUColorTargetInfo color_target;
  SDL_zero(color_target);
  color_target.texture = frame->texture;
  color_target.load_op = SDL_GPU_LOADOP_LOAD;
  color_target.store_op = SDL_GPU_STOREOP_STORE;

  SDL_GPUViewport viewport;
  SDL_zero(viewport);
  viewport.w = frame->texture_w;
  viewport.h = frame->texture_h;
  viewport.max_depth = 1;

  SDL_GPURenderPass *pass = SDL_BeginGPURenderPass(cmd, &color_target, 1, NULL);
  SDL_SetGPUViewport(pass, &viewport);
  SDL_BindGPUGraphicsPipeline(pass, gpu_text_pipeline);

  for (int i = 0; i < glyph_count; i++) {
    GpuQueuedGlyph *glyph = &glyphs[i];
    GpuAtlasTexture *texture = gpu_atlas_lookup_texture(glyph->atlas, &glyph->metric);
    if (!texture || !texture->texture || texture->texture_w <= 0 || texture->texture_h <= 0)
      continue;

    SDL_Rect scissor = {
      .x = glyph->dst_x,
      .y = glyph->dst_y,
      .w = glyph->width,
      .h = glyph->height,
    };
    if (!SDL_GetRectIntersection(&scissor, &clip, &scissor) || scissor.w <= 0 || scissor.h <= 0)
      continue;

    SDL_GPUTextureSamplerBinding binding;
    SDL_zero(binding);
    binding.texture = texture->texture;
    binding.sampler = gpu_text_sampler;

    int src_y = glyph->src_y - (int) glyph->metric.y0;
    if (src_y < 0)
      src_y = 0;

    GpuTextVertexUniforms vertex_uniforms = {
      .dst = { glyph->dst_x, glyph->dst_y, glyph->width, glyph->height },
      .uv = {
        (float) glyph->src_x / texture->texture_w,
        (float) src_y / texture->texture_h,
        (float) glyph->width / texture->texture_w,
        (float) glyph->height / texture->texture_h,
      },
      .target = { frame->texture_w, frame->texture_h, 0, 0 },
    };
    GpuTextFragmentUniforms fragment_uniforms = {
      .color = {
        (float) glyph->color.r / 255.0f,
        (float) glyph->color.g / 255.0f,
        (float) glyph->color.b / 255.0f,
        (float) glyph->color.a / 255.0f,
      },
      .format = glyph->format,
    };

    SDL_SetGPUScissor(pass, &scissor);
    SDL_PushGPUVertexUniformData(cmd, 0, &vertex_uniforms, sizeof(vertex_uniforms));
    SDL_PushGPUFragmentUniformData(cmd, 0, &fragment_uniforms, sizeof(fragment_uniforms));
    SDL_BindGPUFragmentSamplers(pass, 0, &binding, 1);
    SDL_DrawGPUPrimitives(pass, 6, 1, 0, 0);
  }

  SDL_EndGPURenderPass(pass);
  return true;
}

static bool gpu_flush_queued_text(
  GpuWindowData *data,
  SDL_GPUCommandBuffer *cmd,
  UNUSED const RenRect *uploaded_cpu_rects,
  UNUSED int uploaded_cpu_count,
  UNUSED bool uploaded_cpu_full
) {
  if (!data || !cmd || !data->frame.texture || data->pending_text_glyph_count == 0)
    return true;
  if (!gpu_ensure_text_pipeline(data->device))
    return false;

  SDL_GPUColorTargetInfo color_target;
  SDL_zero(color_target);
  color_target.texture = data->frame.texture;
  color_target.load_op = SDL_GPU_LOADOP_LOAD;
  color_target.store_op = SDL_GPU_STOREOP_STORE;

  SDL_GPUViewport viewport;
  SDL_zero(viewport);
  viewport.w = data->frame.texture_w;
  viewport.h = data->frame.texture_h;
  viewport.max_depth = 1;

  SDL_GPURenderPass *pass = SDL_BeginGPURenderPass(cmd, &color_target, 1, NULL);
  SDL_SetGPUViewport(pass, &viewport);
  SDL_BindGPUGraphicsPipeline(pass, gpu_text_pipeline);

  SDL_Rect validation_rect = {0};
  bool have_validation_rect = false;

  for (int i = 0; i < data->pending_text_glyph_count; i++) {
    GpuQueuedGlyph *glyph = &data->pending_text_glyphs[i];
    GpuAtlasTexture *texture = gpu_atlas_lookup_texture(glyph->atlas, &glyph->metric);
    if (!texture || !texture->texture || texture->texture_w <= 0 || texture->texture_h <= 0)
      continue;

    SDL_Rect scissor = {
      .x = glyph->dst_x,
      .y = glyph->dst_y,
      .w = glyph->width,
      .h = glyph->height,
    };
    if (gpu_validate_text_enabled()) {
      if (have_validation_rect)
        SDL_GetRectUnion(&validation_rect, &scissor, &validation_rect);
      else {
        validation_rect = scissor;
        have_validation_rect = true;
      }
    }

    SDL_GPUTextureSamplerBinding binding;
    SDL_zero(binding);
    binding.texture = texture->texture;
    binding.sampler = gpu_text_sampler;

    int src_y = glyph->src_y - (int) glyph->metric.y0;
    if (src_y < 0)
      src_y = 0;

    GpuTextVertexUniforms vertex_uniforms = {
      .dst = { glyph->dst_x, glyph->dst_y, glyph->width, glyph->height },
      .uv = {
        (float) glyph->src_x / texture->texture_w,
        (float) src_y / texture->texture_h,
        (float) glyph->width / texture->texture_w,
        (float) glyph->height / texture->texture_h,
      },
      .target = { data->frame.texture_w, data->frame.texture_h, 0, 0 },
    };
    GpuTextFragmentUniforms fragment_uniforms = {
      .color = {
        (float) glyph->color.r / 255.0f,
        (float) glyph->color.g / 255.0f,
        (float) glyph->color.b / 255.0f,
        (float) glyph->color.a / 255.0f,
      },
      .format = glyph->format,
    };

    SDL_SetGPUScissor(pass, &scissor);
    SDL_PushGPUVertexUniformData(cmd, 0, &vertex_uniforms, sizeof(vertex_uniforms));
    SDL_PushGPUFragmentUniformData(cmd, 0, &fragment_uniforms, sizeof(fragment_uniforms));
    SDL_BindGPUFragmentSamplers(pass, 0, &binding, 1);
    SDL_DrawGPUPrimitives(pass, 6, 1, 0, 0);
  }

  SDL_EndGPURenderPass(pass);

  data->frame_synced_during_replay = true;
  data->pending_text_glyph_count = 0;
  if (!have_validation_rect)
    data->native_text_used = false;
  if (have_validation_rect && !data->validation_reported) {
    if (data->validation_text_pending)
      SDL_GetRectUnion(&data->validation_text_rect, &validation_rect, &data->validation_text_rect);
    else {
      data->validation_text_rect = validation_rect;
      data->validation_text_pending = true;
    }
  }
  return true;
}

static bool gpu_blit_texture_to_bridge(
  SDL_GPUDevice *device,
  SDL_GPUCommandBuffer *cmd,
  GpuFrameBridge *dst,
  GpuFrameBridge *src,
  int x,
  int y,
  SDL_BlendMode blend_mode,
  bool cycle_destination
) {
  if (!device || !cmd)
    return false;
  if (!dst->texture || !dst->surface || !src->texture || !src->surface)
    return false;

  SDL_Rect clip;
  if (!SDL_GetSurfaceClipRect(dst->surface, &clip))
    return false;

  int x1 = SDL_max(x, clip.x);
  int y1 = SDL_max(y, clip.y);
  int x2 = SDL_min(x + src->surface->w, clip.x + clip.w);
  int y2 = SDL_min(y + src->surface->h, clip.y + clip.h);
  x1 = SDL_clamp(x1, 0, dst->surface->w);
  y1 = SDL_clamp(y1, 0, dst->surface->h);
  x2 = SDL_clamp(x2, 0, dst->surface->w);
  y2 = SDL_clamp(y2, 0, dst->surface->h);
  if (x2 <= x1 || y2 <= y1)
    return true;

  if (blend_mode != SDL_BLENDMODE_BLEND && blend_mode != SDL_BLENDMODE_NONE)
    return false;

  SDL_GPUTextureFormat target_format = SDL_GetGPUTextureFormatFromPixelFormat(dst->texture_pixel_format);
  if (target_format == SDL_GPU_TEXTUREFORMAT_INVALID)
    return false;

  if (!gpu_ensure_canvas_pipeline(device))
    return false;

  SDL_GPUGraphicsPipeline *replace_pipeline = NULL;
  SDL_GPUGraphicsPipeline *pipeline = gpu_canvas_blend_pipeline;
  if (blend_mode == SDL_BLENDMODE_NONE) {
    replace_pipeline = gpu_create_canvas_graphics_pipeline(
      device,
      target_format,
      false
    );
    if (!replace_pipeline)
      return false;
    pipeline = replace_pipeline;
  }

  SDL_GPUColorTargetInfo color_target;
  SDL_zero(color_target);
  color_target.texture = dst->texture;
  color_target.load_op = SDL_GPU_LOADOP_LOAD;
  color_target.store_op = SDL_GPU_STOREOP_STORE;
  color_target.cycle = cycle_destination;

  SDL_GPURenderPass *pass = SDL_BeginGPURenderPass(cmd, &color_target, 1, NULL);

  SDL_GPUViewport viewport;
  SDL_zero(viewport);
  viewport.w = dst->texture_w;
  viewport.h = dst->texture_h;
  viewport.max_depth = 1;
  SDL_SetGPUViewport(pass, &viewport);

  SDL_Rect scissor = { .x = x1, .y = y1, .w = x2 - x1, .h = y2 - y1 };
  SDL_SetGPUScissor(pass, &scissor);

  SDL_GPUTextureSamplerBinding binding;
  SDL_zero(binding);
  binding.texture = src->texture;
  binding.sampler = gpu_canvas_sampler;

  GpuTextVertexUniforms vertex_uniforms = {
    .dst = { x1, y1, x2 - x1, y2 - y1 },
    .uv = {
      (float) (x1 - x) / (float) src->texture_w,
      (float) (y1 - y) / (float) src->texture_h,
      (float) (x2 - x1) / (float) src->texture_w,
      (float) (y2 - y1) / (float) src->texture_h,
    },
    .target = { dst->texture_w, dst->texture_h, 0, 0 },
  };

  SDL_BindGPUGraphicsPipeline(pass, pipeline);
  SDL_PushGPUVertexUniformData(cmd, 0, &vertex_uniforms, sizeof(vertex_uniforms));
  SDL_BindGPUFragmentSamplers(pass, 0, &binding, 1);
  SDL_DrawGPUPrimitives(pass, 6, 1, 0, 0);
  SDL_EndGPURenderPass(pass);
  if (replace_pipeline)
    SDL_ReleaseGPUGraphicsPipeline(device, replace_pipeline);
  return true;
}

static bool gpu_blit_canvas_texture_to_frame(
  GpuWindowData *window_data, GpuCanvasData *canvas_data, int x, int y, SDL_BlendMode blend_mode
) {
  GpuFrameBridge *dst = &window_data->frame;
  GpuFrameBridge *src = &canvas_data->frame;
  if (!window_data->command_buffer) {
    window_data->stats_native_canvas_missing_state++;
    return false;
  }
  if (!dst->texture || !dst->surface || !src->texture || !src->surface) {
    window_data->stats_native_canvas_missing_state++;
    return false;
  }

  SDL_Rect clip;
  if (!SDL_GetSurfaceClipRect(dst->surface, &clip)) {
    window_data->stats_native_canvas_clip_rejects++;
    return false;
  }

  int x1 = SDL_max(x, clip.x);
  int y1 = SDL_max(y, clip.y);
  int x2 = SDL_min(x + src->surface->w, clip.x + clip.w);
  int y2 = SDL_min(y + src->surface->h, clip.y + clip.h);
  x1 = SDL_clamp(x1, 0, dst->surface->w);
  y1 = SDL_clamp(y1, 0, dst->surface->h);
  x2 = SDL_clamp(x2, 0, dst->surface->w);
  y2 = SDL_clamp(y2, 0, dst->surface->h);
  if (x2 <= x1 || y2 <= y1) {
    window_data->stats_native_canvas_clip_rejects++;
    return true;
  }

  if (!gpu_blit_texture_to_bridge(
        window_data->device,
        window_data->command_buffer,
        dst,
        src,
        x,
        y,
        blend_mode,
        false
      ))
    return false;

  window_data->frame_synced_during_replay = true;
  window_data->sampled_canvas_this_frame = true;
  window_data->stats_native_canvas_texture_draws++;
  return true;
}

static void gpu_ensure_validation_transfer(GpuWindowData *data, Uint32 size) {
  if (data->validation_transfer && data->validation_transfer_size >= size)
    return;

  if (data->validation_transfer)
    SDL_ReleaseGPUTransferBuffer(data->device, data->validation_transfer);

  SDL_GPUTransferBufferCreateInfo createinfo;
  SDL_zero(createinfo);
  createinfo.usage = SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
  createinfo.size = size;

  data->validation_transfer = SDL_CreateGPUTransferBuffer(data->device, &createinfo);
  if (!data->validation_transfer)
    gpu_abort("SDL_CreateGPUTransferBuffer failed");

  data->validation_transfer_size = size;
}

static bool gpu_queue_native_text_validation_download(
  GpuWindowData *data,
  SDL_GPUCommandBuffer *cmd,
  SDL_GPUTexture *source_texture,
  Uint32 source_w,
  Uint32 source_h,
  Uint32 *row_stride
) {
  if (!data || !cmd || data->validation_reported)
    return false;
  if (!source_texture || !source_w || !source_h)
    return false;

  if (data->validation_text_pending && gpu_env_flag("PRAGTICAL_SDLGPU_VALIDATE_PROBE", true))
    gpu_draw_validation_probe(data, cmd);

  SDL_Rect bounds = {
    .x = 0,
    .y = 0,
    .w = source_w,
    .h = source_h,
  };
  SDL_Rect rect = {0};
  bool have_rect = false;
  if (!SDL_GetRectIntersection(&data->validation_text_rect, &bounds, &rect) || rect.w <= 0 || rect.h <= 0)
    SDL_zero(rect);
  else
    have_rect = true;

  if (data->validation_probe_pending) {
    SDL_Rect probe_rect;
    if (SDL_GetRectIntersection(&data->validation_probe_rect, &bounds, &probe_rect) && probe_rect.w > 0 && probe_rect.h > 0) {
      if (have_rect)
        SDL_GetRectUnion(&rect, &probe_rect, &rect);
      else {
        rect = probe_rect;
        have_rect = true;
      }
    }
  }

  if (!have_rect)
    return false;

  data->validation_text_rect = rect;
  *row_stride = gpu_align_u32((Uint32) rect.w * 4, GPU_TEXTURE_ROW_ALIGNMENT);
  gpu_ensure_validation_transfer(data, *row_stride * rect.h);

  SDL_GPUCopyPass *copy_pass = SDL_BeginGPUCopyPass(cmd);
  SDL_GPUTextureRegion source;
  SDL_zero(source);
  source.texture = source_texture;
  source.x = rect.x;
  source.y = rect.y;
  source.w = rect.w;
  source.h = rect.h;
  source.d = 1;

  SDL_GPUTextureTransferInfo destination;
  SDL_zero(destination);
  destination.transfer_buffer = data->validation_transfer;
  destination.pixels_per_row = *row_stride / 4;
  destination.rows_per_layer = rect.h;
  SDL_DownloadFromGPUTexture(copy_pass, &source, &destination);
  SDL_EndGPUCopyPass(copy_pass);
  return true;
}

static void gpu_report_native_text_validation(GpuWindowData *data, Uint32 row_stride) {
  if (!data || !data->validation_transfer || data->validation_reported)
    return;

  SDL_Rect rect = data->validation_text_rect;
  SDL_Surface *surface = data->frame.surface;
  if (!surface || rect.w <= 0 || rect.h <= 0)
    return;

  const Uint8 *gpu_pixels = SDL_MapGPUTransferBuffer(data->device, data->validation_transfer, false);
  if (!gpu_pixels) {
    fprintf(stderr, "sdlgpu native text validation: FAIL map_error=%s\n", SDL_GetError());
    data->validation_reported = true;
    return;
  }

  const int bpp = SDL_BYTESPERPIXEL(surface->format);
  int text_changed = 0;
  int text_sampled = 0;
  int probe_changed = 0;
  int probe_sampled = 0;
  for (int y = 0; y < rect.h; y++) {
    const Uint8 *gpu_row = gpu_pixels + y * row_stride;
    const Uint8 *cpu_row = (const Uint8 *) surface->pixels + (rect.y + y) * surface->pitch + rect.x * bpp;
    for (int x = 0; x < rect.w; x++) {
      int px = rect.x + x;
      int py = rect.y + y;
      const Uint8 *g = gpu_row + x * 4;
      const Uint8 *c = cpu_row + x * bpp;
      int diff = abs((int) g[0] - (int) c[0])
               + abs((int) g[1] - (int) c[1])
               + abs((int) g[2] - (int) c[2])
               + abs((int) g[3] - (int) c[3]);
      bool in_probe = data->validation_probe_pending
        && px >= data->validation_probe_rect.x
        && py >= data->validation_probe_rect.y
        && px < data->validation_probe_rect.x + data->validation_probe_rect.w
        && py < data->validation_probe_rect.y + data->validation_probe_rect.h;
      if (in_probe) {
        if (diff > 24)
          probe_changed++;
        probe_sampled++;
      } else {
        if (diff > 24)
          text_changed++;
        text_sampled++;
      }
    }
  }

  SDL_UnmapGPUTransferBuffer(data->device, data->validation_transfer);
  fprintf(
    stderr,
    "sdlgpu native text validation: %s rect=%d,%d %dx%d text_changed=%d/%d probe_changed=%d/%d\n",
    text_changed > 0 ? "PASS" : "FAIL",
    rect.x, rect.y, rect.w, rect.h,
    text_changed, text_sampled,
    probe_changed, probe_sampled
  );
  data->validation_reported = true;
  data->validation_text_pending = false;
  data->validation_probe_pending = false;
}

static SDL_Surface *gpu_capture_window(RenCache *cache, RenRect rect) {
  if (!cache->window_target)
    return NULL;

  RenWindow *ren = cache->target;
  GpuWindowData *data = ren->backend_data;
  if (!data || !data->device || !data->frame.surface || !data->frame.texture || data->command_buffer)
    return NULL;

  rect = gpu_clip_surface_rect(data->frame.surface, rect);
  if (rect.width <= 0 || rect.height <= 0)
    return NULL;

  Uint32 row_size = (Uint32) rect.width * 4;
  Uint32 row_stride = gpu_align_u32(row_size, GPU_TEXTURE_ROW_ALIGNMENT);
  Uint32 download_size = row_stride * (Uint32) rect.height;

  SDL_GPUTransferBufferCreateInfo transfer_info;
  SDL_zero(transfer_info);
  transfer_info.usage = SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
  transfer_info.size = download_size;
  SDL_GPUTransferBuffer *download = SDL_CreateGPUTransferBuffer(data->device, &transfer_info);
  if (!download)
    return NULL;

  SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(data->device);
  if (!cmd) {
    SDL_ReleaseGPUTransferBuffer(data->device, download);
    return NULL;
  }

  SDL_GPUCopyPass *copy_pass = SDL_BeginGPUCopyPass(cmd);
  SDL_GPUTextureRegion source;
  SDL_zero(source);
  source.texture = data->frame.texture;
  source.x = rect.x;
  source.y = rect.y;
  source.w = rect.width;
  source.h = rect.height;
  source.d = 1;

  SDL_GPUTextureTransferInfo destination;
  SDL_zero(destination);
  destination.transfer_buffer = download;
  destination.pixels_per_row = row_stride / 4;
  destination.rows_per_layer = rect.height;
  SDL_DownloadFromGPUTexture(copy_pass, &source, &destination);
  SDL_EndGPUCopyPass(copy_pass);

  SDL_GPUFence *fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
  if (!fence) {
    SDL_ReleaseGPUTransferBuffer(data->device, download);
    return NULL;
  }
  SDL_WaitForGPUFences(data->device, true, &fence, 1);
  SDL_ReleaseGPUFence(data->device, fence);

  SDL_Surface *surface = SDL_CreateSurface(rect.width, rect.height, SDL_PIXELFORMAT_BGRA32);
  if (!surface) {
    SDL_ReleaseGPUTransferBuffer(data->device, download);
    return NULL;
  }

  const Uint8 *src = SDL_MapGPUTransferBuffer(data->device, download, false);
  if (!src) {
    SDL_DestroySurface(surface);
    SDL_ReleaseGPUTransferBuffer(data->device, download);
    return NULL;
  }

  if (!SDL_LockSurface(surface)) {
    SDL_UnmapGPUTransferBuffer(data->device, download);
    SDL_DestroySurface(surface);
    SDL_ReleaseGPUTransferBuffer(data->device, download);
    return NULL;
  }

  Uint8 *dst = surface->pixels;
  for (int y = 0; y < rect.height; y++) {
    SDL_memcpy(dst, src, row_size);
    src += row_stride;
    dst += surface->pitch;
  }
  SDL_UnlockSurface(surface);
  SDL_UnmapGPUTransferBuffer(data->device, download);
  SDL_ReleaseGPUTransferBuffer(data->device, download);
  return surface;
}

static bool gpu_download_bridge_texture_to_surface(SDL_GPUDevice *device, GpuFrameBridge *frame) {
  if (!device || !frame->texture || !frame->surface)
    return false;

  const int bytes_per_pixel = SDL_BYTESPERPIXEL(frame->surface->format);
  if (bytes_per_pixel <= 0)
    return false;

  Uint32 row_size = (Uint32) frame->surface->w * bytes_per_pixel;
  Uint32 row_stride = gpu_align_u32(row_size, GPU_TEXTURE_ROW_ALIGNMENT);
  Uint32 download_size = row_stride * (Uint32) frame->surface->h;

  SDL_GPUTransferBufferCreateInfo transfer_info;
  SDL_zero(transfer_info);
  transfer_info.usage = SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
  transfer_info.size = download_size;
  SDL_GPUTransferBuffer *download = SDL_CreateGPUTransferBuffer(device, &transfer_info);
  if (!download)
    return false;

  SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(device);
  if (!cmd) {
    SDL_ReleaseGPUTransferBuffer(device, download);
    return false;
  }

  SDL_GPUCopyPass *copy_pass = SDL_BeginGPUCopyPass(cmd);
  SDL_GPUTextureRegion source;
  SDL_zero(source);
  source.texture = frame->texture;
  source.w = frame->surface->w;
  source.h = frame->surface->h;
  source.d = 1;

  SDL_GPUTextureTransferInfo destination;
  SDL_zero(destination);
  destination.transfer_buffer = download;
  destination.pixels_per_row = row_stride / bytes_per_pixel;
  destination.rows_per_layer = frame->surface->h;
  SDL_DownloadFromGPUTexture(copy_pass, &source, &destination);
  SDL_EndGPUCopyPass(copy_pass);

  SDL_GPUFence *fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
  if (!fence) {
    SDL_ReleaseGPUTransferBuffer(device, download);
    return false;
  }
  bool waited = SDL_WaitForGPUFences(device, true, &fence, 1);
  SDL_ReleaseGPUFence(device, fence);
  if (!waited) {
    SDL_ReleaseGPUTransferBuffer(device, download);
    return false;
  }

  const Uint8 *src = SDL_MapGPUTransferBuffer(device, download, false);
  if (!src) {
    SDL_ReleaseGPUTransferBuffer(device, download);
    return false;
  }

  if (!SDL_LockSurface(frame->surface)) {
    SDL_UnmapGPUTransferBuffer(device, download);
    SDL_ReleaseGPUTransferBuffer(device, download);
    return false;
  }

  Uint8 *dst = frame->surface->pixels;
  for (int y = 0; y < frame->surface->h; y++) {
    SDL_memcpy(dst, src, row_size);
    src += row_stride;
    dst += frame->surface->pitch;
  }
  SDL_UnlockSurface(frame->surface);
  SDL_UnmapGPUTransferBuffer(device, download);
  SDL_ReleaseGPUTransferBuffer(device, download);
  return true;
}

static SDL_GPUDevice *gpu_get_device(void) {
  if (!gpu_device) {
    gpu_device = SDL_CreateGPUDevice(GPU_SUPPORTED_SHADER_FORMATS, false, NULL);
    if (!gpu_device)
      gpu_abort("SDL_CreateGPUDevice failed");
  }
  return gpu_device;
}

static SDL_GPUDevice *gpu_retain_device(void) {
  SDL_GPUDevice *device = gpu_get_device();
  gpu_device_ref_count++;
  return device;
}

static void gpu_release_device(void) {
  if (gpu_device_ref_count > 0)
    gpu_device_ref_count--;
  if (gpu_device_ref_count == 0 && gpu_device) {
    gpu_destroy_canvas_pipeline(gpu_device);
    gpu_destroy_poly_pipeline(gpu_device);
    gpu_destroy_text_pipeline(gpu_device);
    SDL_DestroyGPUDevice(gpu_device);
    gpu_device = NULL;
  }
}

static void gpu_init_window(RenWindow *ren) {
  GpuWindowData *data = gpu_window_data(ren);
  data->device = gpu_retain_device();
  if (!SDL_ClaimWindowForGPUDevice(data->device, ren->window))
    gpu_abort("SDL_ClaimWindowForGPUDevice failed");
  if (SDL_WindowSupportsGPUPresentMode(data->device, ren->window, SDL_GPU_PRESENTMODE_IMMEDIATE)) {
    SDL_SetGPUSwapchainParameters(
      data->device, ren->window, SDL_GPU_SWAPCHAINCOMPOSITION_SDR, SDL_GPU_PRESENTMODE_IMMEDIATE
    );
  } else if (SDL_WindowSupportsGPUPresentMode(data->device, ren->window, SDL_GPU_PRESENTMODE_MAILBOX)) {
    SDL_SetGPUSwapchainParameters(
      data->device, ren->window, SDL_GPU_SWAPCHAINCOMPOSITION_SDR, SDL_GPU_PRESENTMODE_MAILBOX
    );
  }
  gpu_create_surface(ren);
}

static void gpu_resize_window(RenWindow *ren) {
  GpuWindowData *data = gpu_window_data(ren);
  int w, h;
  SDL_GetWindowSizeInPixels(ren->window, &w, &h);
  if (w < 1) w = 1;
  if (h < 1) h = 1;

  float scale_x, scale_y;
  gpu_query_surface_scale(ren, &scale_x, &scale_y);
  if (!data->frame.surface ||
      data->frame.surface->w != w ||
      data->frame.surface->h != h ||
      ren->cache.rensurface.scale_x != scale_x ||
      ren->cache.rensurface.scale_y != scale_y) {
    gpu_create_surface(ren);
    renwin_clip_to_surface(ren);
  }
}

static void gpu_destroy_window(RenWindow *ren) {
  GpuWindowData *data = ren->backend_data;
  if (data) {
    gpu_print_stats(data);
    if (data->command_buffer) {
      if (gpu_active_frame_command_buffer == data->command_buffer) {
        gpu_active_frame_command_buffer = NULL;
        gpu_active_frame_device = NULL;
        gpu_active_frame_window_data = NULL;
      }
      SDL_CancelGPUCommandBuffer(data->command_buffer);
      data->command_buffer = NULL;
    }
    if (data->validation_transfer) {
      SDL_ReleaseGPUTransferBuffer(data->device, data->validation_transfer);
      data->validation_transfer = NULL;
      data->validation_transfer_size = 0;
    }
    if (data->pixels_texture) {
      SDL_ReleaseGPUTexture(data->device, data->pixels_texture);
      data->pixels_texture = NULL;
      data->pixels_texture_w = 0;
      data->pixels_texture_h = 0;
    }
    if (data->pixels_transfer) {
      SDL_ReleaseGPUTransferBuffer(data->device, data->pixels_transfer);
      data->pixels_transfer = NULL;
      data->pixels_transfer_size = 0;
    }
    SDL_free(data->pending_text_glyphs);
    data->pending_text_glyphs = NULL;
    data->pending_text_glyph_count = 0;
    data->pending_text_glyph_capacity = 0;
    gpu_destroy_bridge_resources(data->device, &data->frame);
    if (data->device) {
      SDL_ReleaseWindowFromGPUDevice(data->device, ren->window);
      gpu_release_device();
      data->device = NULL;
    }
    gpu_destroy_surface(data);
    ren->cache.rensurface.surface = NULL;
  }
  SDL_free(ren->backend_data);
  ren->backend_data = NULL;
}

static RenSurface gpu_get_window_surface(RenCache *cache) {
  return cache->rensurface;
}

static void gpu_clear_frame_texture(GpuWindowData *data) {
  if (!data || !data->command_buffer || !data->frame.texture)
    return;

  SDL_GPUColorTargetInfo color_target;
  SDL_zero(color_target);
  color_target.texture = data->frame.texture;
  color_target.clear_color = (SDL_FColor) { 0, 0, 0, 1 };
  color_target.load_op = SDL_GPU_LOADOP_CLEAR;
  color_target.store_op = SDL_GPU_STOREOP_STORE;
  SDL_GPURenderPass *pass = SDL_BeginGPURenderPass(data->command_buffer, &color_target, 1, NULL);
  SDL_EndGPURenderPass(pass);
  data->frame.needs_full_upload = false;
  data->frame.dirty_count = 0;
  data->frame_synced_during_replay = true;
}

static void gpu_begin_frame(RenCache *cache, UNUSED RenRect *rects, UNUSED int count) {
  if (!cache->window_target)
    return;

  RenWindow *ren = cache->target;
  GpuWindowData *data = ren->backend_data;
  GpuFrameBridge *frame = &data->frame;
  if (frame->surface)
    gpu_ensure_bridge_texture(data->device, frame, frame->surface->w, frame->surface->h);

  data->pending_native_rect_count = 0;
  data->pending_text_glyph_count = 0;
  data->native_region = false;
  data->frame_synced_during_replay = false;
  data->native_text_used = false;
  data->sampled_canvas_this_frame = false;

  if (data->command_buffer) {
    gpu_active_frame_device = data->device;
    gpu_active_frame_command_buffer = data->command_buffer;
    gpu_active_frame_window_data = data;
    if (data->frame.needs_full_upload)
      gpu_clear_frame_texture(data);
    return;
  }

  data->command_buffer = SDL_AcquireGPUCommandBuffer(data->device);
  if (!data->command_buffer)
    gpu_abort("SDL_AcquireGPUCommandBuffer failed");

  gpu_active_frame_device = data->device;
  gpu_active_frame_command_buffer = data->command_buffer;
  gpu_active_frame_window_data = data;
  if (data->frame.needs_full_upload)
    gpu_clear_frame_texture(data);
}

static void gpu_end_frame(UNUSED RenCache *cache, UNUSED RenRect *rects, UNUSED int count) {
}

static void gpu_begin_region(RenCache *cache, UNUSED RenRect rect, bool native_only) {
  if (!cache->window_target)
    return;

  RenWindow *ren = cache->target;
  GpuWindowData *data = ren->backend_data;
  if (data)
    data->native_region = gpu_direct_replay_enabled() && native_only;
}

static void gpu_end_region(RenCache *cache, UNUSED RenRect rect, UNUSED bool native_only) {
  if (!cache->window_target)
    return;

  RenWindow *ren = cache->target;
  GpuWindowData *data = ren->backend_data;
  if (data)
    data->native_region = false;
}

static void gpu_blit_frame_to_swapchain(
  GpuWindowData *data,
  SDL_GPUCommandBuffer *cmd,
  SDL_GPUTexture *swapchain_texture,
  Uint32 swapchain_width,
  Uint32 swapchain_height
) {
  GpuFrameBridge *frame = &data->frame;
  SDL_GPUBlitInfo blit_info;
  SDL_zero(blit_info);
  blit_info.source.texture = frame->texture;
  blit_info.source.w = frame->texture_w;
  blit_info.source.h = frame->texture_h;
  blit_info.destination.texture = swapchain_texture;
  blit_info.destination.w = swapchain_width;
  blit_info.destination.h = swapchain_height;
  blit_info.load_op = SDL_GPU_LOADOP_DONT_CARE;
  blit_info.filter = SDL_GPU_FILTER_LINEAR;
  SDL_BlitGPUTexture(cmd, &blit_info);
}

static void gpu_present_window_rects(RenCache *cache, UNUSED RenRect *rects, UNUSED int count) {
  RenWindow *ren = cache->target;
  GpuWindowData *data = ren->backend_data;
  SDL_GPUCommandBuffer *cmd = data->command_buffer;
  if (!cmd) {
    cmd = SDL_AcquireGPUCommandBuffer(data->device);
    if (!cmd)
      gpu_abort("SDL_AcquireGPUCommandBuffer failed");
  }
  data->command_buffer = NULL;
  if (gpu_active_frame_command_buffer == cmd) {
    gpu_active_frame_command_buffer = NULL;
    gpu_active_frame_device = NULL;
    gpu_active_frame_window_data = NULL;
  }

  SDL_GPUTexture *swapchain_texture = NULL;
  Uint32 swapchain_width = 0, swapchain_height = 0;
  if (!SDL_WaitAndAcquireGPUSwapchainTexture(cmd, ren->window, &swapchain_texture, &swapchain_width, &swapchain_height)) {
    SDL_CancelGPUCommandBuffer(cmd);
    gpu_abort("SDL_WaitAndAcquireGPUSwapchainTexture failed");
  }

  if (!gpu_flush_window_native_rects(data, cmd))
    gpu_abort("SDLGPU native rect flush failed");
  if (!gpu_flush_queued_text(data, cmd, NULL, 0, false))
    gpu_abort("SDLGPU native text flush failed");

  if (swapchain_texture)
    gpu_blit_frame_to_swapchain(data, cmd, swapchain_texture, swapchain_width, swapchain_height);
  data->stats_frames++;

  Uint32 validation_row_stride = 0;
  bool validate_text = gpu_queue_native_text_validation_download(
    data,
    cmd,
    data->frame.texture,
    data->frame.texture_w,
    data->frame.texture_h,
    &validation_row_stride
  );
  if (validate_text || data->native_text_used || data->sampled_canvas_this_frame || !swapchain_texture) {
    SDL_GPUFence *fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
    if (!fence)
      gpu_abort("SDL_SubmitGPUCommandBufferAndAcquireFence failed");
    if (!SDL_WaitForGPUFences(data->device, true, &fence, 1))
      gpu_abort("SDL_WaitForGPUFences failed");
    if (validate_text)
      gpu_report_native_text_validation(data, validation_row_stride);
    SDL_ReleaseGPUFence(data->device, fence);
  } else if (!SDL_SubmitGPUCommandBuffer(cmd)) {
    gpu_abort("SDL_SubmitGPUCommandBuffer failed");
  }

  if (!ren->shown) {
    SDL_ShowWindow(ren->window);
    ren->shown = true;
  }
}

static void gpu_init_canvas(RenCache *canvas, SDL_Surface *surface) {
  bool source_has_alpha = SDL_ISPIXELFORMAT_ALPHA(surface->format);
  SDL_GPUTextureFormat texture_format = SDL_GetGPUTextureFormatFromPixelFormat(surface->format);
  if (texture_format == SDL_GPU_TEXTUREFORMAT_INVALID ||
      surface->format != SDL_PIXELFORMAT_BGRA32 ||
      !source_has_alpha) {
    SDL_Surface *converted = SDL_ConvertSurface(surface, SDL_PIXELFORMAT_BGRA32);
    if (converted) {
      SDL_DestroySurface(surface);
      surface = converted;
      if (!source_has_alpha)
        gpu_force_surface_alpha_opaque(surface);
    }
  }

  GpuCanvasData *data = SDL_calloc(1, sizeof(GpuCanvasData));
  if (!data) {
    fprintf(stderr, "Error allocating SDL GPU canvas data\n");
    exit(1);
  }
  data->frame.surface = surface;
  gpu_mark_bridge_full_upload(&data->frame);
  data->surface_valid = true;
  data->texture_valid = false;
  canvas->backend_data = data;
  canvas->rensurface.surface = data->frame.surface;
  canvas->rensurface.scale_x = 1;
  canvas->rensurface.scale_y = 1;
}

static void gpu_destroy_canvas(RenCache *canvas) {
  GpuCanvasData *data = canvas->backend_data;
  if (data) {
    gpu_destroy_bridge_resources(data->device, &data->frame);
    if (data->device) {
      gpu_release_device();
      data->device = NULL;
    }
    gpu_destroy_bridge_surface(&data->frame);
  }
  SDL_free(data);
  canvas->backend_data = NULL;
  canvas->rensurface.surface = NULL;
}

static SDL_Surface *gpu_get_canvas_surface(RenCache *canvas) {
  GpuCanvasData *data = canvas->backend_data;
  if (!data)
    return canvas->rensurface.surface;

  if (!data->surface_valid) {
    if (!data->texture_valid || !data->frame.texture)
      gpu_abort("SDLGPU canvas CPU surface requested without valid texture");
    if (!data->device)
      data->device = gpu_retain_device();
    if (!gpu_download_bridge_texture_to_surface(data->device, &data->frame))
      gpu_abort("SDLGPU canvas texture readback failed");
    data->surface_valid = true;
  }

  return data->frame.surface;
}

static void gpu_get_canvas_size(RenCache *canvas, int *width, int *height) {
  GpuCanvasData *data = canvas->backend_data;
  SDL_Surface *surface = data ? data->frame.surface : gpu_get_canvas_surface(canvas);
  *width = surface->w;
  *height = surface->h;
}

static void gpu_ensure_canvas_cpu_surface_for_draw(RenCache *rc, RenSurface *surface) {
  if (rc->window_target || !rc->backend_data)
    return;

  surface->surface = gpu_get_canvas_surface(rc);
  surface->scale_x = rc->rensurface.scale_x;
  surface->scale_y = rc->rensurface.scale_y;
}

static bool gpu_submit_and_wait(SDL_GPUDevice *device, SDL_GPUCommandBuffer *cmd) {
  SDL_GPUFence *fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
  if (!fence)
    return false;
  bool waited = SDL_WaitForGPUFences(device, true, &fence, 1);
  SDL_ReleaseGPUFence(device, fence);
  return waited;
}

static bool gpu_surface_is_fully_transparent(SDL_Surface *surface) {
  if (!surface || !SDL_ISPIXELFORMAT_ALPHA(surface->format) || SDL_BYTESPERPIXEL(surface->format) != 4)
    return false;

  const SDL_PixelFormatDetails *details = SDL_GetPixelFormatDetails(surface->format);
  if (!details || !details->Amask)
    return false;

  if (!SDL_LockSurface(surface))
    gpu_abort("SDL_LockSurface failed");

  bool transparent = true;
  for (int y = 0; y < surface->h && transparent; y++) {
    const Uint32 *pixel = (const Uint32 *) ((const Uint8 *) surface->pixels + y * surface->pitch);
    for (int x = 0; x < surface->w; x++) {
      if (pixel[x] & details->Amask) {
        transparent = false;
        break;
      }
    }
  }

  SDL_UnlockSurface(surface);
  return transparent;
}

static void gpu_clear_canvas_texture(GpuCanvasData *data, SDL_GPUCommandBuffer *cmd, SDL_FColor color) {
  gpu_ensure_bridge_texture(data->device, &data->frame, data->frame.surface->w, data->frame.surface->h);

  SDL_GPUColorTargetInfo color_target;
  SDL_zero(color_target);
  color_target.texture = data->frame.texture;
  color_target.clear_color = color;
  color_target.load_op = SDL_GPU_LOADOP_CLEAR;
  color_target.store_op = SDL_GPU_STOREOP_STORE;
  color_target.cycle = true;
  SDL_GPURenderPass *pass = SDL_BeginGPURenderPass(cmd, &color_target, 1, NULL);
  SDL_EndGPURenderPass(pass);

  data->texture_valid = true;
  data->frame.needs_full_upload = false;
  data->frame.dirty_count = 0;
}

static bool gpu_copy_canvas_native(RenCache *dst, RenCache *src, int x, int y, bool blend) {
  GpuCanvasData *dst_data = dst->backend_data;
  GpuCanvasData *src_data = src->backend_data;
  if (!dst_data || !src_data || dst_data == src_data)
    return false;

  if (!dst_data->device)
    dst_data->device = gpu_retain_device();
  if (!src_data->device)
    src_data->device = gpu_retain_device();
  if (dst_data->device != src_data->device)
    return false;

  bool source_needs_upload = !src_data->texture_valid || gpu_bridge_has_pending_upload(&src_data->frame);
  bool clear_transparent_dst = !dst_data->texture_valid
      && gpu_bridge_has_pending_upload(&dst_data->frame)
      && gpu_surface_is_fully_transparent(dst_data->frame.surface);
  if (source_needs_upload || !dst_data->texture_valid ||
      gpu_bridge_has_pending_upload(&dst_data->frame)) {
    if (!SDL_WaitForGPUIdle(dst_data->device))
      gpu_abort("SDL_WaitForGPUIdle failed before SDLGPU canvas copy");
  }

  GpuFrameBridge temp_src;
  SDL_zero(temp_src);
  temp_src.surface = src_data->frame.surface;
  GpuFrameBridge *src_frame = &src_data->frame;

  SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(dst_data->device);
  if (!cmd)
    gpu_abort("SDL_AcquireGPUCommandBuffer failed");

  if (source_needs_upload) {
    if (!gpu_upload_bridge_pending(dst_data->device, &temp_src, cmd, NULL, 0, true)) {
      SDL_CancelGPUCommandBuffer(cmd);
      return false;
    }
    src_frame = &temp_src;
  } else {
    gpu_sync_canvas_texture(src_data, cmd);
  }
  if (clear_transparent_dst) {
    gpu_clear_canvas_texture(
      dst_data,
      cmd,
      (SDL_FColor) { .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 0.0f }
    );
  } else {
    gpu_sync_canvas_texture(dst_data, cmd);
  }

  if (!src_frame->texture || !dst_data->texture_valid || !dst_data->frame.texture) {
    SDL_CancelGPUCommandBuffer(cmd);
    gpu_destroy_bridge_resources(dst_data->device, &temp_src);
    return false;
  }
  if (!gpu_submit_and_wait(dst_data->device, cmd))
    gpu_abort("SDL_SubmitGPUCommandBufferAndAcquireFence failed");

  cmd = SDL_AcquireGPUCommandBuffer(dst_data->device);
  if (!cmd)
    gpu_abort("SDL_AcquireGPUCommandBuffer failed");

  bool copied = gpu_blit_texture_to_bridge(
    dst_data->device,
    cmd,
    &dst_data->frame,
    src_frame,
    x,
    y,
    blend ? SDL_BLENDMODE_BLEND : SDL_BLENDMODE_NONE,
    false
  );
  if (!copied) {
    SDL_CancelGPUCommandBuffer(cmd);
    gpu_destroy_bridge_resources(dst_data->device, &temp_src);
    return false;
  }
  if (!gpu_submit_and_wait(dst_data->device, cmd))
    gpu_abort("SDL_SubmitGPUCommandBufferAndAcquireFence failed");
  gpu_destroy_bridge_resources(dst_data->device, &temp_src);

  dst_data->texture_valid = true;
  dst_data->surface_valid = false;
  dst_data->frame.needs_full_upload = false;
  dst_data->frame.dirty_count = 0;
  dst->revision++;
  return true;
}

static void gpu_copy_canvas(RenCache *dst, RenCache *src, int x, int y, bool blend) {
  GpuCanvasData *dst_data = dst->backend_data;
  if (gpu_copy_canvas_native(dst, src, x, y, blend))
    return;

  SDL_Surface *src_surface = gpu_get_canvas_surface(src);
  SDL_Surface *dst_surface = gpu_get_canvas_surface(dst);
  SDL_Rect rect = { .x = x, .y = y, .w = src_surface->w, .h = src_surface->h };
  SDL_BlendMode src_mode;
  SDL_GetSurfaceBlendMode(src_surface, &src_mode);
  SDL_SetSurfaceBlendMode(src_surface, blend ? SDL_BLENDMODE_BLEND : SDL_BLENDMODE_NONE);
  SDL_BlitSurface(src_surface, NULL, dst_surface, &rect);
  SDL_SetSurfaceBlendMode(src_surface, src_mode);

  if (dst_data) {
    RenRect dirty_rect = {
      .x = x,
      .y = y,
      .width = src_surface->w,
      .height = src_surface->h,
    };
    gpu_mark_canvas_surface_modified(dst_data, &dirty_rect, 1);
  }
  dst->revision++;
}

static bool gpu_draw_canvas_rect_native(
  RenCache *rc, RenSurface *surface, RenRect rect, RenColor color, bool replace
) {
  if (rc->window_target || !surface || !surface->surface || rect.width <= 0 || rect.height <= 0)
    return false;

  GpuCanvasData *data = rc->backend_data;
  if (!data)
    return false;
  if (!data->device)
    data->device = gpu_retain_device();

  SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(data->device);
  if (!cmd)
    gpu_abort("SDL_AcquireGPUCommandBuffer failed");

  gpu_sync_canvas_texture(data, cmd);
  bool drawn = gpu_draw_solid_rect_to_bridge(
    data->device, cmd, &data->frame, surface->surface, rect, color, replace
  );
  if (!drawn) {
    SDL_CancelGPUCommandBuffer(cmd);
    return false;
  }
  if (!gpu_submit_and_wait(data->device, cmd))
    gpu_abort("SDL_SubmitGPUCommandBufferAndAcquireFence failed");

  data->texture_valid = true;
  data->surface_valid = false;
  data->frame.needs_full_upload = false;
  data->frame.dirty_count = 0;
  rc->revision++;
  return true;
}

static bool gpu_draw_canvas_pixels_native(
  RenCache *rc, RenSurface *surface, RenRect rect, const char *bytes, size_t len
) {
  if (rc->window_target || !surface || !surface->surface || !bytes || rect.width <= 0 || rect.height <= 0)
    return false;

  GpuCanvasData *data = rc->backend_data;
  if (!data)
    return false;
  if (!data->device)
    data->device = gpu_retain_device();

  SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(data->device);
  if (!cmd)
    gpu_abort("SDL_AcquireGPUCommandBuffer failed");

  gpu_sync_canvas_texture(data, cmd);
  bool uploaded = gpu_upload_pixels_to_bridge(
    data->device, cmd, &data->frame, surface->surface, rect, bytes, len
  );
  if (!uploaded) {
    SDL_CancelGPUCommandBuffer(cmd);
    return false;
  }
  if (!gpu_submit_and_wait(data->device, cmd))
    gpu_abort("SDL_SubmitGPUCommandBufferAndAcquireFence failed");

  data->texture_valid = true;
  data->surface_valid = false;
  data->frame.needs_full_upload = false;
  data->frame.dirty_count = 0;
  rc->revision++;
  return true;
}

static bool gpu_draw_canvas_text_native(
  RenCache *rc, RenSurface *surface, RenFont **fonts, const char *text, size_t len,
  float x, float y, RenColor color, RenTab tab, double *end_x
) {
  if (rc->window_target || !surface || !surface->surface || !fonts || !text)
    return false;

  GpuCanvasData *data = rc->backend_data;
  if (!data)
    return false;
  if (!data->device)
    data->device = gpu_retain_device();
  if (!gpu_native_text_supported(data->device))
    return false;

  SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(data->device);
  if (!cmd)
    gpu_abort("SDL_AcquireGPUCommandBuffer failed");

  gpu_sync_canvas_texture(data, cmd);
  gpu_ensure_bridge_texture(data->device, &data->frame, surface->surface->w, surface->surface->h);
  if (!data->frame.texture || !gpu_ensure_text_pipeline(data->device)) {
    SDL_CancelGPUCommandBuffer(cmd);
    return false;
  }

  GpuTextDrawContext text_context;
  SDL_zero(text_context);
  text_context.device = data->device;
  text_context.command_buffer = cmd;
  text_context.target_frame = &data->frame;
  text_context.collect_overlay = true;

  SDL_GPUDevice *prev_device = gpu_active_frame_device;
  SDL_GPUCommandBuffer *prev_cmd = gpu_active_frame_command_buffer;
  GpuWindowData *prev_window_data = gpu_active_frame_window_data;
  gpu_active_frame_device = data->device;
  gpu_active_frame_command_buffer = cmd;
  gpu_active_frame_window_data = NULL;

  *end_x = ren_draw_text_cb_ex(
    surface, fonts, text, len, x, y, color, tab, gpu_collect_text_glyph, &text_context, false
  );

  gpu_active_frame_device = prev_device;
  gpu_active_frame_command_buffer = prev_cmd;
  gpu_active_frame_window_data = prev_window_data;

  bool drawn = gpu_draw_text_glyphs_to_bridge(
    data->device, cmd, &data->frame, surface->surface, text_context.glyphs, text_context.glyph_count
  );

  int style = ren_font_group_get_style(fonts);
  if (drawn && (style & (FONT_STYLE_UNDERLINE | FONT_STYLE_STRIKETHROUGH))) {
    int height = ren_font_group_get_height(fonts);
    int thickness = ren_font_group_get_underline_thickness(fonts);
    RenRect decoration = {
      .x = x,
      .y = y,
      .width = (int) ceil(*end_x - x),
      .height = (int) ceil(thickness * surface->scale_x),
    };
    if (style & FONT_STYLE_UNDERLINE) {
      decoration.y = y + height - 1;
      drawn = gpu_draw_solid_rect_to_bridge(
        data->device, cmd, &data->frame, surface->surface, decoration, color, false
      );
    }
    if (drawn && (style & FONT_STYLE_STRIKETHROUGH)) {
      decoration.y = y + (float) height / 2;
      drawn = gpu_draw_solid_rect_to_bridge(
        data->device, cmd, &data->frame, surface->surface, decoration, color, false
      );
    }
  }

  int glyph_count = text_context.glyph_count;
  SDL_free(text_context.glyphs);
  if (!drawn) {
    SDL_CancelGPUCommandBuffer(cmd);
    return false;
  }

  if (!gpu_submit_and_wait(data->device, cmd))
    gpu_abort("SDL_SubmitGPUCommandBufferAndAcquireFence failed");

  data->texture_valid = true;
  data->surface_valid = false;
  data->frame.needs_full_upload = false;
  data->frame.dirty_count = 0;
  if (glyph_count > 0)
    rc->revision++;
  return true;
}

static bool gpu_draw_canvas_poly_native(
  RenCache *rc, RenSurface *surface, RenPoint *points, unsigned short npoints, RenColor color
) {
  if (rc->window_target || !surface || !surface->surface || npoints < 3)
    return false;

  RenRect bounds;
  if (ren_poly_cbox(points, npoints, &bounds) != 0 || bounds.width <= 0 || bounds.height <= 0)
    return false;

  GpuCanvasData *data = rc->backend_data;
  if (!data)
    return false;
  if (!data->device)
    data->device = gpu_retain_device();

  RenPoint *flat_points = NULL;
  unsigned short flat_count = 0;
  if (!gpu_flatten_poly(points, npoints, &flat_points, &flat_count))
    return false;

  GpuPolyVertex *vertices = SDL_malloc((flat_count - 2) * 3 * sizeof(GpuPolyVertex));
  if (!vertices)
    gpu_abort("Error allocating polygon vertices");
  int vertex_count = gpu_triangulate_line_poly(
    flat_points, flat_count, vertices,
    surface->scale_x > 0 ? surface->scale_x : 1.0f,
    surface->scale_y > 0 ? surface->scale_y : 1.0f
  );
  if (vertex_count == 0) {
    SDL_free(flat_points);
    SDL_free(vertices);
    return false;
  }

  SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(data->device);
  if (!cmd)
    gpu_abort("SDL_AcquireGPUCommandBuffer failed");

  gpu_sync_canvas_texture(data, cmd);
  bool drawn = gpu_draw_poly_vertices_to_bridge(
    data->device, cmd, &data->frame, surface->surface, vertices, vertex_count, bounds, color
  );
  SDL_free(flat_points);
  SDL_free(vertices);
  if (!drawn) {
    SDL_CancelGPUCommandBuffer(cmd);
    return false;
  }
  if (!gpu_submit_and_wait(data->device, cmd))
    gpu_abort("SDL_SubmitGPUCommandBufferAndAcquireFence failed");

  data->texture_valid = true;
  data->surface_valid = false;
  data->frame.needs_full_upload = false;
  data->frame.dirty_count = 0;
  rc->revision++;
  return true;
}

static void gpu_set_clip_rect(UNUSED RenCache *rc, RenSurface *surface, RenRect rect) {
  ren_set_clip_rect(surface, rect);
}

static bool gpu_can_native_rect(
  RenCache *rc, RenSurface *surface, RenRect rect, RenColor color, UNUSED bool replace
) {
  if (!rc->window_target || !surface->surface || !gpu_direct_replay_enabled() ||
      !gpu_native_rect_enabled() || (replace && color.a != 255))
    return false;

  RenWindow *ren = rc->target;
  GpuWindowData *data = ren->backend_data;
  if (!data || !data->command_buffer || !data->frame.texture)
    return false;
  if (!gpu_ensure_text_pipeline(data->device) ||
      !gpu_ensure_solid_white_texture(data->device, data->command_buffer))
    return false;

  SDL_Rect dst = gpu_pixel_rect_from_ren_rect(surface->surface, rect);
  return dst.w > 0 && dst.h > 0;
}

static bool gpu_can_native_text(
  RenCache *rc, RenSurface *surface, RenFont **fonts, const char *text, size_t len,
  float x, float y, RenColor color, RenTab tab
) {
  if (!rc->window_target || !surface->surface || !gpu_direct_replay_enabled())
    return false;
  int style = ren_font_group_get_style(fonts);
  if ((style & (FONT_STYLE_UNDERLINE | FONT_STYLE_STRIKETHROUGH)) && color.a != 255)
    return false;

  RenWindow *ren = rc->target;
  GpuWindowData *data = ren->backend_data;
  if (!data || !gpu_native_text_supported(data->device) || !data->command_buffer || !data->frame.texture)
    return false;
  if (!gpu_ensure_text_pipeline(data->device))
    return false;
  if ((style & (FONT_STYLE_UNDERLINE | FONT_STYLE_STRIKETHROUGH)) &&
      !gpu_ensure_solid_white_texture(data->device, data->command_buffer))
    return false;

  GpuTextNativeCheck check = { .native_text = true };
  ren_draw_text_cb_ex(surface, fonts, text, len, x, y, color, tab, gpu_check_native_text_glyph, &check, false);
  return check.native_text;
}

static bool gpu_can_native_canvas(
  RenCache *rc, UNUSED RenSurface *surface, RenCache *canvas, UNUSED int x, UNUSED int y
) {
  if (!rc->window_target || !gpu_direct_replay_enabled() || !gpu_native_canvas_enabled())
    return false;

  RenWindow *ren = rc->target;
  GpuWindowData *window_data = ren->backend_data;
  GpuCanvasData *canvas_data = canvas->backend_data;
  if (!window_data || !canvas_data || !window_data->command_buffer)
    return false;

  SDL_BlendMode blend_mode = SDL_BLENDMODE_INVALID;
  return canvas_data->frame.surface
      && SDL_GetSurfaceBlendMode(canvas_data->frame.surface, &blend_mode)
      && (blend_mode == SDL_BLENDMODE_NONE || blend_mode == SDL_BLENDMODE_BLEND);
}

static bool gpu_can_native_pixels(
  RenCache *rc, RenSurface *surface, RenRect rect, UNUSED const char *bytes, size_t len
) {
  if (!rc->window_target || !surface->surface || !gpu_direct_replay_enabled())
    return false;
  if (rect.width <= 0 || rect.height <= 0)
    return false;

  RenWindow *ren = rc->target;
  GpuWindowData *data = ren->backend_data;
  if (!data || !data->command_buffer || !data->frame.texture)
    return false;

  SDL_Rect dst = gpu_pixel_rect_from_ren_rect(surface->surface, rect);
  if (dst.w <= 0 || dst.h <= 0)
    return false;

  Uint64 required = (Uint64) rect.width * (Uint64) rect.height * 4;
  return required > 0 && (Uint64) len >= required;
}

static bool gpu_can_native_poly(
  RenCache *rc, RenSurface *surface, RenPoint *points, unsigned short npoints, UNUSED RenColor color
) {
  if (!rc->window_target || !surface->surface || !gpu_direct_replay_enabled() ||
      npoints < 3)
    return false;

  RenWindow *ren = rc->target;
  GpuWindowData *data = ren->backend_data;
  if (!data || !data->command_buffer || !data->frame.texture)
    return false;
  if (!gpu_ensure_poly_pipeline(data->device))
    return false;
  RenPoint *flat_points = NULL;
  unsigned short flat_count = 0;
  bool can_flatten = gpu_flatten_poly(points, npoints, &flat_points, &flat_count);
  SDL_free(flat_points);
  if (!can_flatten)
    return false;

  RenRect bounds;
  if (ren_poly_cbox(points, npoints, &bounds) != 0 || bounds.width <= 0 || bounds.height <= 0)
    return false;

  SDL_Rect dst = gpu_pixel_rect_from_ren_rect(surface->surface, bounds);
  return dst.w > 0 && dst.h > 0;
}

static void gpu_draw_rect(RenCache *rc, RenSurface *surface, RenRect rect, RenColor color, bool replace) {
  if (!rc->window_target) {
    if (gpu_draw_canvas_rect_native(rc, surface, rect, color, replace))
      return;
    gpu_ensure_canvas_cpu_surface_for_draw(rc, surface);
    ren_draw_rect(surface, rect, color, replace);
    return;
  }

  bool native_region = gpu_window_region_is_native(rc);
  if (!native_region)
    gpu_abort("SDLGPU window rect draw outside native replay region");

  RenWindow *ren = rc->target;
  gpu_flush_pending_text_barrier(ren->backend_data);
  bool native_queued = native_region && gpu_native_rect_enabled() && gpu_queue_window_native_rect(rc, surface, rect, color);
  if (!native_queued)
    gpu_abort("SDLGPU native rect draw failed");
}

static double gpu_draw_text(RenCache *rc, RenSurface *surface, RenFont **fonts, const char *text, size_t len, float x, float y, RenColor color, RenTab tab) {
  if (!rc->window_target) {
    double end_x = x;
    if (gpu_draw_canvas_text_native(rc, surface, fonts, text, len, x, y, color, tab, &end_x))
      return end_x;
    gpu_ensure_canvas_cpu_surface_for_draw(rc, surface);
    return ren_draw_text_cb(surface, fonts, text, len, x, y, color, tab, NULL, NULL);
  }

  GpuTextDrawContext text_context;
  SDL_zero(text_context);
  int style = ren_font_group_get_style(fonts);
  bool native_region = gpu_window_region_is_native(rc);
  if (!native_region)
    gpu_abort("SDLGPU window text draw outside native replay region");

  bool can_use_native_text = !(style & (FONT_STYLE_UNDERLINE | FONT_STYLE_STRIKETHROUGH)) || color.a == 255;
  if (!can_use_native_text)
    gpu_abort("SDLGPU native text decorations with translucent color are unsupported");

  RenWindow *ren = rc->target;
  text_context.window_data = ren->backend_data;
  if (!text_context.window_data || !text_context.window_data->command_buffer)
    gpu_abort("SDLGPU native text command buffer unavailable");
  text_context.collect_overlay = gpu_native_text_supported(text_context.window_data->device)
      && text_context.window_data->frame.texture;
  if (!text_context.collect_overlay)
    gpu_abort("SDLGPU native text pipeline unavailable");
  if (!gpu_flush_window_native_rects(text_context.window_data, text_context.window_data->command_buffer))
    gpu_abort("SDLGPU native rect flush before text failed");

  double end_x = ren_draw_text_cb_ex(
    surface, fonts, text, len, x, y, color, tab, gpu_collect_text_glyph, &text_context, false
  );
  bool used_native = gpu_queue_text_batch(&text_context);
  SDL_free(text_context.glyphs);
  if (!used_native && text_context.have_dirty_rect)
    gpu_abort("SDLGPU native text queue failed");
  if (style & (FONT_STYLE_UNDERLINE | FONT_STYLE_STRIKETHROUGH)) {
    RenWindow *ren = rc->target;
    GpuWindowData *data = ren->backend_data;
    if (data && data->command_buffer && data->pending_text_glyph_count > 0)
      gpu_flush_queued_text(data, data->command_buffer, NULL, 0, false);
    int height = ren_font_group_get_height(fonts);
    int thickness = ren_font_group_get_underline_thickness(fonts);
    RenRect decoration = {
      .x = x,
      .y = y,
      .width = (int) ceil(end_x - x),
      .height = (int) ceil(thickness * surface->scale_x),
    };
    if (style & FONT_STYLE_UNDERLINE) {
      decoration.y = y + height - 1;
      gpu_queue_window_native_rect(rc, surface, decoration, color);
    }
    if (style & FONT_STYLE_STRIKETHROUGH) {
      decoration.y = y + (float) height / 2;
      gpu_queue_window_native_rect(rc, surface, decoration, color);
    }
  }
  return end_x;
}

static void gpu_draw_poly(RenCache *rc, RenSurface *surface, RenPoint *points, unsigned short npoints, RenColor color) {
  if (!rc->window_target) {
    if (gpu_draw_canvas_poly_native(rc, surface, points, npoints, color))
      return;
    gpu_ensure_canvas_cpu_surface_for_draw(rc, surface);
    ren_draw_poly(surface, points, npoints, color);
    return;
  }

  if (!gpu_window_region_is_native(rc))
    gpu_abort("SDLGPU window poly draw outside native replay region");
  if (!gpu_draw_poly_native(rc, surface, points, npoints, color))
    gpu_abort("SDLGPU native poly draw failed");
}

static void gpu_draw_canvas(RenCache *rc, RenSurface *surface, RenCache *canvas, int x, int y) {
  if (!rc->window_target) {
    gpu_ensure_canvas_cpu_surface_for_draw(rc, surface);
    ren_draw_canvas(surface, canvas->backend->get_canvas_surface(canvas), x, y);
    return;
  }

  GpuWindowData *window_data = NULL;
  GpuCanvasData *canvas_data = NULL;
  SDL_BlendMode blend_mode = SDL_BLENDMODE_INVALID;
  bool native_candidate = false;
  bool native_region = gpu_window_region_is_native(rc);
  if (!native_region)
    gpu_abort("SDLGPU window canvas draw outside native replay region");

  if (gpu_native_canvas_enabled()) {
    RenWindow *ren = rc->target;
    window_data = ren->backend_data;
    canvas_data = canvas->backend_data;
    if (window_data && canvas_data) {
      if (!gpu_sync_canvas_texture_immediate(canvas_data))
        gpu_abort("SDLGPU canvas texture sync before window draw failed");
      native_candidate =
        SDL_GetSurfaceBlendMode(canvas_data->frame.surface, &blend_mode) &&
        (blend_mode == SDL_BLENDMODE_NONE || blend_mode == SDL_BLENDMODE_BLEND);
      if (native_candidate) {
        if (window_data->pending_text_glyph_count > 0)
          gpu_flush_queued_text(window_data, window_data->command_buffer, NULL, 0, false);
        if (!gpu_flush_window_native_rects(window_data, window_data->command_buffer))
          gpu_abort("SDLGPU native rect flush before canvas failed");
      }
    }
  }

  if (!native_candidate)
    gpu_abort("SDLGPU native canvas draw unsupported");

  bool synced = false;
  if (window_data && canvas_data && native_candidate)
    synced = gpu_blit_canvas_texture_to_frame(window_data, canvas_data, x, y, blend_mode);
  if (synced) {
    window_data->stats_native_canvases++;
  } else {
    gpu_abort("SDLGPU native canvas draw failed");
  }
}

static void gpu_draw_pixels(RenCache *rc, RenSurface *surface, RenRect rect, const char *bytes, size_t len) {
  if (!rc->window_target) {
    if (gpu_draw_canvas_pixels_native(rc, surface, rect, bytes, len))
      return;
    gpu_ensure_canvas_cpu_surface_for_draw(rc, surface);
    ren_draw_pixels(surface, rect, bytes, len);
    return;
  }

  if (!gpu_window_region_is_native(rc))
    gpu_abort("SDLGPU window pixel draw outside native replay region");
  if (!gpu_draw_pixels_native(rc, surface, rect, bytes, len))
    gpu_abort("SDLGPU native pixel draw failed");
}

static void gpu_target_updated(RenCache *cache, RenRect *rects, int count) {
  if (cache->window_target)
    return;

  GpuCanvasData *data = cache->backend_data;
  if (data && data->surface_valid)
    gpu_mark_canvas_surface_modified(data, rects, count);
}

static const RenCacheDrawOps gpu_draw_ops = {
  .set_clip_rect = gpu_set_clip_rect,
  .draw_rect = gpu_draw_rect,
  .draw_text = gpu_draw_text,
  .draw_poly = gpu_draw_poly,
  .draw_canvas = gpu_draw_canvas,
  .draw_pixels = gpu_draw_pixels,
};

static const RenBackend sdlgpu_backend = {
  .name = "sdlgpu",
  .draw_ops = &gpu_draw_ops,
  .begin_frame = gpu_begin_frame,
  .end_frame = gpu_end_frame,
  .begin_region = gpu_begin_region,
  .end_region = gpu_end_region,
  .can_native_rect = gpu_can_native_rect,
  .can_native_text = gpu_can_native_text,
  .can_native_canvas = gpu_can_native_canvas,
  .can_native_pixels = gpu_can_native_pixels,
  .can_native_poly = gpu_can_native_poly,
  .get_window_surface = gpu_get_window_surface,
  .present_window_rects = gpu_present_window_rects,
  .capture_window = gpu_capture_window,
  .init_window = gpu_init_window,
  .resize_window = gpu_resize_window,
  .destroy_window = gpu_destroy_window,
  .init_canvas = gpu_init_canvas,
  .destroy_canvas = gpu_destroy_canvas,
  .get_canvas_surface = gpu_get_canvas_surface,
  .get_canvas_size = gpu_get_canvas_size,
  .copy_canvas = gpu_copy_canvas,
  .target_updated = gpu_target_updated,
  .init_atlas = gpu_init_atlas,
};

const RenBackend *renbackend_sdlgpu(void) {
  return &sdlgpu_backend;
}

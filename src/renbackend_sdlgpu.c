#include "renbackend_sdlgpu.h"
#include "renwindow.h"

#include <math.h>
#include <stdio.h>
#include <stddef.h>
#include <stdlib.h>

#include "shaders/gpu_canvas.frag.dxbc.h"
#include "shaders/gpu_canvas.frag.dxil.h"
#include "shaders/gpu_canvas.frag.msl.h"
#include "shaders/gpu_canvas.frag.spv.h"
#include "shaders/gpu_canvas.vert.dxbc.h"
#include "shaders/gpu_canvas.vert.dxil.h"
#include "shaders/gpu_canvas.vert.msl.h"
#include "shaders/gpu_canvas.vert.spv.h"
#include "shaders/gpu_canvas_batch.frag.dxbc.h"
#include "shaders/gpu_canvas_batch.frag.dxil.h"
#include "shaders/gpu_canvas_batch.frag.msl.h"
#include "shaders/gpu_canvas_batch.frag.spv.h"
#include "shaders/gpu_canvas_batch.vert.dxbc.h"
#include "shaders/gpu_canvas_batch.vert.dxil.h"
#include "shaders/gpu_canvas_batch.vert.msl.h"
#include "shaders/gpu_canvas_batch.vert.spv.h"
#include "shaders/gpu_rect.frag.dxbc.h"
#include "shaders/gpu_rect.frag.dxil.h"
#include "shaders/gpu_rect.frag.msl.h"
#include "shaders/gpu_rect.frag.spv.h"
#include "shaders/gpu_rect.vert.dxbc.h"
#include "shaders/gpu_rect.vert.dxil.h"
#include "shaders/gpu_rect.vert.msl.h"
#include "shaders/gpu_rect.vert.spv.h"
#include "shaders/gpu_poly.frag.dxbc.h"
#include "shaders/gpu_poly.frag.dxil.h"
#include "shaders/gpu_poly.frag.msl.h"
#include "shaders/gpu_poly.frag.spv.h"
#include "shaders/gpu_poly.vert.dxbc.h"
#include "shaders/gpu_poly.vert.dxil.h"
#include "shaders/gpu_poly.vert.msl.h"
#include "shaders/gpu_poly.vert.spv.h"
#include "shaders/gpu_text.frag.dxbc.h"
#include "shaders/gpu_text.frag.dxil.h"
#include "shaders/gpu_text.frag.msl.h"
#include "shaders/gpu_text.frag.spv.h"
#include "shaders/gpu_text.vert.dxbc.h"
#include "shaders/gpu_text.vert.dxil.h"
#include "shaders/gpu_text.vert.msl.h"
#include "shaders/gpu_text.vert.spv.h"
#include "shaders/gpu_text_batch.frag.dxbc.h"
#include "shaders/gpu_text_batch.frag.dxil.h"
#include "shaders/gpu_text_batch.frag.msl.h"
#include "shaders/gpu_text_batch.frag.spv.h"
#include "shaders/gpu_text_batch.vert.dxbc.h"
#include "shaders/gpu_text_batch.vert.dxil.h"
#include "shaders/gpu_text_batch.vert.msl.h"
#include "shaders/gpu_text_batch.vert.spv.h"

#define GPU_SUPPORTED_SHADER_FORMATS (SDL_GPU_SHADERFORMAT_SPIRV | SDL_GPU_SHADERFORMAT_DXBC | SDL_GPU_SHADERFORMAT_DXIL | SDL_GPU_SHADERFORMAT_MSL)
#define GPU_DIRTY_UPLOAD_FULL_THRESHOLD 64
#define GPU_TEXTURE_ROW_ALIGNMENT 256
#define GPU_TEXTURE_OFFSET_ALIGNMENT 512
#define GPU_NATIVE_TEXT_ENABLED false
#define GPU_NATIVE_CANVAS_ENABLED false
#define GPU_NATIVE_RECT_ENABLED false
#define GPU_NATIVE_RECT_BATCH_SIZE 16384

typedef enum {
  GPU_TEXTURE_BATCH_BLEND,
  GPU_TEXTURE_BATCH_REPLACE,
} GpuTextureBatchMode;

typedef enum {
  GPU_BATCH_PIPELINE_TEXT,
  GPU_BATCH_PIPELINE_CANVAS_BLEND,
  GPU_BATCH_PIPELINE_CANVAS_REPLACE,
  GPU_BATCH_PIPELINE_RECT_BLEND,
  GPU_BATCH_PIPELINE_RECT_REPLACE,
  GPU_BATCH_PIPELINE_POLY,
} GpuBatchPipeline;

typedef enum {
  GPU_BATCH_QUEUE_RECTS = 1 << 0,
  GPU_BATCH_QUEUE_TEXT = 1 << 1,
  GPU_BATCH_QUEUE_CANVASES = 1 << 2,
  GPU_BATCH_QUEUE_POLYS = 1 << 3,
  GPU_BATCH_QUEUE_PIXELS = 1 << 4,
  GPU_BATCH_QUEUE_ALL = GPU_BATCH_QUEUE_RECTS
      | GPU_BATCH_QUEUE_TEXT
      | GPU_BATCH_QUEUE_CANVASES
      | GPU_BATCH_QUEUE_POLYS
      | GPU_BATCH_QUEUE_PIXELS,
} GpuBatchQueueMask;

typedef struct {
  GpuBatchPipeline pipeline;
  SDL_GPUTexture *texture;
  SDL_GPUSampler *sampler;
  unsigned char glyph_format;
} GpuBatchMaterial;

typedef struct {
  GpuBatchMaterial material;
  Uint32 first_vertex;
  Uint32 vertex_count;
} GpuBatchRun;

typedef struct {
  float x, y;
} GpuPolyVertex;

typedef struct {
  SDL_Surface *surface;
  SDL_GPUTexture *texture;
  SDL_GPUTransferBuffer *transfer;
  SDL_GPUBuffer *poly_vertex_buffer;
  SDL_GPUTransferBuffer *poly_transfer;
  SDL_GPUBuffer *text_vertex_buffer;
  SDL_GPUTransferBuffer *text_transfer;
  SDL_GPUBuffer *quad_vertex_buffer;
  SDL_GPUTransferBuffer *quad_transfer;
  GpuBatchRun *batch_runs;
  RenPoint *poly_points;
  GpuPolyVertex *poly_vertices;
  int *poly_indices;
  Uint32 transfer_size;
  Uint32 poly_vertex_buffer_size;
  Uint32 poly_transfer_size;
  Uint32 text_vertex_buffer_size;
  Uint32 text_transfer_size;
  Uint32 quad_vertex_buffer_size;
  Uint32 quad_transfer_size;
  int batch_run_capacity;
  int poly_point_capacity;
  int poly_vertex_capacity;
  int poly_index_capacity;
  SDL_PixelFormat texture_pixel_format;
  int texture_w, texture_h;
  bool needs_full_upload;
  RenRect dirty_rects[GPU_DIRTY_UPLOAD_FULL_THRESHOLD];
  int dirty_count;
} GpuFrameBridge;

typedef struct {
  SDL_Rect rect;
  RenColor color;
  bool replace;
} GpuNativeRect;

typedef struct {
  RenAtlas *atlas;
  GlyphMetric metric;
  SDL_GPUTexture *texture;
  RenColor color;
  int dst_x, dst_y;
  int src_x, src_y;
  int width, height;
  int texture_w, texture_h;
  int texture_y0;
  SDL_Rect clip;
  unsigned char format;
} GpuQueuedGlyph;

typedef struct {
  SDL_GPUTexture *texture;
  SDL_Rect dst;
  float u0, v0, u1, v1;
  GpuTextureBatchMode mode;
} GpuQueuedCanvas;

typedef struct {
  RenColor color;
  SDL_Rect clip;
  Uint32 first_vertex;
  Uint32 vertex_count;
} GpuQueuedPoly;

typedef struct {
  SDL_Rect dst;
  Uint32 transfer_offset;
  Uint32 row_stride;
  Uint32 atlas_y;
} GpuQueuedPixels;

typedef struct {
  float x, y;
  float u, v;
} GpuTextureQuadVertex;

typedef struct {
  SDL_GPUDevice *device;
  SDL_GPUCommandBuffer *command_buffer;
  GpuFrameBridge frame;
  SDL_GPUTexture *pixels_texture;
  SDL_GPUTransferBuffer *pixels_transfer;
  SDL_GPUBuffer *rect_vertex_buffer;
  SDL_GPUTransferBuffer *rect_transfer;
  Uint32 pixels_transfer_size;
  Uint32 rect_vertex_buffer_size;
  Uint32 rect_transfer_size;
  int pixels_texture_w;
  int pixels_texture_h;
  GpuNativeRect pending_native_rects[GPU_NATIVE_RECT_BATCH_SIZE];
  GpuQueuedGlyph *pending_text_glyphs;
  GpuQueuedCanvas *pending_canvases;
  GpuQueuedPoly *pending_polys;
  GpuPolyVertex *pending_poly_vertices;
  GpuQueuedPixels *pending_pixels;
  Uint8 *pending_pixel_bytes;
  SDL_GPUTransferBuffer *validation_transfer;
  Uint32 validation_transfer_size;
  SDL_Rect validation_text_rect;
  SDL_Rect validation_probe_rect;
  SDL_Rect native_clip_rect;
  int pending_native_rect_count;
  int pending_text_glyph_count;
  int pending_text_glyph_capacity;
  int pending_canvas_count;
  int pending_canvas_capacity;
  int pending_poly_count;
  int pending_poly_capacity;
  int pending_poly_vertex_count;
  int pending_poly_vertex_capacity;
  int pending_pixel_count;
  int pending_pixel_capacity;
  Uint32 pending_pixel_bytes_size;
  Uint32 pending_pixel_bytes_capacity;
  int pending_pixels_texture_w;
  int pending_pixels_texture_h;
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
  bool have_native_clip_rect;
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
  SDL_GPUCommandBuffer *command_buffer;
  GpuFrameBridge frame;
  SDL_GPUDevice *prev_active_frame_device;
  SDL_GPUCommandBuffer *prev_active_frame_command_buffer;
  GpuWindowData *prev_active_frame_window_data;
  GpuQueuedGlyph *pending_text_glyphs;
  int pending_text_glyph_count;
  int pending_text_glyph_capacity;
  bool surface_valid;
  bool texture_valid;
  bool region_active;
  bool region_modified;
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
static SDL_GPUGraphicsPipeline *gpu_canvas_batch_pipeline = NULL;
static SDL_GPUGraphicsPipeline *gpu_canvas_batch_replace_pipeline = NULL;
static SDL_GPUSampler *gpu_canvas_sampler = NULL;
static bool gpu_canvas_pipeline_failed = false;
static SDL_GPUGraphicsPipeline *gpu_rect_pipeline = NULL;
static SDL_GPUGraphicsPipeline *gpu_rect_replace_pipeline = NULL;
static bool gpu_rect_pipeline_failed = false;
static SDL_GPUGraphicsPipeline *gpu_poly_pipeline = NULL;
static bool gpu_poly_pipeline_failed = false;
static SDL_GPUGraphicsPipeline *gpu_text_pipeline = NULL;
static SDL_GPUGraphicsPipeline *gpu_text_replace_pipeline = NULL;
static SDL_GPUGraphicsPipeline *gpu_text_batch_pipeline = NULL;
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
static bool gpu_ensure_canvas_batch_replace_pipeline(SDL_GPUDevice *device);
static bool gpu_ensure_poly_pipeline(SDL_GPUDevice *device);
static bool gpu_submit_and_wait(SDL_GPUDevice *device, SDL_GPUCommandBuffer *cmd);
static bool gpu_flush_queued_text(
  GpuWindowData *data,
  SDL_GPUCommandBuffer *cmd,
  UNUSED const RenRect *uploaded_cpu_rects,
  UNUSED int uploaded_cpu_count,
  UNUSED bool uploaded_cpu_full
);
static bool gpu_flush_queued_canvases(GpuWindowData *data, SDL_GPUCommandBuffer *cmd);
static bool gpu_flush_queued_polys(GpuWindowData *data, SDL_GPUCommandBuffer *cmd);
static bool gpu_flush_queued_pixels(GpuWindowData *data, SDL_GPUCommandBuffer *cmd);
static GpuQueuedGlyph *gpu_append_pending_text_glyph(GpuWindowData *data);
static bool gpu_flush_canvas_pending_text(GpuCanvasData *data);
static bool gpu_draw_solid_rect_to_bridge(
  SDL_GPUDevice *device, SDL_GPUCommandBuffer *cmd, GpuFrameBridge *frame,
  SDL_Surface *surface, RenRect rect, RenColor color, bool replace
);
static bool gpu_upload_pixels_to_bridge(
  SDL_GPUDevice *device, SDL_GPUCommandBuffer *cmd, GpuFrameBridge *frame,
  SDL_Surface *surface, RenRect rect, const char *bytes, size_t len
);

static bool gpu_flush_window_batches(GpuWindowData *data, GpuBatchQueueMask queues) {
  if (!data || !data->command_buffer)
    return true;
  if ((queues & GPU_BATCH_QUEUE_RECTS) && !gpu_flush_window_native_rects(data, data->command_buffer))
    return false;
  if ((queues & GPU_BATCH_QUEUE_TEXT) && data->pending_text_glyph_count > 0 &&
      !gpu_flush_queued_text(data, data->command_buffer, NULL, 0, false))
    return false;
  if ((queues & GPU_BATCH_QUEUE_CANVASES) && data->pending_canvas_count > 0 &&
      !gpu_flush_queued_canvases(data, data->command_buffer))
    return false;
  if ((queues & GPU_BATCH_QUEUE_POLYS) && data->pending_poly_count > 0 &&
      !gpu_flush_queued_polys(data, data->command_buffer))
    return false;
  if ((queues & GPU_BATCH_QUEUE_PIXELS) && data->pending_pixel_count > 0 &&
      !gpu_flush_queued_pixels(data, data->command_buffer))
    return false;
  return true;
}

static bool gpu_flush_pending_text_barrier(GpuWindowData *data) {
  return gpu_flush_window_batches(data, GPU_BATCH_QUEUE_TEXT);
}

static bool gpu_flush_pending_canvas_barrier(GpuWindowData *data) {
  return gpu_flush_window_batches(data, GPU_BATCH_QUEUE_CANVASES);
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

static bool gpu_present_sync_forced(void) {
  /* Debug/rollback override: force a CPU<->GPU fence wait every present, like
     the original always-synchronous behavior. */
  return gpu_env_flag("PRAGTICAL_SDLGPU_PRESENT_SYNC", false);
}

static bool gpu_native_text_supported(SDL_GPUDevice *device) {
  SDL_GPUShaderFormat formats = device ? SDL_GetGPUShaderFormats(device) : 0;
  return gpu_native_text_enabled()
      && device
      && (formats & (SDL_GPU_SHADERFORMAT_SPIRV | SDL_GPU_SHADERFORMAT_DXBC | SDL_GPU_SHADERFORMAT_DXIL | SDL_GPU_SHADERFORMAT_MSL));
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
  Uint32 format;
  Uint32 padding[3];
} GpuTextBatchFragmentUniforms;

typedef struct {
  float target[4];
} GpuPolyVertexUniforms;

typedef struct {
  float color[4];
} GpuPolyFragmentUniforms;

typedef struct {
  float dst[4];
  float color[4];
} GpuRectInstance;

typedef struct {
  float dst[4];
  float uv[4];
  float color[4];
} GpuTextBatchInstance;

typedef struct {
  GpuWindowData *window_data;
  SDL_GPUDevice *device;
  SDL_GPUCommandBuffer *command_buffer;
  GpuFrameBridge *target_frame;
  GpuQueuedGlyph *glyphs;
  SDL_Rect clip;
  int glyph_count;
  int glyph_capacity;
  bool collect_overlay;
  bool have_clip;
  bool batch_pipeline_ready;
} GpuTextDrawContext;

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
  if (frame->text_vertex_buffer) {
    if (device)
      SDL_ReleaseGPUBuffer(device, frame->text_vertex_buffer);
    frame->text_vertex_buffer = NULL;
  }
  if (frame->text_transfer) {
    if (device)
      SDL_ReleaseGPUTransferBuffer(device, frame->text_transfer);
    frame->text_transfer = NULL;
  }
  if (frame->quad_vertex_buffer) {
    if (device)
      SDL_ReleaseGPUBuffer(device, frame->quad_vertex_buffer);
    frame->quad_vertex_buffer = NULL;
  }
  if (frame->quad_transfer) {
    if (device)
      SDL_ReleaseGPUTransferBuffer(device, frame->quad_transfer);
    frame->quad_transfer = NULL;
  }
  SDL_free(frame->batch_runs);
  frame->batch_runs = NULL;
  SDL_free(frame->poly_points);
  frame->poly_points = NULL;
  SDL_free(frame->poly_vertices);
  frame->poly_vertices = NULL;
  SDL_free(frame->poly_indices);
  frame->poly_indices = NULL;
  frame->transfer_size = 0;
  frame->poly_vertex_buffer_size = 0;
  frame->poly_transfer_size = 0;
  frame->text_vertex_buffer_size = 0;
  frame->text_transfer_size = 0;
  frame->quad_vertex_buffer_size = 0;
  frame->quad_transfer_size = 0;
  frame->batch_run_capacity = 0;
  frame->poly_point_capacity = 0;
  frame->poly_vertex_capacity = 0;
  frame->poly_index_capacity = 0;
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

static void gpu_ensure_bridge_text_buffers(SDL_GPUDevice *device, GpuFrameBridge *frame, Uint32 size) {
  if (frame->text_vertex_buffer && frame->text_transfer &&
      frame->text_vertex_buffer_size >= size && frame->text_transfer_size >= size)
    return;

  if (frame->text_vertex_buffer)
    SDL_ReleaseGPUBuffer(device, frame->text_vertex_buffer);
  if (frame->text_transfer)
    SDL_ReleaseGPUTransferBuffer(device, frame->text_transfer);
  frame->text_vertex_buffer = NULL;
  frame->text_transfer = NULL;
  frame->text_vertex_buffer_size = 0;
  frame->text_transfer_size = 0;

  SDL_GPUBufferCreateInfo buffer_info;
  SDL_zero(buffer_info);
  buffer_info.usage = SDL_GPU_BUFFERUSAGE_VERTEX;
  buffer_info.size = size;
  frame->text_vertex_buffer = SDL_CreateGPUBuffer(device, &buffer_info);
  if (!frame->text_vertex_buffer)
    gpu_abort("SDL_CreateGPUBuffer failed for text vertices");

  SDL_GPUTransferBufferCreateInfo transfer_info;
  SDL_zero(transfer_info);
  transfer_info.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
  transfer_info.size = size;
  frame->text_transfer = SDL_CreateGPUTransferBuffer(device, &transfer_info);
  if (!frame->text_transfer)
    gpu_abort("SDL_CreateGPUTransferBuffer failed for text vertices");

  frame->text_vertex_buffer_size = size;
  frame->text_transfer_size = size;
}

static void gpu_ensure_bridge_quad_buffers(SDL_GPUDevice *device, GpuFrameBridge *frame, Uint32 size) {
  if (frame->quad_vertex_buffer && frame->quad_transfer &&
      frame->quad_vertex_buffer_size >= size && frame->quad_transfer_size >= size)
    return;

  if (frame->quad_vertex_buffer)
    SDL_ReleaseGPUBuffer(device, frame->quad_vertex_buffer);
  if (frame->quad_transfer)
    SDL_ReleaseGPUTransferBuffer(device, frame->quad_transfer);
  frame->quad_vertex_buffer = NULL;
  frame->quad_transfer = NULL;
  frame->quad_vertex_buffer_size = 0;
  frame->quad_transfer_size = 0;

  SDL_GPUBufferCreateInfo buffer_info;
  SDL_zero(buffer_info);
  buffer_info.usage = SDL_GPU_BUFFERUSAGE_VERTEX;
  buffer_info.size = size;
  frame->quad_vertex_buffer = SDL_CreateGPUBuffer(device, &buffer_info);
  if (!frame->quad_vertex_buffer)
    gpu_abort("SDL_CreateGPUBuffer failed for texture quads");

  SDL_GPUTransferBufferCreateInfo transfer_info;
  SDL_zero(transfer_info);
  transfer_info.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
  transfer_info.size = size;
  frame->quad_transfer = SDL_CreateGPUTransferBuffer(device, &transfer_info);
  if (!frame->quad_transfer)
    gpu_abort("SDL_CreateGPUTransferBuffer failed for texture quads");

  frame->quad_vertex_buffer_size = size;
  frame->quad_transfer_size = size;
}

static void gpu_ensure_window_rect_buffers(GpuWindowData *data, Uint32 size) {
  if (data->rect_vertex_buffer && data->rect_transfer &&
      data->rect_vertex_buffer_size >= size && data->rect_transfer_size >= size)
    return;

  if (data->rect_vertex_buffer)
    SDL_ReleaseGPUBuffer(data->device, data->rect_vertex_buffer);
  if (data->rect_transfer)
    SDL_ReleaseGPUTransferBuffer(data->device, data->rect_transfer);
  data->rect_vertex_buffer = NULL;
  data->rect_transfer = NULL;
  data->rect_vertex_buffer_size = 0;
  data->rect_transfer_size = 0;

  SDL_GPUBufferCreateInfo buffer_info;
  SDL_zero(buffer_info);
  buffer_info.usage = SDL_GPU_BUFFERUSAGE_VERTEX;
  buffer_info.size = size;
  data->rect_vertex_buffer = SDL_CreateGPUBuffer(data->device, &buffer_info);
  if (!data->rect_vertex_buffer)
    gpu_abort("SDL_CreateGPUBuffer failed for rect vertices");

  SDL_GPUTransferBufferCreateInfo transfer_info;
  SDL_zero(transfer_info);
  transfer_info.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
  transfer_info.size = size;
  data->rect_transfer = SDL_CreateGPUTransferBuffer(data->device, &transfer_info);
  if (!data->rect_transfer)
    gpu_abort("SDL_CreateGPUTransferBuffer failed for rect vertices");

  data->rect_vertex_buffer_size = size;
  data->rect_transfer_size = size;
}

static Uint32 gpu_align_u32(Uint32 value, Uint32 alignment) {
  return (value + alignment - 1) & ~(alignment - 1);
}

static Uint32 gpu_grow_upload_size(Uint32 current, Uint32 required, Uint32 minimum) {
  Uint32 size = current > minimum ? current : minimum;
  while (size < required) {
    if (size > SDL_MAX_UINT32 / 2)
      return required;
    size *= 2;
  }
  return size;
}

static bool gpu_batch_material_equal(GpuBatchMaterial a, GpuBatchMaterial b) {
  return a.pipeline == b.pipeline &&
    a.texture == b.texture &&
    a.sampler == b.sampler &&
    a.glyph_format == b.glyph_format;
}

static GpuBatchRun *gpu_batch_append_run(
  GpuBatchRun *runs, int *run_count, GpuBatchMaterial material, Uint32 first_vertex
) {
  if (*run_count == 0 || !gpu_batch_material_equal(runs[*run_count - 1].material, material)) {
    runs[(*run_count)++] = (GpuBatchRun) {
      .material = material,
      .first_vertex = first_vertex,
      .vertex_count = 0,
    };
  }
  return &runs[*run_count - 1];
}

static GpuBatchRun *gpu_batch_append_new_run(
  GpuBatchRun *runs, int *run_count, GpuBatchMaterial material, Uint32 first_vertex
) {
  runs[(*run_count)++] = (GpuBatchRun) {
    .material = material,
    .first_vertex = first_vertex,
    .vertex_count = 0,
  };
  return &runs[*run_count - 1];
}

/* Grow *array so it can hold at least `count` elements of `elem_size`, doubling
** capacity from `initial`. On success updates *array and *capacity and returns
** true; on allocation failure leaves both untouched and returns false.
** Centralizes the realloc/double/NULL-check idiom used by the scratch and
** pending-command buffers below. */
static bool gpu_grow_buffer(void **array, int *capacity, int count,
                            size_t elem_size, int initial) {
  if (count <= *capacity)
    return true;
  int cap = *capacity ? *capacity : initial;
  while (cap < count)
    cap *= 2;
  void *grown = SDL_realloc(*array, (size_t) cap * elem_size);
  if (!grown)
    return false;
  *array = grown;
  *capacity = cap;
  return true;
}

static GpuBatchRun *gpu_ensure_batch_runs(GpuFrameBridge *frame, int count) {
  if (count <= 0)
    return NULL;
  if (!gpu_grow_buffer((void **) &frame->batch_runs, &frame->batch_run_capacity,
                       count, sizeof(GpuBatchRun), 64)) {
    fprintf(stderr, "Error allocating SDL GPU batch runs\n");
    exit(1);
  }
  return frame->batch_runs;
}

static bool gpu_ensure_poly_point_scratch(GpuFrameBridge *frame, int count) {
  return gpu_grow_buffer((void **) &frame->poly_points, &frame->poly_point_capacity,
                         count, sizeof(RenPoint), 32);
}

static bool gpu_ensure_poly_vertex_scratch(GpuFrameBridge *frame, int count) {
  return gpu_grow_buffer((void **) &frame->poly_vertices, &frame->poly_vertex_capacity,
                         count, sizeof(GpuPolyVertex), 32);
}

static bool gpu_ensure_poly_index_scratch(GpuFrameBridge *frame, int count) {
  return gpu_grow_buffer((void **) &frame->poly_indices, &frame->poly_index_capacity,
                         count, sizeof(int), 32);
}

static SDL_GPURenderPass *gpu_begin_configured_render_pass(
  SDL_GPUCommandBuffer *cmd, SDL_GPUTexture *texture, int width, int height, const SDL_Rect *scissor,
  SDL_GPULoadOp load_op, SDL_FColor clear_color, bool cycle
) {
  SDL_GPUColorTargetInfo color_target;
  SDL_zero(color_target);
  color_target.texture = texture;
  color_target.clear_color = clear_color;
  color_target.load_op = load_op;
  color_target.store_op = SDL_GPU_STOREOP_STORE;
  color_target.cycle = cycle;

  SDL_GPURenderPass *pass = SDL_BeginGPURenderPass(cmd, &color_target, 1, NULL);

  SDL_GPUViewport viewport;
  SDL_zero(viewport);
  viewport.w = width;
  viewport.h = height;
  viewport.max_depth = 1;
  SDL_SetGPUViewport(pass, &viewport);
  if (scissor)
    SDL_SetGPUScissor(pass, scissor);
  return pass;
}

static SDL_GPURenderPass *gpu_begin_target_render_pass(
  SDL_GPUCommandBuffer *cmd, SDL_GPUTexture *texture, int width, int height, const SDL_Rect *scissor
) {
  return gpu_begin_configured_render_pass(
    cmd, texture, width, height, scissor, SDL_GPU_LOADOP_LOAD, (SDL_FColor) { 0 }, false
  );
}

static SDL_GPURenderPass *gpu_begin_batch_render_pass(
  SDL_GPUCommandBuffer *cmd, SDL_GPUTexture *texture, int width, int height, const SDL_Rect *scissor
) {
  SDL_GPURenderPass *pass = gpu_begin_target_render_pass(cmd, texture, width, height, scissor);
  GpuPolyVertexUniforms vertex_uniforms = {
    .target = { width, height, 0, 0 },
  };
  SDL_PushGPUVertexUniformData(cmd, 0, &vertex_uniforms, sizeof(vertex_uniforms));
  return pass;
}

static void gpu_upload_batch_vertices(
  SDL_GPUCommandBuffer *cmd, SDL_GPUTransferBuffer *transfer, SDL_GPUBuffer *buffer, Uint32 size
) {
  SDL_GPUCopyPass *copy_pass = SDL_BeginGPUCopyPass(cmd);
  SDL_GPUTransferBufferLocation source;
  SDL_zero(source);
  source.transfer_buffer = transfer;
  SDL_GPUBufferRegion destination;
  SDL_zero(destination);
  destination.buffer = buffer;
  destination.size = size;
  SDL_UploadToGPUBuffer(copy_pass, &source, &destination, true);
  SDL_EndGPUCopyPass(copy_pass);
}

static void gpu_bind_batch_vertex_buffer(SDL_GPURenderPass *pass, SDL_GPUBuffer *buffer) {
  SDL_GPUBufferBinding binding;
  SDL_zero(binding);
  binding.buffer = buffer;
  SDL_BindGPUVertexBuffers(pass, 0, &binding, 1);
}

static SDL_GPUGraphicsPipeline *gpu_batch_pipeline_for_material(GpuBatchMaterial material) {
  switch (material.pipeline) {
    case GPU_BATCH_PIPELINE_TEXT:
      return gpu_text_batch_pipeline;
    case GPU_BATCH_PIPELINE_CANVAS_BLEND:
      return gpu_canvas_batch_pipeline;
    case GPU_BATCH_PIPELINE_CANVAS_REPLACE:
      return gpu_canvas_batch_replace_pipeline;
    case GPU_BATCH_PIPELINE_RECT_BLEND:
      return gpu_rect_pipeline;
    case GPU_BATCH_PIPELINE_RECT_REPLACE:
      return gpu_rect_replace_pipeline;
    case GPU_BATCH_PIPELINE_POLY:
      return gpu_poly_pipeline;
  }
  return NULL;
}

static void gpu_bind_batch_pipeline(
  SDL_GPURenderPass *pass, GpuBatchMaterial material, SDL_GPUGraphicsPipeline **bound_pipeline
) {
  SDL_GPUGraphicsPipeline *pipeline = gpu_batch_pipeline_for_material(material);
  if (*bound_pipeline != pipeline) {
    SDL_BindGPUGraphicsPipeline(pass, pipeline);
    *bound_pipeline = pipeline;
  }
}

static void gpu_bind_fragment_sampler(
  SDL_GPURenderPass *pass, SDL_GPUTexture *texture, SDL_GPUSampler *sampler
) {
  SDL_GPUTextureSamplerBinding binding;
  SDL_zero(binding);
  binding.texture = texture;
  binding.sampler = sampler;
  SDL_BindGPUFragmentSamplers(pass, 0, &binding, 1);
}

static void gpu_color_to_float(RenColor color, float out[4]) {
  out[0] = (float) color.r / 255.0f;
  out[1] = (float) color.g / 255.0f;
  out[2] = (float) color.b / 255.0f;
  out[3] = (float) color.a / 255.0f;
}

static Uint32 gpu_emit_rect_instance(GpuRectInstance *instance, SDL_Rect rect, const float color[4]) {
  instance->dst[0] = rect.x;
  instance->dst[1] = rect.y;
  instance->dst[2] = rect.w;
  instance->dst[3] = rect.h;
  instance->color[0] = color[0];
  instance->color[1] = color[1];
  instance->color[2] = color[2];
  instance->color[3] = color[3];
  return 1;
}

static Uint32 gpu_emit_text_instance(
  GpuTextBatchInstance *instance, SDL_Rect dst, float u0, float v0, float u1, float v1, const float color[4]
) {
  instance->dst[0] = dst.x;
  instance->dst[1] = dst.y;
  instance->dst[2] = dst.w;
  instance->dst[3] = dst.h;
  instance->uv[0] = u0;
  instance->uv[1] = v0;
  instance->uv[2] = u1;
  instance->uv[3] = v1;
  instance->color[0] = color[0];
  instance->color[1] = color[1];
  instance->color[2] = color[2];
  instance->color[3] = color[3];
  return 1;
}

static Uint32 gpu_emit_texture_quad(
  GpuTextureQuadVertex *vertices, SDL_Rect dst, float u0, float v0, float u1, float v1
) {
  float x0 = dst.x;
  float y0 = dst.y;
  float x1 = dst.x + dst.w;
  float y1 = dst.y + dst.h;
  vertices[0] = (GpuTextureQuadVertex) { x0, y0, u0, v0 };
  vertices[1] = (GpuTextureQuadVertex) { x1, y0, u1, v0 };
  vertices[2] = (GpuTextureQuadVertex) { x1, y1, u1, v1 };
  vertices[3] = (GpuTextureQuadVertex) { x0, y0, u0, v0 };
  vertices[4] = (GpuTextureQuadVertex) { x1, y1, u1, v1 };
  vertices[5] = (GpuTextureQuadVertex) { x0, y1, u0, v1 };
  return 6;
}

static bool gpu_color_equal(RenColor a, RenColor b) {
  return a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a;
}

static bool gpu_rect_equal(SDL_Rect a, SDL_Rect b) {
  return a.x == b.x && a.y == b.y && a.w == b.w && a.h == b.h;
}

static bool gpu_rects_overlap(SDL_Rect a, SDL_Rect b) {
  return a.x < b.x + b.w && b.x < a.x + a.w &&
    a.y < b.y + b.h && b.y < a.y + a.h;
}

static bool gpu_try_merge_rect(SDL_Rect *dst, SDL_Rect src, RenColor color) {
  if (!dst || dst->w <= 0 || dst->h <= 0 || src.w <= 0 || src.h <= 0)
    return false;

  bool overlaps = gpu_rects_overlap(*dst, src);
  if (overlaps && color.a != 255)
    return false;

  if (dst->y == src.y && dst->h == src.h) {
    int dst_x2 = dst->x + dst->w;
    int src_x2 = src.x + src.w;
    if (src.x <= dst_x2 && dst->x <= src_x2) {
      int x1 = SDL_min(dst->x, src.x);
      int x2 = SDL_max(dst_x2, src_x2);
      dst->x = x1;
      dst->w = x2 - x1;
      return true;
    }
  }

  if (dst->x == src.x && dst->w == src.w) {
    int dst_y2 = dst->y + dst->h;
    int src_y2 = src.y + src.h;
    if (src.y <= dst_y2 && dst->y <= src_y2) {
      int y1 = SDL_min(dst->y, src.y);
      int y2 = SDL_max(dst_y2, src_y2);
      dst->y = y1;
      dst->h = y2 - y1;
      return true;
    }
  }

  return false;
}

static GpuBatchMaterial gpu_text_batch_material(SDL_GPUTexture *texture, unsigned char format) {
  return (GpuBatchMaterial) {
    .pipeline = GPU_BATCH_PIPELINE_TEXT,
    .texture = texture,
    .sampler = gpu_text_sampler,
    .glyph_format = format,
  };
}

static GpuBatchMaterial gpu_canvas_batch_material(SDL_GPUTexture *texture, GpuTextureBatchMode mode) {
  return (GpuBatchMaterial) {
    .pipeline = mode == GPU_TEXTURE_BATCH_REPLACE
      ? GPU_BATCH_PIPELINE_CANVAS_REPLACE
      : GPU_BATCH_PIPELINE_CANVAS_BLEND,
    .texture = texture,
    .sampler = gpu_canvas_sampler,
    .glyph_format = 0,
  };
}

static GpuBatchMaterial gpu_rect_batch_material(bool replace) {
  return (GpuBatchMaterial) {
    .pipeline = replace ? GPU_BATCH_PIPELINE_RECT_REPLACE : GPU_BATCH_PIPELINE_RECT_BLEND,
    .texture = NULL,
    .sampler = NULL,
    .glyph_format = 0,
  };
}

static GpuBatchMaterial gpu_poly_batch_material(void) {
  return (GpuBatchMaterial) {
    .pipeline = GPU_BATCH_PIPELINE_POLY,
    .texture = NULL,
    .sampler = NULL,
    .glyph_format = 0,
  };
}

static RenRect gpu_clip_surface_rect(SDL_Surface *surface, RenRect rect) {
  int x1 = SDL_clamp(rect.x, 0, surface->w);
  int y1 = SDL_clamp(rect.y, 0, surface->h);
  int x2 = SDL_clamp(rect.x + rect.width, x1, surface->w);
  int y2 = SDL_clamp(rect.y + rect.height, y1, surface->h);
  return (RenRect) { x1, y1, x2 - x1, y2 - y1 };
}

static int gpu_floor_to_int(double value) {
  int result = (int) value;
  return value < (double) result ? result - 1 : result;
}

static int gpu_ceil_to_int(double value) {
  int result = (int) value;
  return value > (double) result ? result + 1 : result;
}

static SDL_Rect gpu_pixel_rect_from_ren_rect(SDL_Surface *surface, RenRect rect) {
  RenRect clipped = gpu_clip_surface_rect(surface, rect);
  const int x1 = SDL_clamp(gpu_floor_to_int(clipped.x), 0, surface->w);
  const int y1 = SDL_clamp(gpu_floor_to_int(clipped.y), 0, surface->h);
  const int x2 = SDL_clamp(gpu_ceil_to_int(clipped.x + clipped.width), x1, surface->w);
  const int y2 = SDL_clamp(gpu_ceil_to_int(clipped.y + clipped.height), y1, surface->h);
  return (SDL_Rect) {.x = x1, .y = y1, .w = x2 - x1, .h = y2 - y1};
}

static SDL_Rect gpu_pixel_rect_from_ren_rect_unclipped(RenRect rect) {
  const int x1 = gpu_floor_to_int(rect.x);
  const int y1 = gpu_floor_to_int(rect.y);
  const int x2 = gpu_ceil_to_int(rect.x + rect.width);
  const int y2 = gpu_ceil_to_int(rect.y + rect.height);
  return (SDL_Rect) {.x = x1, .y = y1, .w = x2 - x1, .h = y2 - y1};
}

static bool gpu_intersect_sdl_rect(SDL_Rect a, SDL_Rect b, SDL_Rect *out) {
  int x1 = SDL_max(a.x, b.x);
  int y1 = SDL_max(a.y, b.y);
  int x2 = SDL_min(a.x + a.w, b.x + b.w);
  int y2 = SDL_min(a.y + a.h, b.y + b.h);
  if (x2 <= x1 || y2 <= y1)
    return false;
  *out = (SDL_Rect) { .x = x1, .y = y1, .w = x2 - x1, .h = y2 - y1 };
  return true;
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

static bool gpu_atlas_use_tight_texture(GlyphMetric *metric) {
  return metric->x1 >= 64 || metric->y1 - metric->y0 >= 64;
}

static GpuAtlasTexture *gpu_atlas_find_texture(GpuAtlasData *data, SDL_Surface *surface, GlyphMetric *metric) {
  bool tight_texture = gpu_atlas_use_tight_texture(metric);
  for (size_t i = 0; i < data->texture_count; i++) {
    GpuAtlasTexture *texture = &data->textures[i];
    if (texture->format == metric->format &&
        texture->atlas_idx == metric->atlas_idx &&
        texture->surface_idx == metric->surface_idx &&
        texture->x1 == (tight_texture ? metric->x1 : (unsigned int) surface->w) &&
        texture->y0 == (tight_texture ? metric->y0 : 0) &&
        texture->y1 == (tight_texture ? metric->y1 : (unsigned int) surface->h))
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
  texture->x1 = tight_texture ? metric->x1 : (unsigned int) surface->w;
  texture->y0 = tight_texture ? metric->y0 : 0;
  texture->y1 = tight_texture ? metric->y1 : (unsigned int) surface->h;
  return texture;
}

static GpuAtlasTexture *gpu_atlas_lookup_texture(RenAtlas *atlas, GlyphMetric *metric) {
  GpuAtlasData *data = atlas->data;
  if (!data)
    return NULL;
  bool tight_texture = gpu_atlas_use_tight_texture(metric);
  for (size_t i = 0; i < data->texture_count; i++) {
    GpuAtlasTexture *texture = &data->textures[i];
    if (texture->format != metric->format ||
        texture->atlas_idx != metric->atlas_idx ||
        texture->surface_idx != metric->surface_idx)
      continue;
    if (tight_texture &&
        texture->x1 == metric->x1 &&
        texture->y0 == metric->y0 &&
        texture->y1 == metric->y1)
      return texture;
    if (!tight_texture &&
        texture->x1 >= metric->x1 &&
        texture->y0 == 0 &&
        texture->y1 >= metric->y1)
      return texture;
  }
  return NULL;
}

static bool gpu_atlas_texture_ready(GpuAtlasTexture *texture) {
  return texture && texture->texture && texture->texture_w > 0 && texture->texture_h > 0;
}

static void gpu_atlas_ensure_texture(SDL_GPUDevice *device, GpuAtlasTexture *texture) {
  int width = texture->x1;
  int height = texture->y1 - texture->y0;
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

  size = gpu_grow_upload_size(texture->transfer_size, size, 16 * 1024);

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
  int texture_y0,
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
  source.y = metric->y0 - texture_y0;
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

  GpuAtlasTexture *texture = gpu_atlas_find_texture(data, surface, metric);
  gpu_atlas_ensure_texture(data->device, texture);

  Uint32 row_stride = 0;
  Uint32 upload_size = gpu_atlas_upload_size(surface, metric, &row_stride);
  if (upload_size == 0)
    return;
  gpu_atlas_ensure_transfer(data->device, texture, upload_size);
  SDL_GPUTransferBuffer *transfer = texture->transfer;

  SDL_GPUCommandBuffer *cmd = NULL;
  bool submit_upload = false;
  if (gpu_active_frame_device == data->device && gpu_active_frame_command_buffer) {
    cmd = gpu_active_frame_command_buffer;
  } else {
    cmd = SDL_AcquireGPUCommandBuffer(data->device);
    if (!cmd)
      gpu_abort("SDL_AcquireGPUCommandBuffer failed");
    submit_upload = true;
  }

  if (!SDL_LockSurface(surface))
    gpu_abort("SDL_LockSurface failed");

  void *map = SDL_MapGPUTransferBuffer(data->device, transfer, true);
  if (!map) {
    SDL_UnlockSurface(surface);
    gpu_abort("SDL_MapGPUTransferBuffer failed");
  }

  gpu_atlas_copy_glyph_to_transfer(surface, metric, map, row_stride);
  SDL_UnmapGPUTransferBuffer(data->device, transfer);
  SDL_UnlockSurface(surface);

  SDL_GPUCopyPass *copy_pass = SDL_BeginGPUCopyPass(cmd);
  SDL_GPUTextureTransferInfo source;
  SDL_zero(source);
  source.transfer_buffer = transfer;
  source.pixels_per_row = row_stride / ren_glyphformat_bytes_per_pixel(EGlyphFormatColor);
  source.rows_per_layer = metric->y1 - metric->y0;

  SDL_GPUTextureRegion destination;
  SDL_zero(destination);
  destination.texture = texture->texture;
  destination.x = 0;
  destination.y = metric->y0 - texture->y0;
  destination.w = metric->x1;
  destination.h = metric->y1 - metric->y0;
  destination.d = 1;

  SDL_UploadToGPUTexture(copy_pass, &source, &destination, false);
  SDL_EndGPUCopyPass(copy_pass);

  if (submit_upload) {
    bool submitted = gpu_validate_atlas_upload(
      data->device, texture->texture, surface, metric, texture->y0, cmd, row_stride
    );
    if (!submitted) {
      if (!SDL_SubmitGPUCommandBuffer(cmd)) {
        gpu_abort("SDL_SubmitGPUCommandBuffer failed");
      }
    }
  }

  gpu_atlas_update_bytesize(atlas);
}

static GpuAtlasTexture *gpu_ensure_native_glyph_texture(
  GpuWindowData *data, RenAtlas *atlas, GlyphMetric *metric
) {
  if (!atlas || !metric)
    return NULL;

  GpuAtlasTexture *texture = gpu_atlas_lookup_texture(atlas, metric);
  if (gpu_atlas_texture_ready(texture))
    return texture;

  if (data && data->pending_text_glyph_count > 0 && !gpu_flush_pending_text_barrier(data))
    return NULL;

  gpu_atlas_glyph_updated(atlas, metric);
  texture = gpu_atlas_lookup_texture(atlas, metric);
  return gpu_atlas_texture_ready(texture) ? texture : NULL;
}

static void gpu_atlas_clear(RenAtlas *atlas) {
  GpuAtlasData *data = atlas->data;
  if (!data) {
    atlas->bytesize = 0;
    return;
  }

  if (gpu_active_frame_device == data->device && gpu_active_frame_window_data &&
      !gpu_flush_pending_text_barrier(gpu_active_frame_window_data))
    gpu_abort("SDLGPU native text flush before atlas clear failed");

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

static bool gpu_queue_window_native_rect(RenCache *rc, RenSurface *surface, RenRect rect, RenColor color, bool replace) {
  if (!rc->window_target || !surface->surface)
    return false;

  RenWindow *ren = rc->target;
  GpuWindowData *data = ren->backend_data;
  if (!data || !data->command_buffer)
    return false;

  SDL_Rect dst = gpu_pixel_rect_from_ren_rect_unclipped(rect);
  if (dst.w == 0 || dst.h == 0)
    return true;

  SDL_Rect clip = data->have_native_clip_rect
    ? data->native_clip_rect
    : (SDL_Rect) { .x = 0, .y = 0, .w = surface->surface->w, .h = surface->surface->h };

  if (!gpu_intersect_sdl_rect(dst, clip, &dst))
    return true;

  if (data->pending_native_rect_count > 0) {
    GpuNativeRect *last = &data->pending_native_rects[data->pending_native_rect_count - 1];
    if (last->replace == replace && gpu_color_equal(last->color, color) &&
        gpu_try_merge_rect(&last->rect, dst, color)) {
      data->stats_native_rects++;
      return true;
    }
  }

  if (data->pending_native_rect_count >= GPU_NATIVE_RECT_BATCH_SIZE) {
    if (!gpu_flush_window_native_rects(data, data->command_buffer))
      gpu_abort("SDLGPU native rect batch flush failed");
  }

  data->pending_native_rects[data->pending_native_rect_count++] = (GpuNativeRect) {
    .rect = dst,
    .color = color,
    .replace = replace,
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

static bool gpu_queue_window_pixels(
  GpuWindowData *data,
  SDL_Rect dst,
  RenRect source_rect,
  const char *bytes
) {
  if (!data || !bytes || dst.w <= 0 || dst.h <= 0)
    return false;

  const int bytes_per_pixel = 4;
  Uint32 row_size = (Uint32) dst.w * bytes_per_pixel;
  Uint32 row_stride = gpu_align_u32(row_size, GPU_TEXTURE_ROW_ALIGNMENT);
  Uint32 transfer_offset = gpu_align_u32(data->pending_pixel_bytes_size, GPU_TEXTURE_OFFSET_ALIGNMENT);
  Uint32 upload_size = row_stride * (Uint32) dst.h;
  Uint32 required_size = transfer_offset + upload_size;

  if (required_size > data->pending_pixel_bytes_capacity) {
    Uint32 capacity = data->pending_pixel_bytes_capacity ? data->pending_pixel_bytes_capacity * 2 : 65536;
    while (capacity < required_size)
      capacity *= 2;
    Uint8 *bytes_buffer = SDL_realloc(data->pending_pixel_bytes, capacity);
    if (!bytes_buffer) {
      fprintf(stderr, "Error allocating SDL GPU pending pixel bytes\n");
      exit(1);
    }
    data->pending_pixel_bytes = bytes_buffer;
    data->pending_pixel_bytes_capacity = capacity;
  }

  if (transfer_offset > data->pending_pixel_bytes_size) {
    SDL_memset(
      data->pending_pixel_bytes + data->pending_pixel_bytes_size,
      0,
      transfer_offset - data->pending_pixel_bytes_size
    );
  }

  const Uint64 source_pitch = (Uint64) source_rect.width * bytes_per_pixel;
  const int src_x = dst.x - source_rect.x;
  const int src_y = dst.y - source_rect.y;
  const Uint8 *src = (const Uint8 *) bytes + (Uint64) src_y * source_pitch + (Uint64) src_x * bytes_per_pixel;
  Uint8 *out = data->pending_pixel_bytes + transfer_offset;
  for (int y = 0; y < dst.h; y++) {
    SDL_memcpy(out, src, row_size);
    src += source_pitch;
    out += row_stride;
  }
  data->pending_pixel_bytes_size = required_size;

  if (!gpu_grow_buffer((void **) &data->pending_pixels, &data->pending_pixel_capacity,
                       data->pending_pixel_count + 1, sizeof(GpuQueuedPixels), 32)) {
    fprintf(stderr, "Error allocating SDL GPU pending pixel commands\n");
    exit(1);
  }

  data->pending_pixels[data->pending_pixel_count++] = (GpuQueuedPixels) {
    .dst = dst,
    .transfer_offset = transfer_offset,
    .row_stride = row_stride,
    .atlas_y = (Uint32) data->pending_pixels_texture_h,
  };
  data->pending_pixels_texture_w = SDL_max(data->pending_pixels_texture_w, dst.w);
  data->pending_pixels_texture_h += dst.h;
  return true;
}

static bool gpu_flush_queued_pixels(GpuWindowData *data, SDL_GPUCommandBuffer *cmd) {
  if (!data || data->pending_pixel_count == 0)
    return true;
  if (!cmd || !data->frame.texture || data->pending_pixel_bytes_size == 0)
    return false;
  if (!gpu_ensure_canvas_batch_replace_pipeline(data->device))
    return false;
  if (!gpu_ensure_pixels_texture(data, data->pending_pixels_texture_w, data->pending_pixels_texture_h))
    return false;
  if (!gpu_ensure_pixels_transfer(data, data->pending_pixel_bytes_size))
    return false;

  Uint8 *map = SDL_MapGPUTransferBuffer(data->device, data->pixels_transfer, true);
  if (!map)
    return false;
  SDL_memcpy(map, data->pending_pixel_bytes, data->pending_pixel_bytes_size);
  SDL_UnmapGPUTransferBuffer(data->device, data->pixels_transfer);

  SDL_GPUCopyPass *copy_pass = SDL_BeginGPUCopyPass(cmd);
  for (int i = 0; i < data->pending_pixel_count; i++) {
    GpuQueuedPixels *pixels = &data->pending_pixels[i];
    SDL_GPUTextureTransferInfo source_info;
    SDL_zero(source_info);
    source_info.transfer_buffer = data->pixels_transfer;
    source_info.offset = pixels->transfer_offset;
    source_info.pixels_per_row = pixels->row_stride / 4;
    source_info.rows_per_layer = pixels->dst.h;

    SDL_GPUTextureRegion destination;
    SDL_zero(destination);
    destination.texture = data->pixels_texture;
    destination.y = pixels->atlas_y;
    destination.w = pixels->dst.w;
    destination.h = pixels->dst.h;
    destination.d = 1;
    SDL_UploadToGPUTexture(copy_pass, &source_info, &destination, false);
  }
  SDL_EndGPUCopyPass(copy_pass);

  Uint32 max_vertices = (Uint32) data->pending_pixel_count * 6;
  Uint32 vertex_upload_size = max_vertices * sizeof(GpuTextureQuadVertex);
  gpu_ensure_bridge_quad_buffers(data->device, &data->frame, vertex_upload_size);

  GpuTextureQuadVertex *vertices = SDL_MapGPUTransferBuffer(data->device, data->frame.quad_transfer, true);
  if (!vertices)
    return false;

  Uint32 vertex_count = 0;
  for (int i = 0; i < data->pending_pixel_count; i++) {
    GpuQueuedPixels *pixels = &data->pending_pixels[i];
    float u0 = 0.0f;
    float v0 = (float) pixels->atlas_y / (float) data->pixels_texture_h;
    float u1 = (float) pixels->dst.w / (float) data->pixels_texture_w;
    float v1 = (float) (pixels->atlas_y + pixels->dst.h) / (float) data->pixels_texture_h;
    vertex_count += gpu_emit_texture_quad(vertices + vertex_count, pixels->dst, u0, v0, u1, v1);
  }
  SDL_UnmapGPUTransferBuffer(data->device, data->frame.quad_transfer);

  if (vertex_count > 0) {
    gpu_upload_batch_vertices(
      cmd, data->frame.quad_transfer, data->frame.quad_vertex_buffer, vertex_count * sizeof(GpuTextureQuadVertex)
    );

    SDL_Rect target_clip = { .x = 0, .y = 0, .w = data->frame.texture_w, .h = data->frame.texture_h };
    SDL_GPURenderPass *pass = gpu_begin_batch_render_pass(
      cmd, data->frame.texture, data->frame.texture_w, data->frame.texture_h, &target_clip
    );
    SDL_GPUGraphicsPipeline *bound_pipeline = NULL;
    gpu_bind_batch_pipeline(
      pass, gpu_canvas_batch_material(data->pixels_texture, GPU_TEXTURE_BATCH_REPLACE), &bound_pipeline
    );
    gpu_bind_batch_vertex_buffer(pass, data->frame.quad_vertex_buffer);

    gpu_bind_fragment_sampler(pass, data->pixels_texture, gpu_canvas_sampler);
    SDL_DrawGPUPrimitives(pass, vertex_count, 1, 0, 0);
    SDL_EndGPURenderPass(pass);
  }

  data->pending_pixel_count = 0;
  data->pending_pixel_bytes_size = 0;
  data->pending_pixels_texture_w = 0;
  data->pending_pixels_texture_h = 0;
  data->frame_synced_during_replay = true;
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

  if (!gpu_flush_window_batches(data, GPU_BATCH_QUEUE_ALL & ~GPU_BATCH_QUEUE_PIXELS))
    gpu_abort("SDLGPU native batch flush before pixels failed");

  if (!gpu_queue_window_pixels(data, dst, rect, bytes))
    return false;
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

static bool gpu_append_flat_poly_point(GpuFrameBridge *frame, int *count, float x, float y) {
  if (*count > 0) {
    RenPoint *last = &frame->poly_points[*count - 1];
    if (last->x == (int) lroundf(x) && last->y == (int) lroundf(y))
      return true;
  }

  if (!gpu_ensure_poly_point_scratch(frame, *count + 1))
    return false;

  frame->poly_points[*count] = (RenPoint) {
    .x = (int) lroundf(x),
    .y = (int) lroundf(y),
    .tag = POLY_NORMAL,
  };
  (*count)++;
  return true;
}

static bool gpu_flatten_poly(
  GpuFrameBridge *frame, RenPoint *points, unsigned short npoints, unsigned short *flat_count
) {
  *flat_count = 0;
  if (!frame || npoints < 3 || points[0].tag != POLY_NORMAL)
    return false;

  int count = 0;
  if (!gpu_append_flat_poly_point(frame, &count, points[0].x, points[0].y))
    return false;

  const int segments = 12;
  for (unsigned short i = 1; i < npoints; i++) {
    RenPoint p0 = frame->poly_points[count - 1];
    RenPoint p1 = points[i];

    if (p1.tag == POLY_NORMAL) {
      if (!gpu_append_flat_poly_point(frame, &count, p1.x, p1.y))
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
        if (!gpu_append_flat_poly_point(frame, &count, x, y))
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
        if (!gpu_append_flat_poly_point(frame, &count, x, y))
          goto error;
      }
      continue;
    }

    goto error;
  }

  if (count > 1 &&
      frame->poly_points[0].x == frame->poly_points[count - 1].x &&
      frame->poly_points[0].y == frame->poly_points[count - 1].y)
    count--;
  if (count < 3 || count > MAX_POLY_POINTS)
    goto error;

  *flat_count = (unsigned short) count;
  return true;

error:
  *flat_count = 0;
  return false;
}

static int gpu_triangulate_line_poly(
  GpuFrameBridge *frame, RenPoint *points, unsigned short npoints,
  GpuPolyVertex *vertices, float scale_x, float scale_y
) {
  if (npoints < 3)
    return 0;
  if (!gpu_ensure_poly_index_scratch(frame, npoints))
    gpu_abort("Error allocating polygon triangulation indices");

  int *indices = frame->poly_indices;
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

  gpu_upload_batch_vertices(cmd, frame->poly_transfer, frame->poly_vertex_buffer, upload_size);

  SDL_Rect scissor = gpu_pixel_rect_from_ren_rect(surface, bounds);
  SDL_Rect clip;
  if (!SDL_GetSurfaceClipRect(surface, &clip))
    return false;
  if (!SDL_GetRectIntersection(&scissor, &clip, &scissor) || scissor.w <= 0 || scissor.h <= 0)
    return true;

  SDL_GPURenderPass *pass = gpu_begin_batch_render_pass(
    cmd, frame->texture, frame->texture_w, frame->texture_h, &scissor
  );
  SDL_GPUGraphicsPipeline *bound_pipeline = NULL;
  gpu_bind_batch_pipeline(pass, gpu_poly_batch_material(), &bound_pipeline);

  gpu_bind_batch_vertex_buffer(pass, frame->poly_vertex_buffer);

  GpuPolyFragmentUniforms fragment_uniforms;
  gpu_color_to_float(color, fragment_uniforms.color);
  SDL_PushGPUFragmentUniformData(cmd, 0, &fragment_uniforms, sizeof(fragment_uniforms));
  SDL_DrawGPUPrimitives(pass, vertex_count, 1, 0, 0);
  SDL_EndGPURenderPass(pass);
  return true;
}

static bool gpu_queue_window_native_poly(
  GpuWindowData *data, SDL_Rect clip, GpuPolyVertex *vertices, int vertex_count, RenColor color
) {
  if (!data || !vertices || vertex_count <= 0 || clip.w <= 0 || clip.h <= 0)
    return false;

  if (!gpu_grow_buffer((void **) &data->pending_poly_vertices, &data->pending_poly_vertex_capacity,
                       data->pending_poly_vertex_count + vertex_count, sizeof(GpuPolyVertex), 256)) {
    fprintf(stderr, "Error allocating SDL GPU pending polygon vertices\n");
    exit(1);
  }

  Uint32 first_vertex = (Uint32) data->pending_poly_vertex_count;
  SDL_memcpy(
    data->pending_poly_vertices + data->pending_poly_vertex_count,
    vertices,
    (size_t) vertex_count * sizeof(GpuPolyVertex)
  );
  data->pending_poly_vertex_count += vertex_count;

  if (data->pending_poly_count > 0) {
    GpuQueuedPoly *last = &data->pending_polys[data->pending_poly_count - 1];
    if (gpu_color_equal(last->color, color) &&
        gpu_rect_equal(last->clip, clip) &&
        last->first_vertex + last->vertex_count == first_vertex) {
      last->vertex_count += (Uint32) vertex_count;
      return true;
    }
  }

  if (!gpu_grow_buffer((void **) &data->pending_polys, &data->pending_poly_capacity,
                       data->pending_poly_count + 1, sizeof(GpuQueuedPoly), 64)) {
    fprintf(stderr, "Error allocating SDL GPU pending polygons\n");
    exit(1);
  }

  data->pending_polys[data->pending_poly_count++] = (GpuQueuedPoly) {
    .color = color,
    .clip = clip,
    .first_vertex = first_vertex,
    .vertex_count = (Uint32) vertex_count,
  };
  return true;
}

static bool gpu_flush_queued_polys(GpuWindowData *data, SDL_GPUCommandBuffer *cmd) {
  if (!data || data->pending_poly_count == 0)
    return true;
  if (!cmd || !data->frame.texture || data->pending_poly_vertex_count <= 0)
    return false;
  if (!gpu_ensure_poly_pipeline(data->device))
    return false;

  Uint32 upload_size = (Uint32) data->pending_poly_vertex_count * sizeof(GpuPolyVertex);
  gpu_ensure_bridge_poly_buffers(data->device, &data->frame, upload_size);

  GpuPolyVertex *map = SDL_MapGPUTransferBuffer(data->device, data->frame.poly_transfer, true);
  if (!map)
    return false;
  SDL_memcpy(map, data->pending_poly_vertices, upload_size);
  SDL_UnmapGPUTransferBuffer(data->device, data->frame.poly_transfer);

  gpu_upload_batch_vertices(cmd, data->frame.poly_transfer, data->frame.poly_vertex_buffer, upload_size);

  SDL_GPURenderPass *pass = gpu_begin_batch_render_pass(
    cmd, data->frame.texture, data->frame.texture_w, data->frame.texture_h, NULL
  );
  SDL_GPUGraphicsPipeline *bound_pipeline = NULL;
  gpu_bind_batch_pipeline(pass, gpu_poly_batch_material(), &bound_pipeline);

  gpu_bind_batch_vertex_buffer(pass, data->frame.poly_vertex_buffer);

  for (int i = 0; i < data->pending_poly_count; i++) {
    GpuQueuedPoly *poly = &data->pending_polys[i];
    if (poly->vertex_count == 0 || poly->clip.w <= 0 || poly->clip.h <= 0)
      continue;

    GpuPolyFragmentUniforms fragment_uniforms;
    gpu_color_to_float(poly->color, fragment_uniforms.color);
    SDL_SetGPUScissor(pass, &poly->clip);
    SDL_PushGPUFragmentUniformData(cmd, 0, &fragment_uniforms, sizeof(fragment_uniforms));
    SDL_DrawGPUPrimitives(pass, poly->vertex_count, 1, poly->first_vertex, 0);
  }

  SDL_EndGPURenderPass(pass);
  data->pending_poly_count = 0;
  data->pending_poly_vertex_count = 0;
  data->frame_synced_during_replay = true;
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
  if (!gpu_flush_pending_canvas_barrier(data))
    gpu_abort("SDLGPU native canvas flush before poly failed");

  unsigned short flat_count = 0;
  if (!gpu_flatten_poly(&data->frame, points, npoints, &flat_count))
    return false;

  int max_vertices = (flat_count - 2) * 3;
  if (!gpu_ensure_poly_vertex_scratch(&data->frame, max_vertices))
    gpu_abort("Error allocating polygon vertices");
  int vertex_count = gpu_triangulate_line_poly(
    &data->frame, data->frame.poly_points, flat_count, data->frame.poly_vertices,
    surface->scale_x > 0 ? surface->scale_x : 1.0f,
    surface->scale_y > 0 ? surface->scale_y : 1.0f
  );
  if (vertex_count == 0)
    return false;

  if (!gpu_flush_window_batches(
        data,
        GPU_BATCH_QUEUE_RECTS
          | GPU_BATCH_QUEUE_TEXT
          | GPU_BATCH_QUEUE_PIXELS
      ))
    gpu_abort("SDLGPU native batch flush before poly failed");

  bool drawn = gpu_queue_window_native_poly(data, dst, data->frame.poly_vertices, vertex_count, color);
  if (!drawn)
    return false;

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
  if (format & SDL_GPU_SHADERFORMAT_DXIL) {
    createinfo.format = SDL_GPU_SHADERFORMAT_DXIL;
    createinfo.code = vertex ? gpu_canvas_vert_dxil : gpu_canvas_frag_dxil;
    createinfo.code_size = vertex ? gpu_canvas_vert_dxil_len : gpu_canvas_frag_dxil_len;
  } else if (format & SDL_GPU_SHADERFORMAT_DXBC) {
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

static SDL_GPUShader *gpu_create_canvas_batch_shader(SDL_GPUDevice *device, bool vertex) {
  SDL_GPUShaderCreateInfo createinfo;
  SDL_zero(createinfo);
  createinfo.num_samplers = vertex ? 0 : 1;
  createinfo.num_uniform_buffers = vertex ? 1 : 0;
  createinfo.stage = vertex ? SDL_GPU_SHADERSTAGE_VERTEX : SDL_GPU_SHADERSTAGE_FRAGMENT;

  SDL_GPUShaderFormat format = SDL_GetGPUShaderFormats(device);
  if (format & SDL_GPU_SHADERFORMAT_DXIL) {
    createinfo.format = SDL_GPU_SHADERFORMAT_DXIL;
    createinfo.code = vertex ? gpu_canvas_batch_vert_dxil : gpu_canvas_batch_frag_dxil;
    createinfo.code_size = vertex ? gpu_canvas_batch_vert_dxil_len : gpu_canvas_batch_frag_dxil_len;
  } else if (format & SDL_GPU_SHADERFORMAT_DXBC) {
    createinfo.format = SDL_GPU_SHADERFORMAT_DXBC;
    createinfo.code = vertex ? gpu_canvas_batch_vert_dxbc : gpu_canvas_batch_frag_dxbc;
    createinfo.code_size = vertex ? gpu_canvas_batch_vert_dxbc_len : gpu_canvas_batch_frag_dxbc_len;
  } else if (format & SDL_GPU_SHADERFORMAT_MSL) {
    createinfo.format = SDL_GPU_SHADERFORMAT_MSL;
    createinfo.code = vertex ? gpu_canvas_batch_vert_msl : gpu_canvas_batch_frag_msl;
    createinfo.code_size = vertex ? gpu_canvas_batch_vert_msl_len : gpu_canvas_batch_frag_msl_len;
  } else if (format & SDL_GPU_SHADERFORMAT_SPIRV) {
    createinfo.format = SDL_GPU_SHADERFORMAT_SPIRV;
    createinfo.code = vertex ? gpu_canvas_batch_vert_spv : gpu_canvas_batch_frag_spv;
    createinfo.code_size = vertex ? gpu_canvas_batch_vert_spv_len : gpu_canvas_batch_frag_spv_len;
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
  if (format & SDL_GPU_SHADERFORMAT_DXIL) {
    createinfo.format = SDL_GPU_SHADERFORMAT_DXIL;
    createinfo.code = vertex ? gpu_poly_vert_dxil : gpu_poly_frag_dxil;
    createinfo.code_size = vertex ? gpu_poly_vert_dxil_len : gpu_poly_frag_dxil_len;
  } else if (format & SDL_GPU_SHADERFORMAT_DXBC) {
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

static SDL_GPUShader *gpu_create_rect_shader(SDL_GPUDevice *device, bool vertex) {
  SDL_GPUShaderFormat format = SDL_GetGPUShaderFormats(device);
  SDL_GPUShaderCreateInfo createinfo;
  SDL_zero(createinfo);
  createinfo.stage = vertex ? SDL_GPU_SHADERSTAGE_VERTEX : SDL_GPU_SHADERSTAGE_FRAGMENT;
  createinfo.entrypoint = "main";
  createinfo.num_samplers = 0;
  createinfo.num_uniform_buffers = vertex ? 1 : 0;

  if (format & SDL_GPU_SHADERFORMAT_DXIL) {
    createinfo.format = SDL_GPU_SHADERFORMAT_DXIL;
    createinfo.code = vertex ? gpu_rect_vert_dxil : gpu_rect_frag_dxil;
    createinfo.code_size = vertex ? gpu_rect_vert_dxil_len : gpu_rect_frag_dxil_len;
  } else if (format & SDL_GPU_SHADERFORMAT_DXBC) {
    createinfo.format = SDL_GPU_SHADERFORMAT_DXBC;
    createinfo.code = vertex ? gpu_rect_vert_dxbc : gpu_rect_frag_dxbc;
    createinfo.code_size = vertex ? gpu_rect_vert_dxbc_len : gpu_rect_frag_dxbc_len;
  } else if (format & SDL_GPU_SHADERFORMAT_MSL) {
    createinfo.format = SDL_GPU_SHADERFORMAT_MSL;
    createinfo.code = vertex ? gpu_rect_vert_msl : gpu_rect_frag_msl;
    createinfo.code_size = vertex ? gpu_rect_vert_msl_len : gpu_rect_frag_msl_len;
  } else if (format & SDL_GPU_SHADERFORMAT_SPIRV) {
    createinfo.format = SDL_GPU_SHADERFORMAT_SPIRV;
    createinfo.code = vertex ? gpu_rect_vert_spv : gpu_rect_frag_spv;
    createinfo.code_size = vertex ? gpu_rect_vert_spv_len : gpu_rect_frag_spv_len;
  } else {
    return NULL;
  }

  return SDL_CreateGPUShader(device, &createinfo);
}

static SDL_GPUGraphicsPipeline *gpu_create_rect_graphics_pipeline(SDL_GPUDevice *device, bool blend) {
  SDL_GPUShader *vertex_shader = gpu_create_rect_shader(device, true);
  SDL_GPUShader *fragment_shader = gpu_create_rect_shader(device, false);
  if (!vertex_shader || !fragment_shader) {
    if (vertex_shader) SDL_ReleaseGPUShader(device, vertex_shader);
    if (fragment_shader) SDL_ReleaseGPUShader(device, fragment_shader);
    return NULL;
  }

  SDL_GPUVertexBufferDescription vertex_buffer;
  SDL_zero(vertex_buffer);
  vertex_buffer.slot = 0;
  vertex_buffer.pitch = sizeof(GpuRectInstance);
  vertex_buffer.input_rate = SDL_GPU_VERTEXINPUTRATE_INSTANCE;

  SDL_GPUVertexAttribute vertex_attributes[2];
  SDL_zeroa(vertex_attributes);
  vertex_attributes[0].location = 0;
  vertex_attributes[0].buffer_slot = 0;
  vertex_attributes[0].format = SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4;
  vertex_attributes[0].offset = 0;
  vertex_attributes[1].location = 1;
  vertex_attributes[1].buffer_slot = 0;
  vertex_attributes[1].format = SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4;
  vertex_attributes[1].offset = offsetof(GpuRectInstance, color);

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
  pipeline_info.vertex_input_state.vertex_buffer_descriptions = &vertex_buffer;
  pipeline_info.vertex_input_state.num_vertex_buffers = 1;
  pipeline_info.vertex_input_state.vertex_attributes = vertex_attributes;
  pipeline_info.vertex_input_state.num_vertex_attributes = SDL_arraysize(vertex_attributes);
  pipeline_info.target_info.num_color_targets = 1;
  pipeline_info.target_info.color_target_descriptions = &color_target;

  SDL_GPUGraphicsPipeline *pipeline = SDL_CreateGPUGraphicsPipeline(device, &pipeline_info);
  SDL_ReleaseGPUShader(device, vertex_shader);
  SDL_ReleaseGPUShader(device, fragment_shader);
  return pipeline;
}

static bool gpu_ensure_rect_pipeline(SDL_GPUDevice *device) {
  if (gpu_rect_pipeline)
    return true;
  if (gpu_rect_pipeline_failed)
    return false;

  gpu_rect_pipeline = gpu_create_rect_graphics_pipeline(device, true);
  if (!gpu_rect_pipeline) {
    gpu_rect_pipeline_failed = true;
    return false;
  }

  return true;
}

static bool gpu_ensure_rect_replace_pipeline(SDL_GPUDevice *device) {
  if (gpu_rect_replace_pipeline)
    return true;
  if (gpu_rect_pipeline_failed)
    return false;
  if (!gpu_ensure_rect_pipeline(device))
    return false;

  gpu_rect_replace_pipeline = gpu_create_rect_graphics_pipeline(device, false);
  if (!gpu_rect_replace_pipeline) {
    gpu_rect_pipeline_failed = true;
    return false;
  }

  return true;
}

static void gpu_destroy_rect_pipeline(SDL_GPUDevice *device) {
  if (gpu_rect_pipeline) {
    SDL_ReleaseGPUGraphicsPipeline(device, gpu_rect_pipeline);
    gpu_rect_pipeline = NULL;
  }
  if (gpu_rect_replace_pipeline) {
    SDL_ReleaseGPUGraphicsPipeline(device, gpu_rect_replace_pipeline);
    gpu_rect_replace_pipeline = NULL;
  }
  gpu_rect_pipeline_failed = false;
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

static SDL_GPUGraphicsPipeline *gpu_create_canvas_batch_graphics_pipeline(
  SDL_GPUDevice *device, SDL_GPUTextureFormat target_format, bool blend
) {
  SDL_GPUShader *vertex_shader = gpu_create_canvas_batch_shader(device, true);
  SDL_GPUShader *fragment_shader = gpu_create_canvas_batch_shader(device, false);
  if (!vertex_shader || !fragment_shader) {
    if (vertex_shader) SDL_ReleaseGPUShader(device, vertex_shader);
    if (fragment_shader) SDL_ReleaseGPUShader(device, fragment_shader);
    return NULL;
  }

  SDL_GPUVertexBufferDescription vertex_buffer;
  SDL_zero(vertex_buffer);
  vertex_buffer.slot = 0;
  vertex_buffer.pitch = sizeof(GpuTextureQuadVertex);
  vertex_buffer.input_rate = SDL_GPU_VERTEXINPUTRATE_VERTEX;

  SDL_GPUVertexAttribute vertex_attributes[2];
  SDL_zeroa(vertex_attributes);
  vertex_attributes[0].location = 0;
  vertex_attributes[0].buffer_slot = 0;
  vertex_attributes[0].format = SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2;
  vertex_attributes[0].offset = 0;
  vertex_attributes[1].location = 1;
  vertex_attributes[1].buffer_slot = 0;
  vertex_attributes[1].format = SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2;
  vertex_attributes[1].offset = offsetof(GpuTextureQuadVertex, u);

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
  pipeline_info.vertex_input_state.vertex_buffer_descriptions = &vertex_buffer;
  pipeline_info.vertex_input_state.num_vertex_buffers = 1;
  pipeline_info.vertex_input_state.vertex_attributes = vertex_attributes;
  pipeline_info.vertex_input_state.num_vertex_attributes = SDL_arraysize(vertex_attributes);
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

static bool gpu_ensure_canvas_batch_pipeline(SDL_GPUDevice *device) {
  if (gpu_canvas_batch_pipeline && gpu_canvas_sampler)
    return true;
  if (gpu_canvas_pipeline_failed)
    return false;
  if (!gpu_ensure_canvas_pipeline(device))
    return false;

  gpu_canvas_batch_pipeline = gpu_create_canvas_batch_graphics_pipeline(
    device,
    SDL_GetGPUTextureFormatFromPixelFormat(SDL_PIXELFORMAT_BGRA32),
    true
  );
  if (!gpu_canvas_batch_pipeline) {
    gpu_canvas_pipeline_failed = true;
    return false;
  }

  return true;
}

static bool gpu_ensure_canvas_batch_replace_pipeline(SDL_GPUDevice *device) {
  if (gpu_canvas_batch_replace_pipeline && gpu_canvas_sampler)
    return true;
  if (gpu_canvas_pipeline_failed)
    return false;
  if (!gpu_ensure_canvas_batch_pipeline(device))
    return false;

  gpu_canvas_batch_replace_pipeline = gpu_create_canvas_batch_graphics_pipeline(
    device,
    SDL_GetGPUTextureFormatFromPixelFormat(SDL_PIXELFORMAT_BGRA32),
    false
  );
  if (!gpu_canvas_batch_replace_pipeline) {
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
  if (gpu_canvas_batch_pipeline) {
    SDL_ReleaseGPUGraphicsPipeline(device, gpu_canvas_batch_pipeline);
    gpu_canvas_batch_pipeline = NULL;
  }
  if (gpu_canvas_batch_replace_pipeline) {
    SDL_ReleaseGPUGraphicsPipeline(device, gpu_canvas_batch_replace_pipeline);
    gpu_canvas_batch_replace_pipeline = NULL;
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
  if (format & SDL_GPU_SHADERFORMAT_DXIL) {
    createinfo.format = SDL_GPU_SHADERFORMAT_DXIL;
    createinfo.code = vertex ? gpu_text_vert_dxil : gpu_text_frag_dxil;
    createinfo.code_size = vertex ? gpu_text_vert_dxil_len : gpu_text_frag_dxil_len;
  } else if (format & SDL_GPU_SHADERFORMAT_DXBC) {
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

static SDL_GPUShader *gpu_create_text_batch_shader(SDL_GPUDevice *device, bool vertex) {
  SDL_GPUShaderCreateInfo createinfo;
  SDL_zero(createinfo);
  createinfo.stage = vertex ? SDL_GPU_SHADERSTAGE_VERTEX : SDL_GPU_SHADERSTAGE_FRAGMENT;
  createinfo.num_samplers = vertex ? 0 : 1;
  createinfo.num_uniform_buffers = 1;

  SDL_GPUShaderFormat format = SDL_GetGPUShaderFormats(device);
  if (format & SDL_GPU_SHADERFORMAT_DXIL) {
    createinfo.format = SDL_GPU_SHADERFORMAT_DXIL;
    createinfo.code = vertex ? gpu_text_batch_vert_dxil : gpu_text_batch_frag_dxil;
    createinfo.code_size = vertex ? gpu_text_batch_vert_dxil_len : gpu_text_batch_frag_dxil_len;
  } else if (format & SDL_GPU_SHADERFORMAT_DXBC) {
    createinfo.format = SDL_GPU_SHADERFORMAT_DXBC;
    createinfo.code = vertex ? gpu_text_batch_vert_dxbc : gpu_text_batch_frag_dxbc;
    createinfo.code_size = vertex ? gpu_text_batch_vert_dxbc_len : gpu_text_batch_frag_dxbc_len;
  } else if (format & SDL_GPU_SHADERFORMAT_MSL) {
    createinfo.format = SDL_GPU_SHADERFORMAT_MSL;
    createinfo.code = vertex ? gpu_text_batch_vert_msl : gpu_text_batch_frag_msl;
    createinfo.code_size = vertex ? gpu_text_batch_vert_msl_len : gpu_text_batch_frag_msl_len;
  } else if (format & SDL_GPU_SHADERFORMAT_SPIRV) {
    createinfo.format = SDL_GPU_SHADERFORMAT_SPIRV;
    createinfo.code = vertex ? gpu_text_batch_vert_spv : gpu_text_batch_frag_spv;
    createinfo.code_size = vertex ? gpu_text_batch_vert_spv_len : gpu_text_batch_frag_spv_len;
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

static SDL_GPUGraphicsPipeline *gpu_create_text_batch_graphics_pipeline(SDL_GPUDevice *device, bool blend) {
  SDL_GPUShader *vertex_shader = gpu_create_text_batch_shader(device, true);
  SDL_GPUShader *fragment_shader = gpu_create_text_batch_shader(device, false);
  if (!vertex_shader || !fragment_shader) {
    if (vertex_shader) SDL_ReleaseGPUShader(device, vertex_shader);
    if (fragment_shader) SDL_ReleaseGPUShader(device, fragment_shader);
    return NULL;
  }

  SDL_GPUVertexBufferDescription vertex_buffer;
  SDL_zero(vertex_buffer);
  vertex_buffer.slot = 0;
  vertex_buffer.pitch = sizeof(GpuTextBatchInstance);
  vertex_buffer.input_rate = SDL_GPU_VERTEXINPUTRATE_INSTANCE;

  SDL_GPUVertexAttribute vertex_attributes[3];
  SDL_zeroa(vertex_attributes);
  vertex_attributes[0].location = 0;
  vertex_attributes[0].buffer_slot = 0;
  vertex_attributes[0].format = SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4;
  vertex_attributes[0].offset = 0;
  vertex_attributes[1].location = 1;
  vertex_attributes[1].buffer_slot = 0;
  vertex_attributes[1].format = SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4;
  vertex_attributes[1].offset = offsetof(GpuTextBatchInstance, uv);
  vertex_attributes[2].location = 2;
  vertex_attributes[2].buffer_slot = 0;
  vertex_attributes[2].format = SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4;
  vertex_attributes[2].offset = offsetof(GpuTextBatchInstance, color);

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
  pipeline_info.vertex_input_state.vertex_buffer_descriptions = &vertex_buffer;
  pipeline_info.vertex_input_state.num_vertex_buffers = 1;
  pipeline_info.vertex_input_state.vertex_attributes = vertex_attributes;
  pipeline_info.vertex_input_state.num_vertex_attributes = SDL_arraysize(vertex_attributes);
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

static bool gpu_ensure_text_batch_pipeline(SDL_GPUDevice *device) {
  if (gpu_text_batch_pipeline && gpu_text_sampler)
    return true;
  if (gpu_text_pipeline_failed)
    return false;
  if (!gpu_ensure_text_pipeline(device))
    return false;

  gpu_text_batch_pipeline = gpu_create_text_batch_graphics_pipeline(device, true);
  if (!gpu_text_batch_pipeline) {
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
  if (gpu_text_batch_pipeline) {
    SDL_ReleaseGPUGraphicsPipeline(device, gpu_text_batch_pipeline);
    gpu_text_batch_pipeline = NULL;
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
  if (!gpu_ensure_rect_pipeline(data->device))
    return false;
  bool needs_replace_pipeline = false;
  for (int i = 0; i < data->pending_native_rect_count; i++) {
    if (data->pending_native_rects[i].replace) {
      needs_replace_pipeline = true;
      break;
    }
  }
  if (needs_replace_pipeline && !gpu_ensure_rect_replace_pipeline(data->device))
    return false;

  int rect_count = 0;
  for (int i = 0; i < data->pending_native_rect_count; i++) {
    GpuNativeRect *native = &data->pending_native_rects[i];
    if (native->rect.w > 0 && native->rect.h > 0)
      rect_count++;
  }
  if (rect_count == 0) {
    data->pending_native_rect_count = 0;
    return true;
  }

  GpuBatchRun *runs = gpu_ensure_batch_runs(&data->frame, rect_count);

  Uint32 instance_count = (Uint32) rect_count;
  Uint32 upload_size = instance_count * sizeof(GpuRectInstance);
  gpu_ensure_window_rect_buffers(data, upload_size);

  GpuRectInstance *instances = SDL_MapGPUTransferBuffer(data->device, data->rect_transfer, true);
  if (!instances)
    return false;

  GpuRectInstance *out = instances;
  int run_count = 0;
  Uint32 emitted_instances = 0;
  for (int i = 0; i < data->pending_native_rect_count; i++) {
    GpuNativeRect *native = &data->pending_native_rects[i];
    if (native->rect.w <= 0 || native->rect.h <= 0)
      continue;

    GpuBatchRun *run = gpu_batch_append_run(
      runs, &run_count, gpu_rect_batch_material(native->replace), emitted_instances
    );

    float color[4];
    gpu_color_to_float(native->color, color);
    Uint32 emitted = gpu_emit_rect_instance(out, native->rect, color);
    out += emitted;
    emitted_instances += emitted;
    run->vertex_count += emitted;
  }
  SDL_UnmapGPUTransferBuffer(data->device, data->rect_transfer);

  gpu_upload_batch_vertices(cmd, data->rect_transfer, data->rect_vertex_buffer, upload_size);

  SDL_GPURenderPass *pass = gpu_begin_batch_render_pass(
    cmd, data->frame.texture, data->frame.texture_w, data->frame.texture_h, NULL
  );

  gpu_bind_batch_vertex_buffer(pass, data->rect_vertex_buffer);

  SDL_GPUGraphicsPipeline *bound_pipeline = NULL;
  for (int i = 0; i < run_count; i++) {
    GpuBatchRun *run = &runs[i];
    if (run->vertex_count == 0)
      continue;

    gpu_bind_batch_pipeline(pass, run->material, &bound_pipeline);
    SDL_DrawGPUPrimitives(pass, 6, run->vertex_count, 0, run->first_vertex);
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

  SDL_GPURenderPass *pass = gpu_begin_target_render_pass(
    cmd, frame->texture, frame->texture_w, frame->texture_h, &dst
  );

  GpuTextVertexUniforms vertex_uniforms = {
    .dst = { dst.x, dst.y, dst.w, dst.h },
    .uv = { 0, 0, 1, 1 },
    .target = { frame->texture_w, frame->texture_h, 0, 0 },
  };
  GpuTextFragmentUniforms fragment_uniforms = {
    .format = EGlyphFormatGrayscale,
  };
  gpu_color_to_float(color, fragment_uniforms.color);

  SDL_BindGPUGraphicsPipeline(pass, replace ? gpu_text_replace_pipeline : gpu_text_pipeline);
  SDL_PushGPUVertexUniformData(cmd, 0, &vertex_uniforms, sizeof(vertex_uniforms));
  SDL_PushGPUFragmentUniformData(cmd, 0, &fragment_uniforms, sizeof(fragment_uniforms));
  gpu_bind_fragment_sampler(pass, gpu_solid_white_texture, gpu_text_sampler);
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

  SDL_GPURenderPass *pass = gpu_begin_target_render_pass(
    cmd, data->frame.texture, data->frame.texture_w, data->frame.texture_h, &rect
  );

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
  gpu_bind_fragment_sampler(pass, gpu_solid_white_texture, gpu_text_sampler);
  SDL_DrawGPUPrimitives(pass, 6, 1, 0, 0);
  SDL_EndGPURenderPass(pass);

  data->validation_probe_rect = rect;
  data->validation_probe_pending = true;
  return true;
}

static bool gpu_collect_text_glyph(void *userdata, const RenGlyphDraw *glyph) {
  GpuTextDrawContext *ctx = userdata;
  if (!ctx->collect_overlay) {
    gpu_abort("SDLGPU native text collection unavailable");
  }

  GpuWindowData *data = ctx->window_data;
  SDL_GPUDevice *device = ctx->device;
  SDL_GPUCommandBuffer *cmd = ctx->command_buffer;
  GpuFrameBridge *frame = ctx->target_frame;
  if (!device || !cmd || !frame || !frame->texture)
    gpu_abort("SDLGPU native text target unavailable");
  if (!ctx->batch_pipeline_ready && !gpu_ensure_text_batch_pipeline(device))
    gpu_abort("SDLGPU native text pipeline unavailable");
  ctx->batch_pipeline_ready = true;

  GpuAtlasTexture *texture = gpu_ensure_native_glyph_texture(data, glyph->atlas, glyph->metric);
  if (!texture) {
    GlyphMetric *m = glyph->metric;
    char detail[256];
    SDL_Surface *gsurface = glyph->atlas ? ren_atlas_get_glyph_surface(glyph->atlas, m) : NULL;
    SDL_snprintf(
      detail, sizeof(detail),
      "SDLGPU native glyph texture unavailable (format=%u atlas=%u surface=%u "
      "x1=%u y0=%u y1=%u surface=%dx%d)",
      m->format, m->atlas_idx, m->surface_idx, m->x1, m->y0, m->y1,
      gsurface ? gsurface->w : -1, gsurface ? gsurface->h : -1
    );
    gpu_abort(detail);
  }
  if (!ctx->have_clip) {
    if (!frame->surface || !SDL_GetSurfaceClipRect(frame->surface, &ctx->clip))
      gpu_abort("SDLGPU native text clip unavailable");
    ctx->have_clip = true;
  }

  GpuQueuedGlyph *queued = NULL;
  if (data) {
    queued = gpu_append_pending_text_glyph(data);
  } else if (!gpu_grow_buffer((void **) &ctx->glyphs, &ctx->glyph_capacity,
                              ctx->glyph_count + 1, sizeof(GpuQueuedGlyph), 128)) {
    fprintf(stderr, "Error allocating SDL GPU text glyph batch\n");
    exit(1);
  }
  if (!queued)
    queued = &ctx->glyphs[ctx->glyph_count];

  *queued = (GpuQueuedGlyph) {
    .atlas = glyph->atlas,
    .metric = *glyph->metric,
    .texture = texture->texture,
    .color = glyph->color,
    .dst_x = glyph->dst_x,
    .dst_y = glyph->dst_y,
    .src_x = glyph->src_x,
    .src_y = glyph->src_y,
    .width = glyph->width,
    .height = glyph->height,
    .texture_w = texture->texture_w,
    .texture_h = texture->texture_h,
    .texture_y0 = texture->y0,
    .clip = ctx->clip,
    .format = glyph->format,
  };
  ctx->glyph_count++;
  return true;
}

static GpuQueuedGlyph *gpu_append_pending_text_glyph(GpuWindowData *data) {
  if (!gpu_grow_buffer((void **) &data->pending_text_glyphs, &data->pending_text_glyph_capacity,
                       data->pending_text_glyph_count + 1, sizeof(GpuQueuedGlyph), 512)) {
    fprintf(stderr, "Error allocating SDL GPU pending text glyphs\n");
    exit(1);
  }
  return &data->pending_text_glyphs[data->pending_text_glyph_count++];
}

static bool gpu_queue_text_batch(GpuTextDrawContext *ctx) {
  GpuWindowData *data = ctx->window_data;
  if (!data || !data->command_buffer || !data->frame.texture || ctx->glyph_count == 0)
    return false;
  if (!gpu_ensure_text_batch_pipeline(data->device))
    return false;

  if (!ctx->glyphs) {
    data->native_text_used = true;
    return true;
  }

  if (!gpu_grow_buffer((void **) &data->pending_text_glyphs, &data->pending_text_glyph_capacity,
                       data->pending_text_glyph_count + ctx->glyph_count, sizeof(GpuQueuedGlyph), 512)) {
    fprintf(stderr, "Error allocating SDL GPU pending text glyphs\n");
    exit(1);
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

static bool gpu_draw_text_batches_to_bridge(
  SDL_GPUDevice *device, SDL_GPUCommandBuffer *cmd, GpuFrameBridge *frame,
  SDL_Surface *surface, GpuQueuedGlyph *glyphs, int glyph_count,
  SDL_Rect *validation_rect, bool *have_validation_rect
) {
  if (!device || !cmd || !frame || !surface || glyph_count == 0)
    return true;
  if (!frame->texture)
    return false;
  if (!gpu_ensure_text_batch_pipeline(device))
    return false;

  GpuBatchRun *runs = gpu_ensure_batch_runs(frame, glyph_count);

  Uint32 max_instances = (Uint32) glyph_count;
  Uint32 upload_size = max_instances * sizeof(GpuTextBatchInstance);
  gpu_ensure_bridge_text_buffers(device, frame, upload_size);

  GpuTextBatchInstance *instances = SDL_MapGPUTransferBuffer(device, frame->text_transfer, true);
  if (!instances)
    return false;

  Uint32 instance_count = 0;
  int run_count = 0;
  SDL_Rect last_glyph_rect = {0};
  GpuBatchMaterial last_material = {0};
  bool have_last_glyph = false;

  for (int i = 0; i < glyph_count; i++) {
    GpuQueuedGlyph *glyph = &glyphs[i];
    if (!glyph->texture || glyph->texture_w <= 0 || glyph->texture_h <= 0)
      continue;

    SDL_Rect dst = {
      .x = glyph->dst_x,
      .y = glyph->dst_y,
      .w = glyph->width,
      .h = glyph->height,
    };
    if (validation_rect && have_validation_rect) {
      if (*have_validation_rect)
        SDL_GetRectUnion(validation_rect, &dst, validation_rect);
      else {
        *validation_rect = dst;
        *have_validation_rect = true;
      }
    }

    SDL_Rect clipped = dst;
    if (!SDL_GetRectIntersection(&clipped, &glyph->clip, &clipped) || clipped.w <= 0 || clipped.h <= 0)
      continue;

    float u0 = (float) (glyph->src_x + clipped.x - dst.x) / (float) glyph->texture_w;
    float v0 = (float) (glyph->src_y - glyph->texture_y0 + clipped.y - dst.y) / (float) glyph->texture_h;
    float u1 = (float) (glyph->src_x + clipped.x - dst.x + clipped.w) / (float) glyph->texture_w;
    float v1 = (float) (glyph->src_y - glyph->texture_y0 + clipped.y - dst.y + clipped.h) / (float) glyph->texture_h;
    float color[4];
    gpu_color_to_float(glyph->color, color);

    GpuBatchMaterial material = gpu_text_batch_material(glyph->texture, glyph->format);
    bool overlaps_last = have_last_glyph
      && gpu_batch_material_equal(last_material, material)
      && SDL_HasRectIntersection(&last_glyph_rect, &clipped);
    GpuBatchRun *run = overlaps_last
      ? gpu_batch_append_new_run(runs, &run_count, material, instance_count)
      : gpu_batch_append_run(runs, &run_count, material, instance_count);

    Uint32 emitted_instances = gpu_emit_text_instance(
      instances + instance_count, clipped, u0, v0, u1, v1, color
    );
    instance_count += emitted_instances;
    run->vertex_count += emitted_instances;
    last_glyph_rect = clipped;
    last_material = material;
    have_last_glyph = true;
  }

  SDL_UnmapGPUTransferBuffer(device, frame->text_transfer);

  if (instance_count == 0) {
    return true;
  }

  gpu_upload_batch_vertices(
    cmd, frame->text_transfer, frame->text_vertex_buffer, instance_count * sizeof(GpuTextBatchInstance)
  );

  SDL_Rect target_clip = { .x = 0, .y = 0, .w = surface->w, .h = surface->h };
  SDL_GPURenderPass *pass = gpu_begin_batch_render_pass(
    cmd, frame->texture, frame->texture_w, frame->texture_h, &target_clip
  );

  gpu_bind_batch_vertex_buffer(pass, frame->text_vertex_buffer);

  SDL_GPUGraphicsPipeline *bound_pipeline = NULL;
  for (int i = 0; i < run_count; i++) {
    GpuBatchRun *run = &runs[i];
    if (run->vertex_count == 0)
      continue;

    gpu_bind_batch_pipeline(pass, run->material, &bound_pipeline);

    GpuTextBatchFragmentUniforms fragment_uniforms = {
      .format = run->material.glyph_format,
    };
    SDL_PushGPUFragmentUniformData(cmd, 0, &fragment_uniforms, sizeof(fragment_uniforms));
    gpu_bind_fragment_sampler(pass, run->material.texture, run->material.sampler);
    SDL_DrawGPUPrimitives(pass, 6, run->vertex_count, 0, run->first_vertex);
  }

  SDL_EndGPURenderPass(pass);
  return true;
}

static bool gpu_flush_queued_canvases(GpuWindowData *data, SDL_GPUCommandBuffer *cmd) {
  if (!data || !cmd || !data->frame.texture || data->pending_canvas_count == 0)
    return true;
  if (!gpu_ensure_canvas_batch_pipeline(data->device))
    return false;

  bool needs_replace_pipeline = false;
  for (int i = 0; i < data->pending_canvas_count; i++) {
    if (data->pending_canvases[i].mode == GPU_TEXTURE_BATCH_REPLACE) {
      needs_replace_pipeline = true;
      break;
    }
  }
  if (needs_replace_pipeline && !gpu_ensure_canvas_batch_replace_pipeline(data->device))
    return false;

  GpuBatchRun *runs = gpu_ensure_batch_runs(&data->frame, data->pending_canvas_count);

  Uint32 max_vertices = (Uint32) data->pending_canvas_count * 6;
  Uint32 upload_size = max_vertices * sizeof(GpuTextureQuadVertex);
  gpu_ensure_bridge_quad_buffers(data->device, &data->frame, upload_size);

  GpuTextureQuadVertex *vertices = SDL_MapGPUTransferBuffer(data->device, data->frame.quad_transfer, true);
  if (!vertices)
    return false;

  Uint32 vertex_count = 0;
  int run_count = 0;
  for (int i = 0; i < data->pending_canvas_count; i++) {
    GpuQueuedCanvas *canvas = &data->pending_canvases[i];
    if (!canvas->texture || canvas->dst.w <= 0 || canvas->dst.h <= 0)
      continue;

    GpuBatchRun *run = gpu_batch_append_run(
      runs, &run_count, gpu_canvas_batch_material(canvas->texture, canvas->mode), vertex_count
    );

    Uint32 quad_vertices = gpu_emit_texture_quad(
      vertices + vertex_count, canvas->dst, canvas->u0, canvas->v0, canvas->u1, canvas->v1
    );
    vertex_count += quad_vertices;
    run->vertex_count += quad_vertices;
  }

  SDL_UnmapGPUTransferBuffer(data->device, data->frame.quad_transfer);

  if (vertex_count == 0) {
    data->pending_canvas_count = 0;
    return true;
  }

  gpu_upload_batch_vertices(
    cmd, data->frame.quad_transfer, data->frame.quad_vertex_buffer, vertex_count * sizeof(GpuTextureQuadVertex)
  );

  SDL_Rect target_clip = { .x = 0, .y = 0, .w = data->frame.texture_w, .h = data->frame.texture_h };
  SDL_GPURenderPass *pass = gpu_begin_batch_render_pass(
    cmd, data->frame.texture, data->frame.texture_w, data->frame.texture_h, &target_clip
  );

  gpu_bind_batch_vertex_buffer(pass, data->frame.quad_vertex_buffer);

  SDL_GPUGraphicsPipeline *bound_pipeline = NULL;
  for (int i = 0; i < run_count; i++) {
    GpuBatchRun *run = &runs[i];
    if (run->vertex_count == 0)
      continue;

    gpu_bind_batch_pipeline(pass, run->material, &bound_pipeline);

    gpu_bind_fragment_sampler(pass, run->material.texture, run->material.sampler);
    SDL_DrawGPUPrimitives(pass, run->vertex_count, 1, run->first_vertex, 0);
  }

  SDL_EndGPURenderPass(pass);
  int submitted_runs = run_count;
  data->pending_canvas_count = 0;
  data->frame_synced_during_replay = true;
  data->sampled_canvas_this_frame = true;
  data->stats_native_canvas_texture_draws += submitted_runs;
  return true;
}

static bool gpu_draw_text_glyphs_to_bridge(
  SDL_GPUDevice *device, SDL_GPUCommandBuffer *cmd, GpuFrameBridge *frame,
  SDL_Surface *surface, GpuQueuedGlyph *glyphs, int glyph_count
) {
  return gpu_draw_text_batches_to_bridge(device, cmd, frame, surface, glyphs, glyph_count, NULL, NULL);
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
  if (!gpu_ensure_text_batch_pipeline(data->device))
    return false;

  SDL_Rect validation_rect = {0};
  bool have_validation_rect = false;
  SDL_Rect *validation_rect_ptr = gpu_validate_text_enabled() ? &validation_rect : NULL;
  bool *have_validation_rect_ptr = gpu_validate_text_enabled() ? &have_validation_rect : NULL;
  if (!gpu_draw_text_batches_to_bridge(
        data->device,
        cmd,
        &data->frame,
        data->frame.surface,
        data->pending_text_glyphs,
        data->pending_text_glyph_count,
        validation_rect_ptr,
        have_validation_rect_ptr
      ))
    return false;

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

  SDL_Rect scissor = { .x = x1, .y = y1, .w = x2 - x1, .h = y2 - y1 };
  SDL_GPURenderPass *pass = gpu_begin_configured_render_pass(
    cmd, dst->texture, dst->texture_w, dst->texture_h, &scissor,
    SDL_GPU_LOADOP_LOAD, (SDL_FColor) { 0 }, cycle_destination
  );

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
  gpu_bind_fragment_sampler(pass, src->texture, gpu_canvas_sampler);
  SDL_DrawGPUPrimitives(pass, 6, 1, 0, 0);
  SDL_EndGPURenderPass(pass);
  if (replace_pipeline)
    SDL_ReleaseGPUGraphicsPipeline(device, replace_pipeline);
  return true;
}

static bool gpu_queue_canvas_texture_to_frame(
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

  if (!gpu_grow_buffer((void **) &window_data->pending_canvases, &window_data->pending_canvas_capacity,
                       window_data->pending_canvas_count + 1, sizeof(GpuQueuedCanvas), 64)) {
    fprintf(stderr, "Error allocating SDL GPU pending canvases\n");
    exit(1);
  }

  window_data->pending_canvases[window_data->pending_canvas_count++] = (GpuQueuedCanvas) {
    .texture = src->texture,
    .dst = { .x = x1, .y = y1, .w = x2 - x1, .h = y2 - y1 },
    .u0 = (float) (x1 - x) / (float) src->texture_w,
    .v0 = (float) (y1 - y) / (float) src->texture_h,
    .u1 = (float) (x2 - x) / (float) src->texture_w,
    .v1 = (float) (y2 - y) / (float) src->texture_h,
    .mode = blend_mode == SDL_BLENDMODE_NONE ? GPU_TEXTURE_BATCH_REPLACE : GPU_TEXTURE_BATCH_BLEND,
  };
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

/* Create (or return the cached) GPU device. Returns NULL on failure without
** aborting, so callers can fall back to another backend. */
static SDL_GPUDevice *gpu_try_get_device(void) {
  if (!gpu_device)
    gpu_device = SDL_CreateGPUDevice(GPU_SUPPORTED_SHADER_FORMATS, false, NULL);
  return gpu_device;
}

static SDL_GPUDevice *gpu_get_device(void) {
  if (!gpu_try_get_device())
    gpu_abort("SDL_CreateGPUDevice failed");
  return gpu_device;
}

/* Backend availability probe: succeeds only if a GPU device can be created.
** The device is cached and reused by gpu_retain_device(), so no work is wasted. */
static bool gpu_backend_available(void) {
  /* GPU support can only be queried once the video subsystem is up. The backend
  ** may be resolved before the first window is created (e.g. during font atlas
  ** setup at startup), so ensure the video subsystem here. The video driver hint
  ** is already set by main() before any backend resolution, so this picks the
  ** same driver video_init() would. SDL_InitSubSystem is idempotent/ref-counted.
  ** The created device is cached and reused by gpu_retain_device(). */
  if (!SDL_WasInit(SDL_INIT_VIDEO) && !SDL_InitSubSystem(SDL_INIT_VIDEO))
    return false;
  return gpu_try_get_device() != NULL;
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
    gpu_destroy_rect_pipeline(gpu_device);
    gpu_destroy_poly_pipeline(gpu_device);
    gpu_destroy_text_pipeline(gpu_device);
    SDL_DestroyGPUDevice(gpu_device);
    gpu_device = NULL;
  }
}

/* Pick the swapchain present mode. With vsync on, prefer MAILBOX (tear-free and
   low-latency/non-blocking) then fall back to VSYNC (always supported, tear-free).
   With vsync off, prefer IMMEDIATE (no vsync, "draw as much as possible to
   screen"; tears) and fall back to MAILBOX then VSYNC if a driver lacks it.
   IMMEDIATE forced unconditionally is what tore on D3D12/Windows. */
static void gpu_apply_present_mode(GpuWindowData *data, RenWindow *ren, bool vsync) {
  SDL_GPUPresentMode present_mode = SDL_GPU_PRESENTMODE_VSYNC;
  if (!vsync &&
      SDL_WindowSupportsGPUPresentMode(data->device, ren->window, SDL_GPU_PRESENTMODE_IMMEDIATE)) {
    present_mode = SDL_GPU_PRESENTMODE_IMMEDIATE;
  } else if (SDL_WindowSupportsGPUPresentMode(data->device, ren->window, SDL_GPU_PRESENTMODE_MAILBOX)) {
    present_mode = SDL_GPU_PRESENTMODE_MAILBOX;
  }
  SDL_SetGPUSwapchainParameters(
    data->device, ren->window, SDL_GPU_SWAPCHAINCOMPOSITION_SDR, present_mode
  );
}

static bool gpu_init_window(RenWindow *ren) {
  GpuWindowData *data = gpu_window_data(ren);
  data->device = gpu_retain_device();
  if (!SDL_ClaimWindowForGPUDevice(data->device, ren->window)) {
    fprintf(stderr, "SDL_ClaimWindowForGPUDevice failed: %s\n", SDL_GetError());
    gpu_release_device();
    data->device = NULL;
    SDL_free(ren->backend_data);
    ren->backend_data = NULL;
    return false;
  }
  /* Default to vsync (tear-free); the Lua side calls set_vsync() to match
     config.auto_fps (off => IMMEDIATE for max frames to screen). */
  gpu_apply_present_mode(data, ren, true);
  gpu_create_surface(ren);
  return true;
}

static void gpu_set_vsync(RenWindow *ren, bool enabled) {
  GpuWindowData *data = ren ? ren->backend_data : NULL;
  if (data && data->device)
    gpu_apply_present_mode(data, ren, enabled);
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
    if (data->rect_vertex_buffer) {
      SDL_ReleaseGPUBuffer(data->device, data->rect_vertex_buffer);
      data->rect_vertex_buffer = NULL;
      data->rect_vertex_buffer_size = 0;
    }
    if (data->rect_transfer) {
      SDL_ReleaseGPUTransferBuffer(data->device, data->rect_transfer);
      data->rect_transfer = NULL;
      data->rect_transfer_size = 0;
    }
    SDL_free(data->pending_text_glyphs);
    data->pending_text_glyphs = NULL;
    data->pending_text_glyph_count = 0;
    data->pending_text_glyph_capacity = 0;
    SDL_free(data->pending_canvases);
    data->pending_canvases = NULL;
    data->pending_canvas_count = 0;
    data->pending_canvas_capacity = 0;
    SDL_free(data->pending_polys);
    data->pending_polys = NULL;
    data->pending_poly_count = 0;
    data->pending_poly_capacity = 0;
    SDL_free(data->pending_poly_vertices);
    data->pending_poly_vertices = NULL;
    data->pending_poly_vertex_count = 0;
    data->pending_poly_vertex_capacity = 0;
    SDL_free(data->pending_pixels);
    data->pending_pixels = NULL;
    data->pending_pixel_count = 0;
    data->pending_pixel_capacity = 0;
    SDL_free(data->pending_pixel_bytes);
    data->pending_pixel_bytes = NULL;
    data->pending_pixel_bytes_size = 0;
    data->pending_pixel_bytes_capacity = 0;
    data->pending_pixels_texture_w = 0;
    data->pending_pixels_texture_h = 0;
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

  SDL_GPURenderPass *pass = gpu_begin_configured_render_pass(
    data->command_buffer, data->frame.texture, data->frame.texture_w, data->frame.texture_h, NULL,
    SDL_GPU_LOADOP_CLEAR, (SDL_FColor) { 0, 0, 0, 1 }, false
  );
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
  data->pending_canvas_count = 0;
  data->pending_poly_count = 0;
  data->pending_poly_vertex_count = 0;
  data->pending_pixel_count = 0;
  data->pending_pixel_bytes_size = 0;
  data->pending_pixels_texture_w = 0;
  data->pending_pixels_texture_h = 0;
  data->native_region = false;
  data->frame_synced_during_replay = false;
  data->native_text_used = false;
  data->have_native_clip_rect = false;
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

// Accumulate a command's collected glyphs into the canvas-wide pending queue so
// consecutive offscreen text commands render in one batch instead of one render
// pass per command.
static bool gpu_append_canvas_text_glyphs(GpuCanvasData *data, GpuQueuedGlyph *glyphs, int count) {
  if (count <= 0)
    return true;
  if (!gpu_grow_buffer((void **) &data->pending_text_glyphs, &data->pending_text_glyph_capacity,
                       data->pending_text_glyph_count + count, sizeof(GpuQueuedGlyph), 512))
    return false;
  SDL_memcpy(
    data->pending_text_glyphs + data->pending_text_glyph_count,
    glyphs, count * sizeof(GpuQueuedGlyph)
  );
  data->pending_text_glyph_count += count;
  return true;
}

// Render and clear the canvas pending text batch into the canvas frame texture.
// Used as an ordering barrier before non-text canvas draws and at region submit.
static bool gpu_flush_canvas_pending_text(GpuCanvasData *data) {
  if (!data || data->pending_text_glyph_count == 0)
    return true;
  if (!data->command_buffer || !data->frame.surface || !data->frame.texture)
    return false;
  bool drawn = gpu_draw_text_batches_to_bridge(
    data->device, data->command_buffer, &data->frame, data->frame.surface,
    data->pending_text_glyphs, data->pending_text_glyph_count, NULL, NULL
  );
  data->pending_text_glyph_count = 0;
  if (drawn)
    data->region_modified = true;
  return drawn;
}

static void gpu_submit_canvas_region_command(GpuCanvasData *data) {
  if (!data || !data->command_buffer) {
    if (data)
      data->region_modified = false;
    return;
  }

  if (!gpu_flush_canvas_pending_text(data))
    gpu_abort("SDLGPU canvas pending text flush failed");

  SDL_GPUCommandBuffer *cmd = data->command_buffer;
  data->command_buffer = NULL;
  if (gpu_active_frame_command_buffer == cmd) {
    gpu_active_frame_device = data->prev_active_frame_device;
    gpu_active_frame_command_buffer = data->prev_active_frame_command_buffer;
    gpu_active_frame_window_data = data->prev_active_frame_window_data;
  }
  data->prev_active_frame_device = NULL;
  data->prev_active_frame_command_buffer = NULL;
  data->prev_active_frame_window_data = NULL;

  if (!gpu_submit_and_wait(data->device, cmd))
    gpu_abort("SDL_SubmitGPUCommandBufferAndAcquireFence failed");

  if (data->region_modified) {
    data->texture_valid = true;
    data->surface_valid = false;
    data->frame.needs_full_upload = false;
    data->frame.dirty_count = 0;
    data->region_modified = false;
  }
}

static SDL_GPUCommandBuffer *gpu_begin_canvas_region_command(GpuCanvasData *data) {
  if (!data)
    return NULL;
  if (data->command_buffer)
    return data->command_buffer;
  if (!data->device)
    data->device = gpu_retain_device();

  data->command_buffer = SDL_AcquireGPUCommandBuffer(data->device);
  if (!data->command_buffer)
    gpu_abort("SDL_AcquireGPUCommandBuffer failed");
  data->prev_active_frame_device = gpu_active_frame_device;
  data->prev_active_frame_command_buffer = gpu_active_frame_command_buffer;
  data->prev_active_frame_window_data = gpu_active_frame_window_data;
  gpu_active_frame_device = data->device;
  gpu_active_frame_command_buffer = data->command_buffer;
  gpu_active_frame_window_data = NULL;
  gpu_sync_canvas_texture(data, data->command_buffer);
  return data->command_buffer;
}

static void gpu_begin_region(RenCache *cache, UNUSED RenRect rect, UNUSED bool native_only) {
  if (!cache->window_target) {
    GpuCanvasData *data = cache->backend_data;
    if (data) {
      data->region_active = true;
      data->region_modified = false;
      data->pending_text_glyph_count = 0;
    }
    return;
  }

  RenWindow *ren = cache->target;
  GpuWindowData *data = ren->backend_data;
  if (data)
    data->native_region = gpu_direct_replay_enabled();
}

static void gpu_end_region(RenCache *cache, UNUSED RenRect rect, UNUSED bool native_only) {
  if (!cache->window_target) {
    GpuCanvasData *data = cache->backend_data;
    gpu_submit_canvas_region_command(data);
    if (data)
      data->region_active = false;
    return;
  }

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
  if (!gpu_flush_queued_canvases(data, cmd))
    gpu_abort("SDLGPU native canvas flush failed");
  if (!gpu_flush_queued_polys(data, cmd))
    gpu_abort("SDLGPU native polygon flush failed");
  if (!gpu_flush_queued_pixels(data, cmd))
    gpu_abort("SDLGPU native pixel flush failed");

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
  /* Only block on the GPU when the completed frame is actually needed on the
     CPU this frame: native-text validation readback, or a missing swapchain
     texture (hidden/temporary window that renderer.to_canvas may capture).
     A debug override can also force it. Steady-state frames submit without
     waiting so the CPU can build the next frame while the GPU renders this one.
     This is safe because per-frame vertex/transfer buffers are mapped and
     uploaded with cycle=true (SDL recycles them across in-flight frames) and
     command buffers execute in submission order, so the persistent frame
     texture and any sampled canvas textures stay correct without a fence.
     gpu_capture_window() submits and waits on its own command buffer. */
  bool wait_for_gpu = validate_text || !swapchain_texture || gpu_present_sync_forced();
  if (wait_for_gpu) {
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
    if (data->command_buffer) {
      if (gpu_active_frame_command_buffer == data->command_buffer) {
        gpu_active_frame_device = data->prev_active_frame_device;
        gpu_active_frame_command_buffer = data->prev_active_frame_command_buffer;
        gpu_active_frame_window_data = data->prev_active_frame_window_data;
      }
      SDL_CancelGPUCommandBuffer(data->command_buffer);
      data->command_buffer = NULL;
    }
    gpu_destroy_bridge_resources(data->device, &data->frame);
    if (data->device) {
      gpu_release_device();
      data->device = NULL;
    }
    gpu_destroy_bridge_surface(&data->frame);
    SDL_free(data->pending_text_glyphs);
    data->pending_text_glyphs = NULL;
  }
  SDL_free(data);
  canvas->backend_data = NULL;
  canvas->rensurface.surface = NULL;
}

static SDL_Surface *gpu_get_canvas_surface(RenCache *canvas) {
  GpuCanvasData *data = canvas->backend_data;
  if (!data)
    return canvas->rensurface.surface;

  if (data->command_buffer && data->region_modified)
    gpu_submit_canvas_region_command(data);

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

  SDL_GPURenderPass *pass = gpu_begin_configured_render_pass(
    cmd, data->frame.texture, data->frame.texture_w, data->frame.texture_h, NULL,
    SDL_GPU_LOADOP_CLEAR, color, true
  );
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

static SDL_GPUCommandBuffer *gpu_canvas_command_buffer(GpuCanvasData *data, bool *owned) {
  if (data->command_buffer) {
    *owned = false;
    return data->command_buffer;
  }
  if (data->region_active) {
    *owned = false;
    return gpu_begin_canvas_region_command(data);
  }

  SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(data->device);
  if (!cmd)
    gpu_abort("SDL_AcquireGPUCommandBuffer failed");
  *owned = true;
  return cmd;
}

static void gpu_finish_canvas_draw(
  RenCache *rc, GpuCanvasData *data, SDL_GPUCommandBuffer *cmd, bool owned, bool modified
) {
  if (owned) {
    if (!gpu_submit_and_wait(data->device, cmd))
      gpu_abort("SDL_SubmitGPUCommandBufferAndAcquireFence failed");
  }

  if (modified) {
    data->texture_valid = true;
    data->surface_valid = false;
    data->frame.needs_full_upload = false;
    data->frame.dirty_count = 0;
    if (owned)
      rc->revision++;
    else
      data->region_modified = true;
  }
}

static void gpu_cancel_canvas_draw(SDL_GPUCommandBuffer *cmd, bool owned) {
  if (owned)
    SDL_CancelGPUCommandBuffer(cmd);
}

static bool gpu_draw_canvas_to_canvas_native(
  RenCache *dst, RenSurface *surface, RenCache *src, int x, int y
) {
  if (dst->window_target || !surface || !surface->surface || dst == src)
    return false;

  GpuCanvasData *dst_data = dst->backend_data;
  GpuCanvasData *src_data = src->backend_data;
  if (!dst_data || !src_data || src_data->command_buffer)
    return false;
  if (!dst_data->device)
    dst_data->device = gpu_retain_device();
  if (!src_data->device)
    src_data->device = gpu_retain_device();
  if (dst_data->device != src_data->device)
    return false;

  SDL_BlendMode blend_mode = SDL_BLENDMODE_INVALID;
  if (!src_data->frame.surface ||
      !SDL_GetSurfaceBlendMode(src_data->frame.surface, &blend_mode) ||
      (blend_mode != SDL_BLENDMODE_NONE && blend_mode != SDL_BLENDMODE_BLEND))
    return false;

  bool owned = false;
  SDL_GPUCommandBuffer *cmd = gpu_canvas_command_buffer(dst_data, &owned);
  gpu_sync_canvas_texture(src_data, cmd);
  gpu_sync_canvas_texture(dst_data, cmd);
  bool drawn = gpu_blit_texture_to_bridge(
    dst_data->device,
    cmd,
    &dst_data->frame,
    &src_data->frame,
    x,
    y,
    blend_mode,
    false
  );
  if (!drawn) {
    gpu_cancel_canvas_draw(cmd, owned);
    return false;
  }

  gpu_finish_canvas_draw(dst, dst_data, cmd, owned, true);
  return true;
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

  bool owned = false;
  SDL_GPUCommandBuffer *cmd = gpu_canvas_command_buffer(data, &owned);

  gpu_sync_canvas_texture(data, cmd);
  if (!gpu_flush_canvas_pending_text(data))
    gpu_abort("SDLGPU canvas pending text flush failed");
  bool drawn = gpu_draw_solid_rect_to_bridge(
    data->device, cmd, &data->frame, surface->surface, rect, color, replace
  );
  if (!drawn) {
    gpu_cancel_canvas_draw(cmd, owned);
    return false;
  }

  gpu_finish_canvas_draw(rc, data, cmd, owned, true);
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

  bool owned = false;
  SDL_GPUCommandBuffer *cmd = gpu_canvas_command_buffer(data, &owned);

  gpu_sync_canvas_texture(data, cmd);
  if (!gpu_flush_canvas_pending_text(data))
    gpu_abort("SDLGPU canvas pending text flush failed");
  bool uploaded = gpu_upload_pixels_to_bridge(
    data->device, cmd, &data->frame, surface->surface, rect, bytes, len
  );
  if (!uploaded) {
    gpu_cancel_canvas_draw(cmd, owned);
    return false;
  }

  gpu_finish_canvas_draw(rc, data, cmd, owned, true);
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

  bool owned = false;
  SDL_GPUCommandBuffer *cmd = gpu_canvas_command_buffer(data, &owned);

  gpu_sync_canvas_texture(data, cmd);
  gpu_ensure_bridge_texture(data->device, &data->frame, surface->surface->w, surface->surface->h);
  if (!data->frame.texture || !gpu_ensure_text_pipeline(data->device)) {
    gpu_cancel_canvas_draw(cmd, owned);
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

  int style = ren_font_group_get_style(fonts);
  int glyph_count = text_context.glyph_count;
  bool decorated = (style & (FONT_STYLE_UNDERLINE | FONT_STYLE_STRIKETHROUGH)) != 0;

  // Region path without decorations: defer the draw and accumulate glyphs so the
  // whole region's text renders in one batch instead of a render pass per
  // command. The texture becomes authoritative immediately; the batch is flushed
  // at the next non-text barrier or at region submit.
  if (!owned && !decorated) {
    bool appended = gpu_append_canvas_text_glyphs(data, text_context.glyphs, glyph_count);
    SDL_free(text_context.glyphs);
    if (!appended)
      gpu_abort("SDLGPU canvas text glyph append failed");
    if (glyph_count > 0) {
      data->texture_valid = true;
      data->surface_valid = false;
      data->frame.needs_full_upload = false;
      data->frame.dirty_count = 0;
      data->region_modified = true;
    }
    return true;
  }

  // Immediate path (no region, or a decorated run that must keep text and
  // decoration ordered on this command buffer). Flush any deferred batch first
  // so it stays beneath this run.
  if (!owned && !gpu_flush_canvas_pending_text(data))
    gpu_abort("SDLGPU canvas pending text flush failed");

  bool drawn = gpu_draw_text_glyphs_to_bridge(
    data->device, cmd, &data->frame, surface->surface, text_context.glyphs, text_context.glyph_count
  );

  if (drawn && decorated) {
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

  SDL_free(text_context.glyphs);
  if (!drawn) {
    gpu_cancel_canvas_draw(cmd, owned);
    return false;
  }

  gpu_finish_canvas_draw(rc, data, cmd, owned, glyph_count > 0);
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

  unsigned short flat_count = 0;
  if (!gpu_flatten_poly(&data->frame, points, npoints, &flat_count))
    return false;

  int max_vertices = (flat_count - 2) * 3;
  if (!gpu_ensure_poly_vertex_scratch(&data->frame, max_vertices))
    gpu_abort("Error allocating polygon vertices");
  int vertex_count = gpu_triangulate_line_poly(
    &data->frame, data->frame.poly_points, flat_count, data->frame.poly_vertices,
    surface->scale_x > 0 ? surface->scale_x : 1.0f,
    surface->scale_y > 0 ? surface->scale_y : 1.0f
  );
  if (vertex_count == 0)
    return false;

  bool owned = false;
  SDL_GPUCommandBuffer *cmd = gpu_canvas_command_buffer(data, &owned);

  gpu_sync_canvas_texture(data, cmd);
  if (!gpu_flush_canvas_pending_text(data))
    gpu_abort("SDLGPU canvas pending text flush failed");
  bool drawn = gpu_draw_poly_vertices_to_bridge(
    data->device, cmd, &data->frame, surface->surface, data->frame.poly_vertices, vertex_count, bounds, color
  );
  if (!drawn) {
    gpu_cancel_canvas_draw(cmd, owned);
    return false;
  }

  gpu_finish_canvas_draw(rc, data, cmd, owned, true);
  return true;
}

static void gpu_set_clip_rect(RenCache *rc, RenSurface *surface, RenRect rect) {
  ren_set_clip_rect(surface, rect);
  if (rc && rc->window_target && surface && surface->surface) {
    RenWindow *ren = rc->target;
    GpuWindowData *data = ren ? ren->backend_data : NULL;
    if (data) {
      data->native_clip_rect = gpu_pixel_rect_from_ren_rect(surface->surface, rect);
      data->have_native_clip_rect = true;
    }
  }
}

static bool gpu_can_native_rect(
  RenCache *rc, RenSurface *surface, RenRect rect, RenColor color, bool replace
) {
  if (!rc->window_target || !surface->surface || !gpu_direct_replay_enabled() ||
      !gpu_native_rect_enabled() || (replace && color.a != 255))
    return false;

  RenWindow *ren = rc->target;
  GpuWindowData *data = ren->backend_data;
  if (!data || !data->command_buffer || !data->frame.texture)
    return false;
  return rect.width > 0 && rect.height > 0;
}

static bool gpu_can_native_region(RenCache *rc, UNUSED RenSurface *surface, UNUSED RenRect region) {
  if (!rc->window_target || !gpu_direct_replay_enabled())
    return false;

  RenWindow *ren = rc->target;
  GpuWindowData *data = ren ? ren->backend_data : NULL;
  return data && data->command_buffer && data->frame.texture;
}

static bool gpu_full_frame_regions_enabled(void) {
  return gpu_env_flag("PRAGTICAL_SDLGPU_FULL_FRAME", false);
}

static bool gpu_use_full_frame_regions(RenCache *rc) {
  /* Default to dirty-region native replay so static frames only redraw changed
     cells into the retained frame texture, matching the surface backend's
     frame-to-frame coherence. PRAGTICAL_SDLGPU_FULL_FRAME=1 restores the old
     whole-frame re-emit path for A/B comparison. */
  return rc && rc->window_target && gpu_direct_replay_enabled()
      && gpu_full_frame_regions_enabled();
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

  return true;
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
  unsigned short flat_count = 0;
  bool can_flatten = gpu_flatten_poly(&data->frame, points, npoints, &flat_count);
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
  GpuWindowData *data = ren->backend_data;
  if (!gpu_flush_window_batches(data, GPU_BATCH_QUEUE_ALL & ~GPU_BATCH_QUEUE_RECTS))
    gpu_abort("SDLGPU native batch flush before rect failed");
  bool native_queued = native_region && gpu_native_rect_enabled() &&
    gpu_queue_window_native_rect(rc, surface, rect, color, replace);
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
  if (!gpu_flush_window_batches(text_context.window_data, GPU_BATCH_QUEUE_ALL & ~GPU_BATCH_QUEUE_TEXT))
    gpu_abort("SDLGPU native batch flush before text failed");
  GpuWindowData *data = text_context.window_data;
  text_context.device = data->device;
  text_context.command_buffer = data->command_buffer;
  text_context.target_frame = &data->frame;
  text_context.collect_overlay = gpu_native_text_supported(data->device) && data->frame.texture;
  if (!text_context.collect_overlay)
    gpu_abort("SDLGPU native text pipeline unavailable");
  double end_x = ren_draw_text_cb_ex(
    surface, fonts, text, len, x, y, color, tab, gpu_collect_text_glyph, &text_context, false
  );
  bool used_native = gpu_queue_text_batch(&text_context);
  SDL_free(text_context.glyphs);
  if (!used_native && text_context.glyph_count > 0)
    gpu_abort("SDLGPU native text queue failed");
  if (style & (FONT_STYLE_UNDERLINE | FONT_STYLE_STRIKETHROUGH)) {
    if (!gpu_flush_pending_text_barrier(data))
      gpu_abort("SDLGPU native text flush before decorations failed");
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
      gpu_queue_window_native_rect(rc, surface, decoration, color, false);
    }
    if (style & FONT_STYLE_STRIKETHROUGH) {
      decoration.y = y + (float) height / 2;
      gpu_queue_window_native_rect(rc, surface, decoration, color, false);
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
    if (gpu_draw_canvas_to_canvas_native(rc, surface, canvas, x, y))
      return;
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
        if (!gpu_flush_window_batches(window_data, GPU_BATCH_QUEUE_ALL & ~GPU_BATCH_QUEUE_CANVASES))
          gpu_abort("SDLGPU native batch flush before canvas failed");
      }
    }
  }

  if (!native_candidate)
    gpu_abort("SDLGPU native canvas draw unsupported");

  bool synced = false;
  if (window_data && canvas_data && native_candidate)
    synced = gpu_queue_canvas_texture_to_frame(window_data, canvas_data, x, y, blend_mode);
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
  .available = gpu_backend_available,
  .draw_ops = &gpu_draw_ops,
  .use_full_frame_regions = gpu_use_full_frame_regions,
  .begin_frame = gpu_begin_frame,
  .end_frame = gpu_end_frame,
  .begin_region = gpu_begin_region,
  .end_region = gpu_end_region,
  .can_native_region = gpu_can_native_region,
  .can_native_rect = gpu_can_native_rect,
  .can_native_text = gpu_can_native_text,
  .can_native_canvas = gpu_can_native_canvas,
  .can_native_pixels = gpu_can_native_pixels,
  .can_native_poly = gpu_can_native_poly,
  .get_window_surface = gpu_get_window_surface,
  .present_window_rects = gpu_present_window_rects,
  .capture_window = gpu_capture_window,
  .init_window = gpu_init_window,
  .set_vsync = gpu_set_vsync,
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

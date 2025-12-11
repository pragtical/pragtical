local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local keymap = require "core.keymap"
local View = require "core.view"

---List of supported image types by extension.
---@type table<string,boolean>
local SUPPORTED_EXTENSIONS = {
  -- AVIF (External library needed)
  avif = true,
  -- BMP (Built-in support)
  bmp = true,
  -- CUR (Cursor) (Built-in support)
  cur = true,
  -- GIF (Built-in support)
  gif = true,
  -- ICO (Icon) (Built-in support)
  ico = true,
  -- JPEG/JPG (Built-in via STB or External library needed)
  jpg = true, jpeg = true, jfif = true, pjpeg = true, pjp = true,
  -- JPEG-XL (External library needed)
  jxl = true,
  -- LBM (Interleaved Bitmap) (Built-in support)
  lbm = true, iff = true,
  -- PCX (Built-in support)
  pcx = true,
  -- PNG: (Built-in via STB or External library needed)
  png = true,
  -- PNM (Portable Anymap) (Built-in support)
  pnm = true, pbm = true, pgm = true, ppm = true,
  -- QOI (Quite OK Image) (Built-in support)
  qoi = true,
  -- SVG (Built-in support for simple files)
  svg = true,
  -- TGA (Targa) (Built-in support)
  tga = true,
  -- TIFF/TIF (Built-in support)
  tif = true, tiff = true,
  -- WebP (External library needed)
  webp = true,
  -- XCF (GIMP format) (Built-in support)
  xcf = true,
  -- XPM (X11 Pixmap) (Built-in support)
  xpm = true,
  -- XV (Thumbnail format) (Built-in support)
  xv = true
}

---An image view that allows zooming in and out an image.
---@class core.imageview : core.view
---@field super core.view
---@field path string?
---@field background canvas?
---@field image canvas?
---@field image_scaled canvas?
---@field zoom_mode "fit" | "fixed"
---@field zoom_scale number
---@field width number
---@field height number
---@field errmsg string?
---@overload fun(path:string):core.imageview
---@diagnostic disable-next-line
local ImageView = View:extend()

ImageView.context = "application"

function ImageView:__tostring() return "ImageView" end

---Constructor
---@param path? string
function ImageView:new(path)
  ImageView.super.new(self)

  self.scrollable = true
  self.prev_size = {x = self.size.x, y = self.size.y}
  self.zoom_mode = "fit"
  self.zoom_scale = 1
  self.width = 0
  self.height = 0
  self.errmsg = nil
  self.bg_mode = config.images_background_mode or "grid"
  self.bg_color = config.images_background_color or { common.color "#ffffff" }

  self:load(path)
end

---Loads the given image into the view.
---@param path? string
---@return boolean loaded
---@return string? errmsg
function ImageView:load(path)
  if not path or not io.open(path, "r") then return false, "invalid path" end
  self.path = path
  self.image, self.errmsg = canvas.load_image(path)
  if self.image then
    self:scale_image()
  else
    return false, self.errmsg
  end
  return true
end

function ImageView:get_name()
  if self.path and self.image then
    return common.basename(self.path)
  end
  return "Image Viewer"
end

---Scale the currently loaded image depending on the current
---zoom mode and scale factor.
function ImageView:scale_image()
  if not self.image or self.size.x == 0 or self.size.y == 0 then return end

  local img_w, img_h = self.image:get_size()
  if self.zoom_mode == "fit" then
    if img_w < self.size.x then
      self.zoom_scale = 1
    else
      self.zoom_scale = math.min(self.size.x / img_w, self.size.y / img_h)
      self.zoom_scale = tonumber(string.format("%.2f", self.zoom_scale))
        or self.zoom_scale
      self.zoom_scale = self.zoom_scale - 0.01
      if self.zoom_scale > 1 then
        self.zoom_scale = 1
      end
    end
  end

  -- the renderer cells can not handle more than 8k so we limit the
  -- zoom to around 4k just to be on the safe side...
  local max_dim = 4096
  local max_scale_w = max_dim / img_w
  local max_scale_h = max_dim / img_h
  local max_allowed_scale = math.min(max_scale_w, max_scale_h)
  if self.zoom_scale > max_allowed_scale then
    self.zoom_scale = max_allowed_scale
  end

  local new_w = math.floor(img_w * self.zoom_scale)
  local new_h = math.floor(img_h * self.zoom_scale)
  local needs_scaling = true
  if self.image_scaled then
    local cw, ch = self.image_scaled:get_size()
    if new_w == cw and new_h == ch then
      needs_scaling = false
    end
  end

  if needs_scaling then
    self.image_scaled = self.image:scaled(new_w, new_h, "nearest")
  end

  if
    needs_scaling
    or
    self.bg_mode ~= config.images_background_mode
    or
    self.bg_color ~= config.images_background_color
  then
    self.bg_mode = config.images_background_mode
    self.bg_color = config.images_background_color
    self.width, self.height = self.image_scaled:get_size()

    if self.bg_mode == "grid" then
      self.background = canvas.new(
        self.width, self.height, { common.color "rgb(0,0,0)" }, false
      )
      local bright = { common.color "#AAAAAA" }
      local dark = { common.color "#555555" }
      local bsize = 50
      local bhalf = bsize / 2
      for h=0, self.height+(bsize*2), bhalf do
        for w=0, self.width+(bsize*2), bsize do
          self.background:draw_rect(w, h, bhalf, bhalf, dark, false)
          self.background:draw_rect(w+bhalf, h, bhalf, bhalf, bright, false)
        end
        local temp = bright
        bright = dark
        dark = temp
      end
    elseif self.bg_mode == "solid" then
      self.background = canvas.new(
        self.width, self.height, self.bg_color, true
      )
    else
      self.background = nil
    end
  end
end

---Increases the image scale.
function ImageView:zoom_in()
  self.zoom_mode = "fixed"
  self.zoom_scale = self.zoom_scale == 0.1 and 0.5 or self.zoom_scale + 0.5
  self:scale_image()
end

---Decreases the image scale.
function ImageView:zoom_out()
  self.zoom_mode = "fixed"
  self.zoom_scale = math.max(self.zoom_scale - 0.5, 0.1)
  self:scale_image()
end

---Sets image size to original.
function ImageView:zoom_reset()
  self.zoom_mode = "fixed"
  self.zoom_scale = 1
  self:scale_image()
end

function ImageView:get_scrollable_size()
  return self.height
end

function ImageView:get_h_scrollable_size()
  return self.width
end

function ImageView:on_mouse_pressed(button, x, y, clicks)
  if not ImageView.super.on_mouse_pressed(self, button, x, y, clicks) then
    self.mouse_pressed = true
    self.cursor = "hand"
  end
  return true
end

function ImageView:on_mouse_released(button, x, y)
  ImageView.super.on_mouse_released(self, button, x, y)
  self.mouse_pressed = false
  self.cursor = "arrow"
end

function ImageView:on_mouse_moved(x, y, dx, dy)
  if not ImageView.super.on_mouse_moved(self, x, y, dx, dy) then
    if self.mouse_pressed then
      self.scroll.to.x = self.scroll.to.x - dx
      self.scroll.to.y = self.scroll.to.y - dy
      return true
    end
    return false
  end
  return true
end

function ImageView:on_mouse_wheel(d)
  for _, val in pairs(keymap.modkeys) do
    if val then return false end
  end
  if d > 0 then self:zoom_in() else self:zoom_out() end
  return true
end

function ImageView:update()
  ImageView.super.update(self)
  if
    self.prev_size.x ~= self.size.x or self.prev_size.y ~= self.size.y
    or
    self.bg_mode ~= config.images_background_mode
    or
    self.bg_color ~= config.images_background_color
  then
    self:scale_image()
    self.prev_size = {x = self.size.x, y = self.size.y}
  end
end

function ImageView:draw_image()
  if not self.image_scaled then return end
  local w, h = self.image_scaled:get_size()
  local x, y = 0, 0
  if w < self.size.x then
    x = (self.size.x / 2) - (w / 2)
  end
  if h < self.size.y then
    y = (self.size.y / 2) - (h / 2)
  end
  if self.bg_mode == "grid" or self.bg_mode == "solid" then
    renderer.draw_canvas(
      self.background,
      self.position.x + x - self.scroll.x,
      self.position.y + y - self.scroll.y
    )
  end
  renderer.draw_canvas(
    self.image_scaled,
    self.position.x + x - self.scroll.x,
    self.position.y + y - self.scroll.y
  )
end

function ImageView:draw()
  self:draw_background(style.background)
  self:draw_image()
  self:draw_scrollbar()
end

---Check if an image type is supported by its filename extension.
---@param path string
---@return boolean supported
---@return string file_extension
function ImageView.is_supported(path)
  local ext = path:match("%.(%a+)$")
  if ext then
    ext = ext:ulower()
    if SUPPORTED_EXTENSIONS[ext] then
      return true, ext
    end
  end
  return false, ext
end


return ImageView

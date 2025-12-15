---@meta

---
---Core functionality that allows rendering into a separate surface.
---@class canvas
canvas = {}

---@alias canvas.scale_mode "linear" | "nearest"

---
---Creates a new canvas.
---
---@param width integer
---@param height integer
---@param color renderer.color Background color to initialize the Canvas with
---@param transparent? boolean Make the canvas transparent
---@return canvas
function canvas.new(width, height, color, transparent) end

---
---Loads an image into a new canvas.
---
---@param path string
---
---@return canvas? canvas
---@return string? errmsg
function canvas.load_image(path) end

---
---Loads an svg image with the specified width and height.
---
---@param path string
---@param width integer
---@param height integer
---
---@return canvas? canvas
---@return string? errmsg
function canvas.load_svg_image(path, width, height) end

---
---Returns the Canvas size.
---
---@return integer w
---@return integer h
function canvas:get_size() end

---
---Returns the pixels of the specified portion of the Canvas.
---
---If the coordinates are not specified, the whole Canvas is considered.
---The pixel format is RGBA32.
---
---@param x? integer
---@param y? integer
---@param width? integer
---@param height? integer
---@return string pixels
function canvas:get_pixels(pixels, x, y, width, height) end

---
---Overwrites the pixels of the Canvas with the specified ones.
---
---The pixel format *must be* RGBA32.
---
---@param pixels string
---@param x integer
---@param y integer
---@param width integer
---@param height integer
function canvas:set_pixels(pixels, x, y, width, height) end

---
---Copies (a part of) the Canvas in a new Canvas.
---
---If no arguments are passed, the Canvas is duplicated as-is.
---
---`new_width` and `new_height` specify the new size of the copied region.
---
---@param x? integer
---@param y? integer
---@param width? integer
---@param height? integer
---@param new_width? integer
---@param new_height? integer
---@param scale_mode? canvas.scale_mode
---@return canvas copied_canvas A copy of the Canvas
function canvas:copy(x, y, width, height, new_width, new_height, scale_mode) end

---
---Returns a scaled copy of the Canvas.
---
---@param new_width integer
---@param new_height integer
---@param scale_mode canvas.scale_mode
---@return canvas scaled_canvas A scaled copy of the Canvas
function canvas:scaled(new_width, new_height, scale_mode) end

---
---Clean the canvas, content will be replaced with transparent pixels,
---or a full opaque color if the canvas is not transparent.
---
---@param color? renderer.color Optional color used to fill the surface.
function canvas:clear(color) end

---
---Set the region of the Canvas where draw operations will take effect.
---
---@param x integer
---@param y integer
---@param width integer
---@param height integer
function canvas:set_clip_rect(x, y, width, height) end

---
---Draw a rectangle.
---
---@param x integer
---@param y integer
---@param width integer
---@param height integer
---@param color renderer.color
---@param replace boolean Overwrite the content with the specified color. Useful when dealing with alpha.
function canvas:draw_rect(x, y, width, height, color, replace) end

---
---Draw text and return the x coordinate where the text finished drawing.
---
---@param font renderer.font
---@param text string
---@param x number
---@param y integer
---@param color renderer.color
---@param tab_data? renderer.tab_data
---
---@return number x
function canvas:draw_text(font, text, x, y, color, tab_data) end

---
---Draw a Canvas.
---
---@param canvas canvas
---@param x integer
---@param y integer
---@param blend boolean Whether to blend the Canvas, or replace the pixels
function canvas:draw_canvas(canvas, x, y, blend) end

---
---Draws a filled polygon, consisting of curves and points.
---The polygon is filled using the non-zero winding rule in clockwise direction.
---
---The function returns the control box of the polygon,
---which is greater than or equal to the dimensions of the rendered polygon.
---It is not guaranteed to the exact dimension of the rendered polygon.
---
---@param poly renderer.poly_object[] the lines or curves to draw, up to 65535 points.
---@param color renderer.color
---
---@return number x the X coordinate of top left corner of the control box.
---@return number y the Y coordinate of the top left corner of the control box.
---@return number w the width of the control box.
---@return number h the height of the control box.
function canvas:draw_poly(poly, color) end

---
---Explicitly render all the draw commands sent to the canvas so far
---without having to render the canvas into a window first.
---
function canvas:render() end

---
---Save the current canvas as an image.
---
---@param filename string
---@param type? "png" | "jpg" | "avif" Defaults to "png"
---@param quality? integer A number from 1 to 100 used for jpg and avif. Defaults to 100
---
---@return boolean saved
---@return string? errmsg
function canvas:save_image(filename, type, quality) end

return canvas

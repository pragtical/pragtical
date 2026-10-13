local core = require "core"
local common = require "core.common"
local command = require "core.command"
local style = require "core.style"
local Widget = require "widget"
local Dialog = require "widget.dialog"
local Label = require "widget.label"
local Button = require "widget.button"
local ListBox = require "widget.listbox"
local NoteBook = require "widget.notebook"

---Application information displayed in the About dialog.
---@class core.aboutview : widget
---@overload fun(parent:widget):core.aboutview
---@field title widget.label Application name
---@field version widget.label Build version
---@field description widget.label Application description
---@field renderer_info widget.label Active renderer details
---@field website widget.button Application website link
---@field notebook widget.notebook Contributors and license tabs
---@field contributors widget.listbox Contributor names, roles and website links
---@field license widget Scrollable license pane
---@field license_content widget License text container with space reserved for the scrollbar
---@field license_labels widget.label[] Wrapped license paragraphs and copyright notices
---@field license_text string Full application license text
local AboutView = Widget:extend()

local license = [[MIT License

Copyright (c) 2020 rxi
Copyright (c) 2021 Lite XL Team
Copyright (c) 2023 Pragtical Team

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.]]

local contributors = {
  { "Rxi", "Lite Founder", "https://github.com/rxi" },
  { "Francesco Abbate", "Lite XL Founder", "https://github.com/franko" },
  { "jgmdev", "Pragtical Founder, Core, Plugins", "https://github.com/jgmdev" },
  { "AmerM137", "Pragtical Contributor, Colors, Ninja", "https://github.com/AmerM137" },
  { "juliardi",	"Pragtical Contributor, Evangelist", "https://github.com/juliardi" },
  { "Walkero", "Pragtical Amiga Port, Tests", "https://github.com/walkero-gr" },
  { "Jan", "Pragtical Contributor", "https://github.com/Jan200101" },
  { "tacf", "Pragtical Contributor", "https://github.com/tacf" },
  { "detomastah", "Pragtical Contributor", "https://github.com/detomastah" },
  { "acook", "Pragtical Contributor", "https://github.com/acook" },
  { "Adam Harrison", "Core", "https://github.com/adamharrison" },
  { "Andrea Zanellato", "CI, Website", "https://github.com/redtide" },
  { "Björn Buckwalter", "MacOS Support", "https://github.com/bjornbm" },
  { "boppyt", "Contributor", "https://github.com/boppyt" },
  { "Cukmekerb", "Contributor", "https://github.com/vincens2005" },
  { "Daniel Rocha", "Contributor", "https://github.com/dannRocha" },
  { "daubaris", "Contributor", "https://github.com/daubaris" },
  { "Dheisom Gomes", "Contributor", "https://github.com/dheisom" },
  { "Evgeny Petrovskiy", "Contributor", "https://github.com/eugenpt" },
  { "Ferdinand Prantl", "Contributor", "https://github.com/prantlf" },
  { "Janis-Leuenberger", "MacOS Support", "https://github.com/Janis-Leuenberger" },
  { "Jipok", "Contributor", "https://github.com/Jipok" },
  { "Joshua Minor", "Contributor", "https://github.com/jminor" },
  { "George Linkovsky", "Contributor", "https://github.com/Timofffee" },
  { "Guldoman", "Core", "https://github.com/Guldoman" },
  { "liquidev", "Contributor", "https://github.com/liquidev" },
  { "Mat Mariani", "MacOS Support", "https://github.com/mathewmariani" },
  { "Nightwing", "Contributor", "https://github.com/Nightwing13" },
  { "Nils Kvist", "Contributor", "https://github.com/budRich" },
  { "Not-a-web-Developer", "Contributor", "https://github.com/Not-a-web-Developer" },
  { "Robert Štojs", "CI", "https://github.com/netrobert" },
  { "sammyette", "Plugins", "https://github.com/TorchedSammy" },
  { "Takase", "Core", "https://github.com/takase1121" },
  { "xwii", "Contributor", "https://github.com/xcb-xwii" }
}

---Create the About contents inside an existing pane or dialog panel.
---@param parent widget Container that provides the available width and height
function AboutView:new(parent)
  AboutView.super.new(self, parent)
  self.border.width = 0
  self.scrollable = false
  self.title = Label(self, "Pragtical")
  self.title.font = "big_font"
  self.version = Label(self, "version " .. VERSION, true)
  self.description = Label(
    self,
    "A lightweight text editor written in Lua, adapted from lite.",
    true
  )
  local info = core.window:get_renderer_info()
  local parts = { "Renderer: " .. info.backend }
  if info.power then table.insert(parts, info.power) end
  if info.device then table.insert(parts, info.device) end
  self.renderer_info = Label(self, table.concat(parts, ", "), true)
  self.website = Button(self, "Visit Website")
  self.website:set_icon("G")
  self.website:set_tooltip("Open Pragtical Website", "core:view-website")
  ---Open the application website through its existing command.
  function self.website:on_click() command.perform "core:view-website" end
  self.notebook = NoteBook(self)
  self.notebook.border.width = 0
  self.notebook.scrollable = false
  self.notebook:set_size(300 * SCALE, 200 * SCALE)
  local contributors_pane = self.notebook:add_pane("contributors", "Contributors")
  contributors_pane.border.width = 0
  contributors_pane.scrollable = false
  self.contributors = ListBox(contributors_pane)
  self.contributors.scrollable = true
  self.contributors:add_column("Contributors")
  self.contributors:add_column("")
  self.contributors:add_column("Website")
  ---Open the website associated with the clicked contributor.
  ---@param data string Contributor website URL
  function self.contributors:on_row_click(_, data)
    common.open_in_system(data)
  end
  for _, contributor in ipairs(contributors) do
    self.contributors:add_row(
      {
        contributor[1],
        ListBox.COLEND,
        contributor[2],
        ListBox.COLEND,
        contributor[3]
      },
      contributor[3]
    )
  end
  self.license = self.notebook:add_pane("license", "License")
  self.license_text = license
  self.license_content = Widget(self.license)
  self.license_content.border.width = 0
  self.license_content.scrollable = false
  self.license_labels = {}
  for paragraph in (license .. "\n\n"):gmatch("(.-)\n\n") do
    if paragraph:match("^Copyright") then
      for notice in paragraph:gmatch("[^\n]+") do
        table.insert(
          self.license_labels,
          Label(self.license_content, notice, true)
        )
      end
    else
      table.insert(
        self.license_labels,
        Label(self.license_content, paragraph:gsub("\n", " "), true)
      )
    end
  end
end

---Center the information and reserve the remaining panel space for the tabs.
---Keep usable tab contents in short windows so the parent panel can scroll.
function AboutView:update_positions()
  local center = self.size.x / 2
  self.title:set_label("Pragtical")
  local previous
  for _, label in ipairs {
    self.title, self.version, self.description, self.renderer_info
  } do
    label:set_position(
      center - label:get_width() / 2,
      previous and previous:get_bottom() + style.padding.y / 2 or style.padding.y
    )
    previous = label
  end
  self.website:set_position(
    center - self.website:get_width() / 2,
    self.renderer_info:get_bottom() + style.padding.y
  )
  -- Child content offsets round to pixels; align the tab viewport to the same grid.
  local top = common.round(self.website:get_bottom() + style.padding.y)
  self.notebook:set_position(style.padding.x, top)
  self.notebook:set_size(
    math.max(1, self.size.x - style.padding.x * 2),
    math.max(120 * SCALE, self.size.y - top - style.padding.y)
  )
  self:set_size(nil, self.notebook:get_bottom() + style.padding.y)
  self.contributors:set_position(0, 0)
  self.contributors:set_size(
    self.contributors.parent.size.x,
    self.contributors.parent.size.y
  )
  self.license_content:set_position(style.padding.x, style.padding.y)
  self.license_content:set_size(
    math.max(
      1,
      self.license.size.x
        - style.padding.x * 2
        - style.expanded_scrollbar_size
        - SCALE
    )
  )
  local bottom = 0
  for index, label in ipairs(self.license_labels) do
    label:set_position(0, bottom)
    -- Keep copyright notices together and separate the license paragraphs.
    bottom = label:get_bottom() + (
      (index == 2 or index == 3) and 0 or style.padding.y
    )
  end
  self.license_content:set_size(nil, bottom)
  self.contributors:set_visible_rows()
end

---Fill the parent panel and refresh layout after labels have updated their wrapping.
---@return boolean updated Whether this visible view was updated
function AboutView:update()
  self:set_size(self.parent.size.x, self.parent.size.y)
  if not AboutView.super.update(self) then return false end
  self:update_positions()
  return true
end

---Dialog host for the About contents.
---@class core.aboutview.dialog : widget.dialog
---@overload fun():core.aboutview.dialog
local AboutDialog = Dialog:extend()

---Create a modal dialog that restores editor focus when dismissed.
function AboutDialog:new()
  AboutDialog.super.new(self, "About Pragtical")
  self.name = "About Pragtical"
  self:set_floating(true, {
    modal = true,
    focus = "show",
    dismiss_on_escape = true
  })
  AboutView(self:get_panel())
end

---Fit the scaled outer size inside the editor window and center the dialog.
---Preserve the current tab, contents and keyboard focus.
function AboutDialog:fit_to_window()
  local width, height = system.get_window_size(core.window)
  self:set_size(
    math.max(1, math.min(760 * SCALE, width - style.padding.x * 4)),
    math.max(1, math.min(560 * SCALE, height - style.padding.y * 4))
  )
  self:centered()
end

---Resize and recenter the shown dialog before laying out its scaled controls.
---@param new_scale number Updated editor scale
---@param prev_scale number Previous editor scale
function AboutDialog:on_scale_change(new_scale, prev_scale)
  self:fit_to_window()
  AboutDialog.super.on_scale_change(self, new_scale, prev_scale)
end

---Lay out the dialog header and panel without resizing its outer bounds.
---Widget sizes exclude borders; set_size() expects sizes including borders.
function AboutDialog:update_size_position()
  Widget.update_size_position(self)
  self.title:set_position(style.padding.x / 2, style.padding.y / 2)
  self.close:set_position(
    self.size.x - self.close:get_width() - style.padding.x / 2,
    style.padding.y / 2
  )
  local top = self.title:get_bottom() + style.padding.y / 2
  self.panel:set_position(0, top)
  self.panel:set_size(self.size.x, math.max(1, self.size.y - top))
end

---@type core.aboutview.dialog?
local dialog

---Show or raise the modal About dialog, fitting it to the editor window.
---Escape and the title-bar close button restore the previous editor focus.
---@return core.aboutview.dialog dialog Shown dialog, reused on subsequent calls
function AboutView.show_dialog()
  if not dialog then
    dialog = AboutDialog()
  end
  -- Hidden widgets store pending sizes; show the reused dialog before resizing it.
  dialog:show()
  dialog:fit_to_window()
  dialog:update_size_position()
  dialog:bring_to_front()
  return dialog
end

return AboutView

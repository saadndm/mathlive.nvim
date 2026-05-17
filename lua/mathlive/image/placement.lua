local Image = require("mathlive.image.image")
local Renderer = require("mathlive.image.renderer")
local Terminal = require("mathlive.image.terminal")
local State = require("mathlive.state")
local Util = require("mathlive.util")

---@class mathlive.image.Placement
---@field id                     integer
---@field buf                    integer
---@field img                    mathlive.Image
---@field kind                   mathlive.image.Kind
---@field eids                   integer[]
---@field hidden                 boolean
---@field closed                 boolean
---@field extmark?               integer
---@field _grid?                 string[]
---@field _range?                Range4
---@field _range_changedtick?    integer
---@field _multiline_inline_row? integer
---@field _kitty_img_id?         integer
---@field _kitty_size?           mathlive.image.Size
local M = {}
M.__index = M

local ns = vim.api.nvim_create_namespace("mathlive.image")
M.ns = ns

---@param buf     integer
---@param src     string
---@param kind    mathlive.image.Kind
---@param extmark integer?
function M.new(buf, src, kind, extmark)
  assert(type(buf) == "number", "`Placement.new`: buf should be a number")
  assert(type(src) == "string", "`Placement.new`: src should be a string")
  local self = setmetatable({}, M)

  self.id = Terminal.generate_id()
  self.buf = buf
  self.img = Image.new(src)
  self.img.placements[self.id] = self
  self.kind = kind
  self.eids = {}
  self.hidden = false
  self.closed = false
  self.extmark = extmark

  return self
end

function M:get_range()
  assert(self.extmark, "`Placement:get_range` requires valid extmark")
  if not vim.api.nvim_buf_is_valid(self.buf) then
    self._range = nil
    self._range_changedtick = nil
    return
  end

  local changedtick = vim.b[self.buf].changedtick
  if self._range and self._range_changedtick == changedtick then
    return self._range
  end
  self._range = Util.is_valid_extmark(self.buf, State.ns, self.extmark)
  self._range_changedtick = changedtick

  return self._range
end

---@param range Range4
function M:set_range(range)
  self._range = range
  self._range_changedtick = vim.b[self.buf].changedtick
end

function M:hide()
  if self.hidden then return end
  self.hidden = true
  self._range = nil
  self._range_changedtick = nil

  Renderer.unindex_multiline_inline(self)

  for _, eid in ipairs(self.eids) do
    vim.api.nvim_buf_del_extmark(self.buf, ns, eid)
  end
  self.eids = {}
end

function M:show()
  if self.closed or not self.hidden then return end
  self.hidden = false

  self:render()
end

function M:close()
  if self.closed then return end
  self.closed = true
  self:hide()
  self.img:del(self.id)
  self.eids = {}
  self._kitty_img_id = nil
  self._kitty_size = nil
  Util.del_hl("MathLiveImage" .. self.id)
end

---@param new_file string
function M:replace(new_file)
  local old_img = self.img

  Renderer.unindex_multiline_inline(self)

  self.file = new_file
  self.img = Image.new(new_file)
  self.img.placements[self.id] = self
  self._grid = nil
  self._kitty_img_id = nil
  self._kitty_size = nil

  if old_img ~= self.img then
    old_img:del(self.id)
  end
end

--- Renders the unicode placeholder grid in the buffer
---@param cell_size mathlive.image.Size
function M:render_grid(cell_size)
  local hl = "MathLiveImage" .. self.id -- image id is encoded in the foreground color
  Util.set_hl({
    [hl] = {
      fg = self.img.id,
      sp = self.id,
      nocombine = true
    }
  })

  Renderer.render(self, cell_size, hl)
end

---@param extmarks mathlive.image.ExtmarkSpec[]
function M:_render(extmarks)
  for _, e in ipairs(extmarks) do
    e.undo_restore = false
    e.strict = false
    if self.hidden then
      e.virt_text = nil
      e.conceal = nil
      e.virt_lines = nil
    end
  end
  local eids = {} ---@type integer[]
  for _, extmark in ipairs(extmarks) do
    local row, col = extmark.row, extmark.col
    extmark.row, extmark.col, extmark.id = nil, nil, table.remove(self.eids, 1)
    table.insert(eids, vim.api.nvim_buf_set_extmark(self.buf, ns, row, col, extmark))
  end
  for _, eid in ipairs(self.eids) do
    vim.api.nvim_buf_del_extmark(self.buf, ns, eid)
  end
  self.eids = eids
end

function M:render()
  if self.closed or self.hidden then return end

  self.img:ensure_sent(function (supported)
    if not supported or self.closed or self.hidden then return end
    local cell_size = Util.pixels_to_cells(self.img.size)
    local kitty_size = self._kitty_size
    if self._kitty_img_id ~= self.img.id or not kitty_size
      or kitty_size.width ~= cell_size.width or kitty_size.height ~= cell_size.height then
      Terminal.create_virtual_placement(self.img.id, self.id, cell_size.width, cell_size.height)
      self._kitty_img_id = self.img.id
      self._kitty_size = cell_size
    end
    self:render_grid(cell_size)
  end)
end

return M

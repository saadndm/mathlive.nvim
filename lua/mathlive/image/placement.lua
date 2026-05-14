local Image = require("mathlive.image.image")
local Renderer = require("mathlive.image.renderer")
local Terminal = require("mathlive.image.terminal")
local State = require("mathlive.state")
local Util = require("mathlive.util")

---@class mathlive.image.Placement
---@field id      integer
---@field buf     integer
---@field hidden? boolean
local M = {}
M.__index = M

---@alias mathlive.image.Extmark vim.api.keyset.set_extmark | { row: integer, col: integer }

local ns = vim.api.nvim_create_namespace("mathlive.image")
M.ns = ns

---@param buf   integer
---@param src   string
---@param opts? mathlive.image.Opts
function M.new(buf, src, opts)
  assert(type(buf) == "number", "`Placement.new`: buf should be a number")
  assert(type(src) == "string", "`Placement.new`: src should be a string")
  local self = setmetatable({}, M)

  self.img = Image.new(src)
  self.img:place(self)
  self.opts = opts or {}
  self.buf = buf
  self.file = src
  self.eids = {}

  return self
end

---@return Range4?
function M:get_range()
  if not self.opts.extmark then return end
  if not vim.api.nvim_buf_is_valid(self.buf) then return end
  return Util.is_valid_extmark(self.buf, State.ns, self.opts.extmark)
end

function M:hide()
  if self.hidden then
    return
  end
  self.hidden = true

  for _, eid in ipairs(self.eids) do
    vim.api.nvim_buf_del_extmark(self.buf, ns, eid)
  end
  self.eids = {}
end

function M:show()
  if not self.hidden then
    return
  end
  self.hidden = false

  self:render_when_ready()
end

function M:close()
  self:hide()
  self.img:del(self.id)
  self.eids = {}
end

---@param new_file string
function M:replace(new_file)
  local old_img = self.img

  self.file = new_file
  self.img = Image.new(new_file)
  self.img:place(self)
  self._grid = nil

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

---@param extmarks mathlive.image.Extmark[]
function M:_render(extmarks)
  for _, e in ipairs(extmarks) do
    e.undo_restore = false
    e.strict = false
    if self.hidden then
      e.virt_text = nil
      e.conceal = nil
      if e.virt_lines then
        e.virt_lines = vim.tbl_map(function (l)
          return { { "" } }
        end, e.virt_lines)
      end
    end
  end
  local eids = {} ---@type number[]
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
  local cell_size = Util.pixels_to_cells(self.img.size)
  Terminal.create_virtual_placement(self.img.id, self.id, cell_size.width, cell_size.height)
  self:render_grid(cell_size)
end

function M:render_when_ready()
  Terminal.detect(function (supported)
    if not supported then return end
    if not self.img.sent then
      self.img:send()
    end
    self:render()
  end)
end

return M

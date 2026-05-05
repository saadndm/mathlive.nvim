local Image = require("mathlive.image.image")
local Renderer = require("mathlive.image.renderer")
local Terminal = require("mathlive.image.terminal")
local State = require("mathlive.state")
local Util = require("mathlive.util")

---@class mathlive.image.Placement
---@field id integer
---@field buf integer
---@field hidden? boolean
---@field closed? boolean
---@field _state? mathlive.image.State
local M = {}
M.__index = M

---@alias mathlive.image.Extmark vim.api.keyset.set_extmark|{row:integer, col:integer}

local ns = vim.api.nvim_create_namespace("mathlive.image")
M.ns = ns
local placements = {} ---@type table<number, table<number, mathlive.image.Placement?>?>

---@param buf integer
---@param src string
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
  self.augroup = vim.api.nvim_create_augroup("mathlive.image." .. self.id, { clear = true })
  self.eids = {}

  if self.opts.auto_resize then
    vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter", "BufWinLeave", "BufEnter" }, {
      group = self.augroup,
      buffer = self.buf,
      callback = function()
        vim.schedule(function()
          self:update()
        end)
      end,
    })
    vim.api.nvim_create_autocmd({ "WinClosed", "WinNew", "WinEnter", "WinResized" }, {
      group = self.augroup,
      callback = function()
        vim.schedule(function()
          self:update()
        end)
      end,
    })
  end
  placements[self.buf] = placements[self.buf] or {}
  placements[self.buf][self.id] = self

  if self:ready() then
    vim.schedule(function()
      self:update()
    end)
  elseif self.img:failed() then
    self:error()
  elseif not self.opts.type or not self.opts.type:match("^preview") then
    -- temporary extmark so that we can keep track of unloaded images in the buffer
    local range = self:get_range()
    if range then
      self:_render({
        {
          row = range[1],
          col = range[2],
        },
      })
    end
  else
    self:progress()
  end

  local update = self.update
  self.update = Util.debounce(function()
    update(self)
  end, { ms = 10 })
  return self
end

---@return Range4?
function M:get_range()
  if not self.opts.extmark then return end
  if not vim.api.nvim_buf_is_valid(self.buf) then return end
  return Util.is_valid_extmark(self.buf, State.ns, self.opts.extmark)
end

function M:error()
  if self.opts.type == 'inline_formula' then
    return
  end
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, {
    "# Image Load Failed",
    "",
    "Could not read: " .. self.img.file
  })
  vim.api.nvim_set_option_value("syntax", "markdown", { buf = self.buf })
end

function M:progress()
  if self.opts.type == 'inline_formula' or self:ready() then
    return
  end
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, {})
  vim.bo[self.buf].modifiable = false
  local timer = assert(vim.uv.new_timer())
  timer:start(
    0,
    80,
    vim.schedule_wrap(function()
      if self:ready() or self.img:failed() or not vim.api.nvim_buf_is_valid(self.buf) then
        timer:stop()
        if not timer:is_closing() then
          timer:close()
        end
        return
      end
      vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
      vim.api.nvim_buf_set_extmark(self.buf, ns, 0, 0, {
        virt_text = {
          { Util.spinner(),                  "MathLiveImageSpinner" },
          { " " },
          { self.img.file .. " loading ...", "MathLiveImageLoading" },
        },
      })
    end)
  )
end

---@return integer[]
function M:wins()
  ---@param win integer
  return vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_buf(win) == self.buf
  end, vim.api.nvim_tabpage_list_wins(0))
end

function M:hide()
  if self.hidden or not self:ready() then
    return
  end
  self.hidden = true
  self._state = nil -- Force re-render
  self:update()
end

function M:show()
  if not self.hidden or not self:ready() then
    return
  end
  self.hidden = false
  self._state = nil -- Force re-render
  self:update()
end

function M:close()
  if self.closed then
    return
  end
  if placements[self.buf] then
    placements[self.buf][self.id] = nil
  end
  self.closed = true
  self:del()
  pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
end

---@param extmark integer
function M:move(extmark)
  if self.closed then return end
  self.opts.extmark = extmark
  self._state = nil
  self:update()
end

---@param src string
function M:replace(src)
  if self.closed then return end

  local old_img = self.img
  self.file = src
  self.img = Image.new(src)
  self.img:place(self)
  self._state = nil

  if self:ready() then
    self:update()
  elseif self.img:failed() then
    self:error()
  else
    self:progress()
  end

  if old_img ~= self.img then
    self._replace_old_img = old_img
  end
end

function M:delete()
  self:close()
end

function M:del()
  self.img:del(self.id)
  -- Clear all rendering extmarks
  if vim.api.nvim_buf_is_valid(self.buf) then
    for _, eid in ipairs(self.eids) do
      pcall(vim.api.nvim_buf_del_extmark, self.buf, ns, eid)
    end
  end
  self.eids = {}
end

--- Renders the unicode placeholder grid in the buffer
---@param size mathlive.image.Size
function M:render_grid(size)
  local hl = "MathLiveImage" .. self.id -- image id is encoded in the foreground color
  Util.set_hl({
    [hl] = {
      fg = self.img.id,
      sp = self.id,
      nocombine = true,
    },
  })

  Renderer.render(self, size, hl)
end

---@param extmarks mathlive.image.Extmark[]
function M:_render(extmarks)
  -- First, delete ALL old extmarks
  if vim.api.nvim_buf_is_valid(self.buf) then
    for _, eid in ipairs(self.eids) do
      pcall(vim.api.nvim_buf_del_extmark, self.buf, ns, eid)
    end
  end
  self.eids = {}

  -- Apply hidden state to extmarks
  for _, e in ipairs(extmarks) do
    e.undo_restore = false
    e.strict = false
    if self.hidden then
      e.virt_text = nil
      e.conceal = nil
      e.conceal_lines = nil
      e.virt_lines = nil
    end
  end

  -- Create new extmarks
  for _, extmark in ipairs(extmarks) do
    local row, col = extmark.row or 0, extmark.col or 0
    extmark.row, extmark.col = nil, nil
    local ok, eid = pcall(vim.api.nvim_buf_set_extmark, self.buf, ns, row, col, extmark)
    if ok and eid then
      table.insert(self.eids, eid)
    end
  end
end

function M:render_fallback(state)
  Renderer.render_fallback(self, state)
end

---@return mathlive.image.State
function M:state()
  local wins = {} ---@type number[]
  local is_fallback = not Terminal.env().placeholders
  local zindex = vim.api.nvim_win_get_config(0).zindex or 0

  for _, win in ipairs(self:wins()) do
    if is_fallback then
      local z = vim.api.nvim_win_get_config(win).zindex or 0
      if z >= zindex or (zindex > 0 and z > 0) then
        wins[#wins + 1] = win -- use if higher z-index or both are floating
      end
    else
      wins[#wins + 1] = win
    end
  end

  local size = Util.pixels_to_cells(self.img.size)

  -- Get current range from extmark (always fresh)
  local range = self:get_range()

  ---@class mathlive.image.State
  ---@field hidden boolean
  ---@field size mathlive.image.Size
  ---@field wins number[]
  ---@field range Range4?
  return {
    hidden = self.hidden or false,
    size = size,
    wins = wins,
    range = range,
  }
end

function M:valid()
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) or not self:ready() then
    return false
  end
  -- For extmark-tracked placements, check if extmark still exists and has valid range
  if self.opts.extmark then
    local range = self:get_range()
    if not range then
      return false -- Extmark was deleted or collapsed
    end
    return range[1] < vim.api.nvim_buf_line_count(self.buf)
  end
  -- For preview placements without extmark tracking, always valid if buffer is valid
  return true
end

function M:update()
  if not self:ready() then
    return
  end

  if not self:valid() then
    self:close()
    return
  end

  if self.opts.on_update_pre then
    self.opts.on_update_pre(self)
  end

  local state = self:state()
  if vim.deep_equal(state, self._state) then
    return
  end
  self._state = state

  if #state.wins == 0 then
    self:del()
    return
  end

  self.img:place(self)

  Terminal.detect(function()
    if not self:valid() or self.closed then return end

    if Terminal.env().placeholders then
      Terminal.request({
        a = "p",
        U = 1,
        i = self.img.id,
        p = self.id,
        C = 1,
        c = state.size.width,
        r = state.size.height,
      })
      self:render_grid(state.size)
    else
      self:render_fallback(state)
    end

    if self._replace_old_img then
      self._replace_old_img:del(self.id)
      self._replace_old_img = nil
    end

    if self.opts.on_update then
      self.opts.on_update(self)
    end
  end)
end

function M:ready()
  return not self.closed and self.buf and vim.api.nvim_buf_is_valid(self.buf) and self.img:ready()
end

return M

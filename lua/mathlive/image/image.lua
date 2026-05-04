local Terminal = require("mathlive.image.terminal")
local Util = require("mathlive.util")

---@class mathlive.Image
---@field src string
---@field file string
---@field mtime uv.fs_stat.result.time
---@field id integer image id. unique per nvim instance and file
---@field sent? boolean image data is sent
---@field placements table<number, mathlive.image.Placement> image placements
---@field size mathlive.image.Size
---@field height? integer
---@field fsize? number
local M = {}
M.__index = M

local CHUNK_SIZE = 4096
local images = {} ---@type table<string, mathlive.Image?>
local NVIM_ID_BITS = 10
local MAX_FSIZE = 200 * 1024 * 1024 -- 200MB
local _id = 30
local _pid = 10
local nvim_id = 0
local lru = {} ---@type {img:mathlive.Image, used:number}[]
local lru_fsize = 0.0

---@param img mathlive.Image
local function use(img)
  if img.fsize == 0 then
    return
  end
  local now = os.time()
  for _, v in ipairs(lru) do
    if v.img == img then
      v.used = now
      return
    end
  end
  table.sort(lru, function(a, b)
    return a.used > b.used
  end)
  while lru_fsize >= MAX_FSIZE and #lru > 0 do
    local i = table.remove(lru).img
    i.sent = false
    lru_fsize = lru_fsize - (i.fsize or 0)
  end
  lru_fsize = lru_fsize + (img.fsize or 0)
  table.insert(lru, { img = img, used = now })
end

---@param file string
function M.new(file)
  local self = setmetatable({}, M)
  self.file = file

  local fs_stat = vim.uv.fs_stat(file)
  if fs_stat then
    if images[self.file] and vim.deep_equal(images[self.file].mtime, fs_stat.mtime) then
      return images[self.file]
    end
    self.mtime = fs_stat.mtime
  end

  images[self.file] = self
  _id = _id + 1
  local bit = require("bit")
  -- generate a unique id for this nvim instance (10 bits)
  if nvim_id == 0 then
    local pid = vim.fn.getpid()
    nvim_id = bit.band(bit.bxor(pid, bit.rshift(pid, 5), bit.rshift(pid, NVIM_ID_BITS)), 0x3FF)
  end
  -- interleave the nvim id and the image id
  self.id = bit.bor(bit.lshift(nvim_id, 24 - NVIM_ID_BITS), _id)
  self.placements = {}

  if self:ready() then
    self:on_ready()
  end

  return self
end

function M:on_ready()
  if not self.sent then
    self.fsize = vim.fn.getfsize(self.file)

    self.size = Util.dim(self.file)

    -- Wait for terminal detection before sending
    Terminal.detect(function()
      self:send()
    end)
  end
end

function M:on_send()
  use(self)
  for _, placement in pairs(self.placements) do
    placement._state = nil
    placement:update()
  end
end

function M:failed()
  return self.file and vim.fn.filereadable(self.file) == 0
end

function M:ready()
  return self.file and vim.fn.filereadable(self.file) == 1
end

-- create the image
function M:send()
  assert(not self.sent, "Image already sent")
  self.sent = true
  -- local image
  if not Terminal.env().remote then
    Terminal.request({
      t = "f",
      i = self.id,
      f = 100,
      data = vim.base64.encode(self.file),
    })
  else
    -- remote image
    local fd = assert(io.open(self.file, "rb"), "Failed to open file: " .. self.file)
    local data = fd:read("*a")
    fd:close()
    data = vim.base64.encode(data) -- encode the data
    local offset = 1
    while offset <= #data do
      local chunk = data:sub(offset, offset + CHUNK_SIZE - 1)
      local first = offset == 1
      offset = offset + CHUNK_SIZE
      local last = offset > #data
      if first then
        Terminal.request({
          t = "d",
          i = self.id,
          f = 100,
          m = last and 0 or 1,
          data = chunk,
        })
      else
        Terminal.request({
          m = last and 0 or 1,
          data = chunk,
        })
      end
      vim.uv.sleep(1)
    end
  end
  self:on_send()
end

---@param placement mathlive.image.Placement
function M:place(placement)
  if not placement.id then
    _pid = _pid + 1
    placement.id = _pid
  end
  self.placements[placement.id] = placement
  if self.sent then
    use(self)
  elseif self:ready() then
    -- Wait for terminal detection before sending
    Terminal.detect(function()
      if not self.sent then
        self:send()
      end
    end)
  end
end

---@param placement mathlive.image.Placement
function M:unplace(placement)
  self.placements[placement.id] = nil
  if not next(self.placements) then
    Terminal.request({ a = "d", d = "i", i = self.id })
    if images[self.file] == self then
      images[self.file] = nil
    end
  end
end

---@param pid? number
function M:del(pid)
  for _, id in ipairs(pid and { pid } or vim.tbl_keys(self.placements)) do
    Terminal.request({ a = "d", d = "i", i = self.id, p = id })
    self.placements[id] = nil
  end

  if not next(self.placements) then
    Terminal.request({ a = "d", d = "i", i = self.id })
    if images[self.file] == self then
      images[self.file] = nil
    end
  end
end

function M.clear()
  images = {}
end

return M

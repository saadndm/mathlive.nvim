local Terminal = require("mathlive.image.terminal")
local Util = require("mathlive.util")

---@class mathlive.Image
---@field id integer image id. unique per nvim instance and file
---@field file string
---@field mtime uv.fs_stat.result.time
---@field size mathlive.image.Size
---@field sent? boolean image data is sent
---@field placements table<number, mathlive.image.Placement> image placements
local M = {}
M.__index = M

local images = {} ---@type table<string, mathlive.Image?>

---@param file string
function M.new(file)
  file = vim.fs.normalize(file)
  local fs_stat = vim.uv.fs_stat(file)
  assert(fs_stat, "Image does not exist: " .. file)

  if images[file] and vim.deep_equal(images[file].mtime, fs_stat.mtime) then
    return images[file]
  end

  local self = setmetatable({}, M)
  self.file = file
  self.mtime = fs_stat.mtime
  self.size = Util.dim(file)
  self.placements = {}

  images[file] = self

  self.id = Terminal.generate_id()

  return self
end

-- create the image
function M:send()
  assert(not self.sent, "Image already sent")
  self.sent = true
  if not Terminal.env().remote then
    Terminal.transmit_local_png(self.id, self.file)
  else
    local fd = assert(io.open(self.file, "rb"), "Failed to open file: " .. self.file)
    local data = fd:read("*a")
    fd:close()

    Terminal.transmit(self.id, data)
  end
end

---@param placement mathlive.image.Placement
function M:place(placement)
  if not placement.id then
    placement.id = Terminal.generate_id()
  end
  self.placements[placement.id] = placement
  -- Wait for terminal detection before sending
  Terminal.detect(function()
    if not self.sent then
      self:send()
    end
  end)
end

---@param pid integer
function M:del(pid)
  if not self.placements[pid] then
    return
  end

  Terminal.delete_placement(self.id, pid)
  self.placements[pid] = nil
  if not next(self.placements) then
    Terminal.delete_image(self.id)
    self.sent = false
    if images[self.file] == self then
      images[self.file] = nil
    end
  end
end

return M

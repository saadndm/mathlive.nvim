---@class mathlive.image.terminal
---@field supported   boolean?
---@field generate_id fun(): integer
local M = {}

local pending  ---@type fun(supported: boolean)[]?

---@param terminal string
local function is_supported(terminal)
  return terminal:find("ghostty", 1, true) ~= nil or terminal:find("kitty", 1, true) ~= nil
end

--- Detect whether terminal supports kitty graphics protocol placeholders
---@param cb fun(supported: boolean)
function M.detect(cb)
  if M.supported ~= nil then
    return cb(M.supported)
  end

  if pending then
    pending[#pending + 1] = cb
    return
  end
  pending = { cb }

  local function finish(supported)
    M.supported = supported
    local callbacks = pending
    pending = nil
    for _, fn in ipairs(callbacks) do
      fn(supported)
    end
  end

  if vim.env.TMUX then
    vim.system({ "tmux", "display-message", "-p", "#{client_termname}" }, { text = true }, function (obj)
      local supported = obj.code == 0 and is_supported((obj.stdout or ""):lower())
      if supported then
        vim.system({ "tmux", "set", "-p", "allow-passthrough", "all" })
      end

      vim.schedule(function ()
        finish(supported)
      end)
    end)
    return
  end

  local term = table.concat({ vim.env.TERM or "", vim.env.TERM_PROGRAM or "" }, " "):lower()
  finish(is_supported(term))
end

function M.write(data)
  if vim.env.TMUX then
    data = "\027Ptmux;" .. data:gsub("\027", "\027\027") .. "\027\\"
  end

  if vim.api.nvim_ui_send then
    vim.api.nvim_ui_send(data)
  else
    io.stdout:write(data)
    io.stdout:flush()
  end
end

M.generate_id = (function ()
  local bit = require("bit")
  local NVIM_PID_BITS = 10

  local nvim_pid = 0
  local cnt = 30

  ---@return integer
  return function ()
    if nvim_pid == 0 then
      local pid = vim.fn.getpid()
      nvim_pid = bit.band(bit.bxor(pid, bit.rshift(pid, 5), bit.rshift(pid, NVIM_PID_BITS)), 0x3FF)
    end
    cnt = cnt + 1
    return bit.bor(bit.lshift(nvim_pid, 24 - NVIM_PID_BITS), cnt)
  end
end)()

--- Build a Kitty graphics protocol escape sequence.
---@param control  table<string, string | number>
---@param payload? string
---@return string
function M.seq(control, payload)
  local parts = { "\027_G" }

  local tmp = {}
  for k, v in pairs(control) do
    table.insert(tmp, k .. "=" .. v)
  end
  if #tmp > 0 then
    table.insert(parts, table.concat(tmp, ","))
  end

  if payload and payload ~= "" then
    table.insert(parts, ";")
    table.insert(parts, payload)
  end

  table.insert(parts, "\027\\")
  return table.concat(parts)
end

--- Transmit image bytes to kitty in base64 chunks using direct transmission.
---@param id   integer kitty image id
---@param data string  raw image bytes
function M.transmit(id, data)
  local chunk_size = 4096
  local base64_data = vim.base64.encode(data)
  local pos = 1
  local len = #base64_data

  while pos <= len do
    local end_pos = math.min(pos + chunk_size - 1, len)
    local chunk = base64_data:sub(pos, end_pos)
    local is_last = end_pos >= len

    local control = {}

    if pos == 1 then
      control.f = "100"  -- PNG format
      control.a = "t"    -- Transmit without displaying
      control.t = "d"    -- Direct transmission
      control.i = id
      control.q = "2"  -- Suppress responses
    end

    control.m = is_last and "0" or "1"

    M.write(M.seq(control, chunk))
    pos = end_pos + 1
  end
end

--- Transmit a local PNG by file path.
---@param img_id integer
---@param file   string
function M.transmit_local_png(img_id, file)
  M.write(M.seq({
      t = "f",
      i = img_id,
      f = 100,
      q = "2",
    }, vim.base64.encode(file)))
end

--- Create an invisible Kitty virtual placement for unicode placeholder mode.
---@param img_id       integer
---@param placement_id integer
---@param width        integer columns
---@param height       integer rows
function M.create_virtual_placement(img_id, placement_id, width, height)
  M.write(M.seq({
      a = "p",
      U = "1",
      i = img_id,
      p = placement_id,
      c = width,
      r = height,
      C = "1",
      q = "2",
    }))
end

--- Delete one virtual placement for an image.
---@param img_id       integer
---@param placement_id integer
function M.delete_placement(img_id, placement_id)
  M.write(M.seq({
      a = "d",
      d = "i",
      i = img_id,
      p = placement_id,
      q = "2",
    }))
end

--- Delete an image allowing the terminal free its data.
---@param img_id integer
function M.delete_image(img_id)
  M.write(M.seq({
      a = "d",
      d = "I",
      i = img_id,
      q = "2",
    }))
end

return M

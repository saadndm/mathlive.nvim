---@class mathlive.image.terminal
local M = {}

---@type mathlive.image.Env[]
local environments = {
  {
    name = "kitty",
    terminal = "kitty",
    supported = true,
  },
  {
    name = "ghostty",
    terminal = "ghostty",
    supported = true,
  },
  {
    name = "wezterm",
    terminal = "wezterm",
    supported = false,
  },
  {
    name = "tmux",
    env = { TERM = "tmux", TMUX = true },
    setup = function()
      pcall(vim.fn.system, { "tmux", "set", "-p", "allow-passthrough", "all" })
    end,
    transform = function(data)
      return ("\027Ptmux;" .. data:gsub("\027", "\027\027")) .. "\027\\"
    end,
  },
  { name = "zellij", env = { TERM = "zellij", ZELLIJ = true },           supported = false },
  { name = "ssh",    env = { SSH_CLIENT = true, SSH_CONNECTION = true }, remote = true },
}

M._env = nil ---@type mathlive.image.Env?

M._terminal = nil ---@type mathlive.image.Terminal?

function M.env()
  if M._env then
    return M._env
  end
  if not M._terminal then
    M.detect()
  end
  M._env = {
    name = "",
    env = {},
  }
  for _, e in ipairs(environments) do
    local override = os.getenv("MATHLIVE_" .. e.name:upper())
    if override then
      e.detected = override ~= "0" and override ~= "false"
    else
      if e.terminal and M._terminal and M._terminal.terminal then
        e.detected = M._terminal.terminal:lower():find(e.terminal:lower()) ~= nil
      end
      if not e.detected then
        for k, v in pairs(e.env or {}) do
          local val = os.getenv(k)
          if val and (v == true or val:find(v)) then
            e.detected = true
            break
          end
        end
      end
    end
    if e.detected then
      M._env.name = M._env.name .. "/" .. e.name
      if e.supported ~= nil then
        M._env.supported = e.supported
      end
      M._env.transform = e.transform or M._env.transform
      M._env.remote = e.remote or M._env.remote
      if e.setup then
        e.setup()
      end
    end
  end
  M._env.name = M._env.name:gsub("^/", "")
  return M._env
end

function M.write(data)
  data = M.transform and M.transform(data) or data
  vim.api.nvim_ui_send(data)
end

--- Detect terminal capabilities
--- Will call the callback when detection is complete,
--- or block until detection is complete if no callback is provided.
---@param cb? fun(term: mathlive.image.Terminal)
function M.detect(cb)
  if cb then -- async
    return M._detect(cb)
  end
  -- sync
  local detected = false
  M.detect(function()
    detected = true
  end)
  vim.wait(1500, function()
    return detected
  end, 10)
end

---@param cb fun(term: mathlive.image.Terminal)
function M._detect(cb)
  if M._terminal then
    if M._terminal.pending then
      table.insert(M._terminal.pending, cb)
      return
    end
    return cb(M._terminal)
  end

  ---@class mathlive.image.Terminal
  ---@field terminal? string
  ---@field version? string
  ---@field supported? boolean
  local ret = {
    terminal = "unknown",
    version = "unknown",
    pending = { cb }, ---@type fun(term: mathlive.image.Terminal)[]
  }
  M._terminal = ret

  local timer = assert(vim.uv.new_timer())

  local function on_done()
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    M._env = nil
    vim.schedule(function()
      local todo = ret.pending or {}
      ret.pending = nil
      for _, c in ipairs(todo) do
        c(ret)
      end
    end)
  end

  if vim.env.TMUX then
    pcall(vim.fn.system, { "tmux", "set", "-p", "allow-passthrough", "all" })
    M.transform = function(data)
      return ("\027Ptmux;" .. data:gsub("\027", "\027\027")) .. "\027\\"
    end
    -- NOTE: When tmux has extended-keys enabled, Neovim's TermResponse autocmd doesn't fire.
    -- Terminal response sequences leak as literal text instead of being captured.
    -- Workaround: Query tmux directly for the terminal name instead of sending escape sequences.
    -- See: https://github.com/folke/snacks.nvim/issues/2332
    local ok, out = pcall(vim.fn.system, { "tmux", "show", "-g", "extended-keys" })
    if ok and vim.trim(out):find(" on$") then
      ok, out = pcall(vim.fn.system, { "tmux", "display-message", "-p", "#{client_termname}" })
      if ok then
        ret.terminal = vim.trim(out):gsub("^xterm%-", "")
        return vim.schedule(on_done)
      end
    end
  end

  local id = vim.api.nvim_create_autocmd("TermResponse", {
    group = vim.api.nvim_create_augroup("mathlive.image.terminal.detect", { clear = true }),
    callback = function(ev)
      local data = ev.data.sequence ---@type string
      local term, version = data:match("P>|(%S+)%s*(.*)")
      if not (term and version) then
        return
      end
      ret.terminal = term
      ret.version = version
      vim.schedule(on_done)
      return true -- delete autocmd
    end,
  })

  timer:start(1000, 0, function()
    vim.schedule(function()
      pcall(vim.api.nvim_del_autocmd, id)
    end)
    on_done()
  end)

  M.write("\27[>q")
end

M.generate_id = (function()
  local bit = require('bit')
  local NVIM_PID_BITS = 10

  local nvim_pid = 0
  local cnt = 30

  ---@return integer
  return function()
    if nvim_pid == 0 then
      local pid = vim.fn.getpid()
      nvim_pid = bit.band(bit.bxor(pid, bit.rshift(pid, 5), bit.rshift(pid, NVIM_PID_BITS)), 0x3FF)
    end
    cnt = cnt + 1
    return bit.bor(bit.lshift(nvim_pid, 24 - NVIM_PID_BITS), cnt)
  end
end)()

---Build a Kitty graphics protocol escape sequence.
---@param control table<string, string|number>
---@param payload? string
---@return string
function M.seq(control, payload)
  local parts = { '\027_G' }

  local tmp = {}
  for k, v in pairs(control) do
    table.insert(tmp, k .. '=' .. v)
  end
  if #tmp > 0 then
    table.insert(parts, table.concat(tmp, ','))
  end

  if payload and payload ~= '' then
    table.insert(parts, ';')
    table.insert(parts, payload)
  end

  table.insert(parts, '\027\\')
  return table.concat(parts)
end

---Transmit image bytes to kitty in base64 chunks using direct transmission.
---@param id integer kitty image id
---@param data string raw image bytes
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
      control.f = '100' -- PNG format
      control.a = 't'   -- Transmit without displaying
      control.t = 'd'   -- Direct transmission
      control.i = id
      control.q = '2'   -- Suppress responses
    end

    control.m = is_last and '0' or '1'

    M.write(M.seq(control, chunk))
    pos = end_pos + 1
  end
end

---Transmit a local PNG by file path.
---@param img_id integer
---@param file string
function M.transmit_local_png(img_id, file)
  M.write(M.seq({
    t = 'f',
    i = img_id,
    f = 100,
    q = '2',
  }, vim.base64.encode(file)))
end

---Create an invisible Kitty virtual placement for unicode placeholder mode.
---@param img_id integer
---@param placement_id integer
---@param width integer columns
---@param height integer rows
function M.create_virtual_placement(img_id, placement_id, width, height)
  M.write(M.seq({
    a = 'p',
    U = '1',
    i = img_id,
    p = placement_id,
    c = width,
    r = height,
    C = '1',
    q = '2',
  }))
end

---Delete one virtual placement for an image.
---@param img_id integer
---@param placement_id integer
function M.delete_placement(img_id, placement_id)
  M.write(M.seq({
    a = 'd',
    d = 'i',
    i = img_id,
    p = placement_id,
    q = '2',
  }))
end

---Delete an image allowing the terminal free its data.
---@param img_id integer
function M.delete_image(img_id)
  M.write(M.seq({
    a = 'd',
    d = 'I',
    i = img_id,
    q = '2',
  }))
end

return M

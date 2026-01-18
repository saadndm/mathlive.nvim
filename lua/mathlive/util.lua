---@class mathlive.util
local M = {}

M.FIXED_CELL_WIDTH = 13
M.FIXED_CELL_HEIGHT = 26

---@generic T
---@param fn T
---@param opts? {ms?:integer}
---@return T
function M.debounce(fn, opts)
  local timer = assert(vim.uv.new_timer())
  local ms = opts and opts.ms or 20
  return function()
    timer:start(ms, 0, vim.schedule_wrap(fn))
  end
end

function M.spinner()
  local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
  return spinner[math.floor(vim.uv.hrtime() / (1e6 * 80)) % #spinner + 1]
end

---@param size mathlive.image.Size
function M.pixels_to_cells(size)
  return M.norm({
    width = size.width / M.FIXED_CELL_WIDTH,
    height = size.height / M.FIXED_CELL_HEIGHT,
  })
end

---@param size {width: number, height: number}
---@return mathlive.image.Size
function M.norm(size)
  return {
    width = math.max(1, math.ceil(size.width)),
    height = math.max(1, math.ceil(size.height)),
  }
end

---@alias mathlive.util.hl table<string, string|vim.api.keyset.highlight>

local hl_groups = {} ---@type table<string, vim.api.keyset.highlight>
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("mathlive_util_hl", { clear = true }),
  callback = function()
    for hl_group, hl in pairs(hl_groups) do
      vim.api.nvim_set_hl(0, hl_group, hl)
    end
  end,
})

--- Ensures the hl groups are always set, even after a colorscheme change.
---@param groups mathlive.util.hl
---@param opts? { prefix?:string, default?:boolean, managed?:boolean }
function M.set_hl(groups, opts)
  opts = opts or {}
  for hl_group, hl in pairs(groups) do
    hl_group = opts.prefix and opts.prefix .. hl_group or hl_group
    hl = type(hl) == "string" and { link = hl } or hl --[[@as vim.api.keyset.highlight]]
    hl.default = opts.default
    if opts.managed ~= false then
      hl_groups[hl_group] = hl
    end
    vim.api.nvim_set_hl(0, hl_group, hl)
  end
end

local dims = {} ---@type table<string, {mtime: uv.fs_stat.result.time, size: mathlive.image.Size}>

--- Get the dimensions of a PNG file
---@param file string
---@return mathlive.image.Size
function M.dim(file)
  file = vim.fs.normalize(file)
  local fs_stat = vim.uv.fs_stat(file)
  if not fs_stat then
    return { height = 0, width = 0 }
  end

  local mtime = fs_stat.mtime
  if dims[file] and vim.deep_equal(dims[file].mtime, mtime) then
    return dims[file].size
  end

  -- extract header with IHDR chunk
  local fd = assert(io.open(file, "rb"), "Failed to open file: " .. file)
  local header = fd:read(24) ---@type string
  fd:close()

  -- Check PNG signature
  assert(header:sub(1, 8) == "\137PNG\r\n\26\n", "Not a valid PNG file: " .. file)

  -- Extract width and height from the IHDR chunk
  local width = header:byte(17) * 16777216 + header:byte(18) * 65536 + header:byte(19) * 256 + header:byte(20)
  local height = header:byte(21) * 16777216 + header:byte(22) * 65536 + header:byte(23) * 256 + header:byte(24)
  dims[file] = { mtime = mtime, size = { width = width, height = height } }
  return dims[file].size
end

function M.hash(formula)
  return vim.fn.sha256(formula):sub(1, 8)
end

---@param buf integer
---@param ns integer
---@param sr integer
---@param sc integer
---@param er? integer
---@param ec? integer
---@return integer?
function M.get_extmark(buf, ns, sr, sc, er, ec)
  er = er or sr
  ec = ec or sc
  local marks = vim.api.nvim_buf_get_extmarks(
    buf, ns,
    { sr, sc }, { er, ec },
    { overlap = true }
  )
  return marks[1] and marks[1][1] or nil
end

---@param buf integer
---@param ns integer
---@param extmark_id integer
---@return Range4?
function M.is_valid_extmark(buf, ns, extmark_id)
  local ok, mark = pcall(vim.api.nvim_buf_get_extmark_by_id, buf, ns, extmark_id, { details = true })
  if not ok or not mark or #mark < 3 then return nil end

  local details = mark[3]
  if not details or details.end_row == nil or details.end_col == nil then return nil end

  local sr = mark[1] --[[@as integer]]
  local sc = mark[2] --[[@as integer]]
  local line_count = vim.api.nvim_buf_line_count(buf)

  if sr >= line_count or details.end_row >= line_count then return nil end
  if sr == details.end_row and sc == details.end_col then return nil end

  return { sr, sc, details.end_row, details.end_col }
end

return M

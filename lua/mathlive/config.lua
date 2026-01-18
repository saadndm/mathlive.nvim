---@class mathlive.config
---@field enabled boolean
---@field filetypes string[]
---@field color_hex string
local M = {
  enabled = true,
  filetypes = { "markdown" },
  color_hex = "",
}

local user_color_hex = nil

---@param name string
local function get_hl_fg(name)
  local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
  if hl and hl.fg then
    return string.format("#%06x", hl.fg)
  end
end

function M.update_color()
  M.color_hex = user_color_hex
      or get_hl_fg("@markup.math.latex")
      or get_hl_fg("Special")
      or get_hl_fg("Normal")
end

function M.setup(opts)
  for k, v in pairs(opts or {}) do
    if type(v) == "table" and type(M[k]) == "table" then
      M[k] = vim.tbl_deep_extend("force", M[k], v)
    else
      M[k] = v
    end
  end

  user_color_hex = opts and opts.color_hex
  M.update_color()

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("mathlive.config", { clear = true }),
    callback = M.update_color,
  })
end

return M

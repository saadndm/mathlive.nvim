---@class mathlive.state
local M = {}

---@class mathlive.state.Preview
---@field buf     integer
---@field extmark integer
---@field path?   string
---@field kind?   mathlive.image.Kind
---@field float?  integer
---@field p?      mathlive.image.Placement

---@class mathlive.state.PlacementEntry
---@field placement?  mathlive.image.Placement
---@field formula     string
---@field formula_raw string
---@field kind?       mathlive.image.Kind
---@field path?       string
---@field hash        string
---@field compiling?  boolean
---@field failed?     boolean

M.preview = nil ---@type mathlive.state.Preview?
M.ns = vim.api.nvim_create_namespace("mathlive")
M.placements = {} ---@type table<integer, table<integer, mathlive.state.PlacementEntry?>?>
M.typst_process = nil ---@type vim.SystemObj?

local cache_path = vim.fn.stdpath("cache") .. "/mathlive/"
if vim.fn.isdirectory(cache_path) == 0 then
  vim.fn.mkdir(cache_path, "p")
end
M.cache_path = cache_path

return M

---@class mathlive.state
---@field preview               mathlive.state.Preview?
---@field ns                    integer
---@field placements            table<integer, table<integer, mathlive.state.PlacementEntry?>?>
---@field multiline_inline_rows table<integer, table<integer, true?>?>
---@field typst_process         vim.SystemObj?
---@field cache_path            string
local M = {}

---@class mathlive.state.Preview
---@field buf     integer
---@field extmark integer
---@field path?   string
---@field kind    mathlive.image.Kind
---@field float?  integer
---@field p?      mathlive.image.Placement

---@class mathlive.state.PlacementEntry
---@field placement?  mathlive.image.Placement
---@field formula     string
---@field formula_raw string
---@field kind        mathlive.image.Kind
---@field path?       string
---@field hash        string
---@field compiling?  boolean
---@field failed?     boolean

M.ns = vim.api.nvim_create_namespace("mathlive")
M.placements = {}
M.multiline_inline_rows = {}

local cache_path = vim.fn.stdpath("cache") .. "/mathlive/"
if vim.fn.isdirectory(cache_path) == 0 then
  vim.fn.mkdir(cache_path, "p")
end
M.cache_path = cache_path

return M

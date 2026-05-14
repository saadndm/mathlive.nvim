---@class mathlive.image
---@field terminal  mathlive.image.terminal
---@field image     mathlive.Image
---@field placement mathlive.image.Placement
---@field util      mathlive.util
local M = {}

---@alias mathlive.image.Size { width: integer, height: integer }
---@alias mathlive.image.Kind "inline_formula" | "displayed_equation" | "preview_inline_formula" | "preview_displayed_equation"
---@alias mathlive.image.ExtmarkSpec { row: integer, col: integer, [string]: any }

return M

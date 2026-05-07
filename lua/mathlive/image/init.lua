---@class mathlive.image
---@field terminal mathlive.image.terminal
---@field image mathlive.Image
---@field placement mathlive.image.Placement
---@field util mathlive.util
local M = {}

---@alias mathlive.image.Size {width: integer, height: integer}
---@alias mathlive.image.Pos {[1]: integer, [2]: integer}
---@alias mathlive.image.Type "inline_formula"|"displayed_equation"|"preview_inline_formula"|"preview_displayed_equation"

---@class mathlive.image.Env
---@field name string
---@field env? table<string, string|true>
---@field terminal? string
---@field supported? boolean default: false
---@field setup? fun(): boolean?
---@field transform? fun(data: string): string
---@field detected? boolean
---@field remote? boolean this is a remote client, so full transfer of the image data is required


---@class mathlive.image.Opts
---@field pos? mathlive.image.Pos (row, col) (1,0)-indexed. defaults to the top-left corner
---@field range? Range4
---@field width? integer
---@field height? integer
---@field type mathlive.image.Type
---@field auto_resize? boolean
---@field extmark? integer

return M

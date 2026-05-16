local State = require("mathlive.state")
local Util = require("mathlive.util")
local Placement = require("mathlive.image.placement")

---@class mathlive.preview
local M = {}

---@param float   integer
---@param preview mathlive.state.Preview
---@param size    mathlive.image.Size
local function position_inline_float(float, preview, size)
  -- Allow nvim to refresh screen position first
  vim.schedule(function ()
    if State.preview ~= preview or not vim.api.nvim_win_is_valid(float) then return end
    vim.api.nvim_win_set_config(float, {
      hide = false,
      relative = 'editor',
      row = vim.fn.screenrow(),
      col = vim.fn.screencol(),
      width = size.width,
      height = size.height
    })
  end)
end

---@param size mathlive.image.Size
function M.create_float(size)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false

  local float = vim.api.nvim_open_win(buf, false, {
    hide = true,
    relative = 'editor',
    row = vim.fn.screenrow(),
    col = vim.fn.screencol(),
    border = "rounded",
    width = size.width,
    height = size.height,
    focusable = false,
    style = "minimal"
  })

  return buf, float
end

---@param buf          integer
---@param extmark      integer
---@param prev_preview mathlive.state.PlacementEntry | mathlive.state.Preview
function M.create(buf, extmark, prev_preview)
  local image_path = prev_preview.path or (State.cache_path .. "temp.png")
  State.preview = { buf = buf, extmark = extmark, path = prev_preview.path or "temp.png" }
  local dim = Util.dim(image_path)
  local size = Util.pixels_to_cells(dim)
  local kind = prev_preview.kind

  if kind == 'inline_formula' then
    local preview_buf, float = M.create_float(size)
    State.preview.float = float
    local p = Placement.new(preview_buf, image_path, 'preview_inline_formula', nil)

    State.preview.p = p
    p:render()
    position_inline_float(float, State.preview, Util.pixels_to_cells(p.img.size))
  else
    local p = Placement.new(buf, image_path, 'preview_displayed_equation', extmark)
    State.preview.p = p
    p:render()
  end
end

function M.update()
  local preview = State.preview
  if not preview then return end

  if preview.path ~= "temp.png" then
    preview.path = "temp.png"
    return
  end

  local p = preview.p
  if not p then return end

  p:replace(State.cache_path .. "temp.png")
  p:render()

  if p.kind == "preview_inline_formula" then
    if preview.float then
      position_inline_float(preview.float, preview, Util.pixels_to_cells(p.img.size))
    end
  end
end

function M.close_preview()
  local preview = State.preview
  if preview then
    if preview.float and vim.api.nvim_win_is_valid(preview.float) then
      vim.api.nvim_win_close(preview.float, true)
    end

    if preview.p then
      preview.p:close()
    end

    State.preview = nil
  end

  if State.typst_process then
    State.typst_process:kill('sigterm')
    State.typst_process = nil
  end
end

M.update_debounced = Util.debounce(M.update, { ms = 10 })

return M

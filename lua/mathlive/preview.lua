local State = require("mathlive.state")
local Util = require("mathlive.util")
local Placement = require("mathlive.image.placement")

---@class mathlive.preview
local M = {}

---@param size mathlive.image.Size
function M.create_float(size)
  local buf = vim.api.nvim_create_buf(false, true)

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

---@param buf integer
---@param extmark integer
---@param prev_preview mathlive.state.PlacementEntry
function M.create(buf, extmark, prev_preview)
  assert(prev_preview.path, "Preview missing path")
  State.preview = { buf = buf, extmark = extmark, path = prev_preview.path }
  local dim = Util.dim(prev_preview.path)
  local size = Util.pixels_to_cells(dim)

  if prev_preview.placement and prev_preview.placement.opts.type == 'inline_formula' then
    local preview_buf, float = M.create_float(size)
    local p = Placement.new(preview_buf, prev_preview.path, {
      type = 'preview_inline_formula',
      on_update = function(self)
        if self._state and State.preview and State.preview.float and vim.api.nvim_win_is_valid(State.preview.float) then
          vim.api.nvim_win_set_config(float, {
            hide = false,
            relative = 'editor',
            row = vim.fn.screenrow(),
            col = vim.fn.screencol(),
            width = self._state.size.width,
            height = self._state.size.height,
          })
        end
      end
    })
    State.preview.p = p
    State.preview.float = float
  else
    -- For displayed equations, use extmark-based positioning
    local p = Placement.new(buf, prev_preview.path, {
      type = 'preview_displayed_equation',
      extmark = extmark,
    })
    State.preview.p = p
  end
end

function M.update()
  local preview = State.preview
  if not preview then return end

  -- Ignore first temp.png update
  if preview.path ~= "temp.png" then
    preview.path = "temp.png"
    return
  end

  local prev_p = preview.p

  if prev_p and prev_p.opts.type == 'preview_inline_formula' then
    local float = preview.float
    if not float or not vim.api.nvim_win_is_valid(float) then return end

    local dim = Util.dim(State.cache_path .. "temp.png")
    local size = Util.pixels_to_cells(dim)

    -- Close old placement FIRST
    prev_p:close()

    vim.api.nvim_win_set_config(float, {
      hide = false,
      width = size.width,
      height = size.height,
    })

    local p = Placement.new(prev_p.buf, State.cache_path .. "temp.png", {
      type = 'preview_inline_formula',
    })
    preview.p = p
  else
    local buf = preview.buf
    local extmark = preview.extmark

    -- Close old placement FIRST
    if prev_p then
      prev_p:close()
    end

    local p = Placement.new(buf, State.cache_path .. "temp.png", {
      type = 'preview_displayed_equation',
      extmark = extmark,
    })
    preview.p = p
  end
end

function M.close_preview()
  if State.preview then
    if State.preview.float and vim.api.nvim_win_is_valid(State.preview.float) then
      vim.api.nvim_win_close(State.preview.float, true)
    end
    if State.preview.p then
      State.preview.p:close()
    end
    State.preview = nil
  end

  if State.typst_process then
    State.typst_process:kill('sigterm')
    State.typst_process = nil
  end
end

return M

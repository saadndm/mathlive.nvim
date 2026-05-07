local State = require("mathlive.state")
local Util = require("mathlive.util")
local Placement = require("mathlive.image.placement")

---@class mathlive.preview
local M = {}

---@param float integer
---@param preview mathlive.state.Preview
---@param size mathlive.image.Size
local function position_inline_float(float, preview, size)
  -- Allow nvim to refresh screen position first
  vim.schedule(function()
    if State.preview ~= preview or not vim.api.nvim_win_is_valid(float) then return end
    vim.api.nvim_win_set_config(float, {
      hide = false,
      relative = 'editor',
      row = vim.fn.screenrow(),
      col = vim.fn.screencol(),
      width = size.width,
      height = size.height,
    })
  end)
end

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
---@param prev_preview mathlive.state.PlacementEntry|mathlive.state.Preview
function M.create(buf, extmark, prev_preview)
  local image_path = prev_preview.path or (State.cache_path .. "temp.png")
  State.preview = { buf = buf, extmark = extmark, path = prev_preview.path or "temp.png" }
  local dim = Util.dim(image_path)
  local size = Util.pixels_to_cells(dim)

  local formula_type = prev_preview.formula_type
  if not formula_type and prev_preview.placement then
    formula_type = prev_preview.placement.opts.type
  end

  if formula_type == 'inline_formula' then
    local preview_buf, float = M.create_float(size)
    State.preview.float = float
    local p = Placement.new(preview_buf, image_path, {
      type = 'preview_inline_formula',
      on_update = function(self)
        if self._state and State.preview and State.preview.float and vim.api.nvim_win_is_valid(State.preview.float) then
          position_inline_float(float, State.preview, self._state.size)
        end
      end
    })
    State.preview.p = p
    p:update()
  else
    local p = Placement.new(buf, image_path, {
      type = 'preview_displayed_equation',
      extmark = extmark,
    })
    State.preview.p = p
    p:update()
  end
end

function M.update()
  local preview = State.preview
  if not preview then return end

  if preview.path ~= "temp.png" then
    preview.path = "temp.png"
    return
  end

  local prev_p = preview.p

  if prev_p and prev_p.opts.type == 'preview_inline_formula' then
    local float = preview.float
    if not float or not vim.api.nvim_win_is_valid(float) then return end

    local closed_prev = false

    local p = Placement.new(prev_p.buf, State.cache_path .. "temp.png", {
      type = 'preview_inline_formula',
      on_update = function(self)
        if State.preview ~= preview then
          self:close()
          return
        end

        if self._state and State.preview and State.preview.float and vim.api.nvim_win_is_valid(State.preview.float) then
          position_inline_float(float, State.preview, self._state.size)
        end

        if not closed_prev then
          closed_prev = true
          preview.p = self
          if prev_p ~= self then
            prev_p:close()
          end
        end
      end,
    })
    p:update()
  else
    local buf = preview.buf
    local extmark = preview.extmark

    local closed_prev = false

    local p = Placement.new(buf, State.cache_path .. "temp.png", {
      type = 'preview_displayed_equation',
      extmark = extmark,
      on_update = function(self)
        if State.preview ~= preview then
          self:close()
          return
        end

        if not closed_prev then
          closed_prev = true
          preview.p = self
          if prev_p and prev_p ~= self then
            prev_p:close()
          end
        end
      end,
    })
    p:update()
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

M.update_debounced = Util.debounce(M.update, { ms = 10 })

return M

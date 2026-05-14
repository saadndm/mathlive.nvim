local Placeholders = require("mathlive.image.placeholders")
local Util = require("mathlive.util")

---@class mathlive.image.renderer
local M = {}

local State = require("mathlive.state")
local Conceal = require("mathlive.conceal")
local Strategies = {}

local function is_previewed(placement)
  local preview = State.preview
  if not preview or not preview.extmark then
    return false
  end
  return placement.extmark and placement.extmark == preview.extmark
end

local function get_win_for_buf(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
  return nil
end

local function cursor_screenpos(win)
  local screenpos = vim.fn.win_screenpos(win)
  if type(screenpos) == "table" and screenpos[1] and screenpos[2] then
    local row = screenpos[1] + vim.fn.winline() - 1
    local col = screenpos[2] + vim.fn.wincol() - 1
    return row, col
  end
  return vim.fn.screenrow(), vim.fn.screencol()
end

local function slice_text(line, start_col, end_col)
  if end_col < start_col then
    return ""
  end
  return line:sub(start_col + 1, end_col)
end

local function filter_visible_placements(placements)
  local visible = {}
  for _, item in ipairs(placements) do
    local p = item.placement
    if not p.hidden and p._grid and not is_previewed(p) then
      visible[#visible + 1] = item
    end
  end
  return visible
end

local function resolve_target_win(buf, target_win)
  if target_win and vim.api.nvim_win_is_valid(target_win) and vim.api.nvim_win_get_buf(target_win) == buf then
    return target_win
  end
  return get_win_for_buf(buf)
end

local function build_virt_lines(visible, positions_by_id, max_height, scroll_padding)
  if max_height <= 1 then
    return nil
  end

  local virt_lines = {}
  for i = 2, max_height do
    local vline = {}
    local base = scroll_padding
    local col = 0
    if scroll_padding > 0 then
      vline[#vline + 1] = { string.rep(" ", scroll_padding) }
      col = scroll_padding
    end
    for _, item in ipairs(visible) do
      local p = item.placement
      local pos = positions_by_id[p.id]
      if p._grid and i <= #p._grid and pos then
        local target_col = base + pos.start_col
        if target_col > col then
          vline[#vline + 1] = { string.rep(" ", target_col - col) }
        end
        vline[#vline + 1] = { p._grid[i], "MathLiveImage" .. p.id }
        col = target_col + pos.width
      end
    end
    virt_lines[#virt_lines + 1] = vline
  end

  return virt_lines
end

local function reposition_preview_if_needed(win)
  if not State.preview or not State.preview.float then return end
  if not vim.api.nvim_win_is_valid(State.preview.float) then return end
  local target_win = win and vim.api.nvim_win_is_valid(win) and win or vim.api.nvim_get_current_win()
  vim.api.nvim_win_call(target_win, function ()
    vim.cmd("redraw")
    local row, col = cursor_screenpos(target_win)
    vim.api.nvim_win_set_config(State.preview.float, {
      relative = "editor",
      row = row,
      col = col
    })
  end)
end

local function compute_layout(state)
  local positions_by_id = {}
  local max_height = 1
  local last_end = 0
  local display_col = 0
  local scroll_padding = 0
  local virt_lines = nil
  local anchor = nil

  local function compute_positions()
    local conceallevel = vim.wo.conceallevel
    local view = vim.fn.winsaveview()
    local leftcol = tonumber(view and view.leftcol) or 0
    local projector = Conceal.build_row_projector(state.buf, state.row, state.line_text, state.visible)

    for _, item in ipairs(state.visible) do
      local p = item.placement
      local range = item.range
      local sc = range[2]
      local ec = range[4]

      if last_end < sc then
        local gap_width = projector:screen_width(last_end, sc)
        display_col = display_col + gap_width
      end

      positions_by_id[p.id] = { start_col = display_col, width = Util.pixels_to_cells(p.img.size).width }

      display_col = display_col + positions_by_id[p.id].width
      if conceallevel == 0 then
        local formula_segment = slice_text(state.line_text, sc, ec)
        display_col = display_col + vim.fn.strdisplaywidth(formula_segment, display_col)
      elseif conceallevel == 1 and ec > sc then
        display_col = display_col + 1
      end
      last_end = ec

      if p._grid then
        max_height = math.max(max_height, #p._grid)
      end
    end

    if conceallevel > 0 and leftcol > 0 then
      scroll_padding = projector:scroll_padding_before(leftcol)
    end
  end

  if state.win then
    vim.api.nvim_win_call(state.win, compute_positions)
  else
    compute_positions()
  end

  virt_lines = build_virt_lines(state.visible, positions_by_id, max_height, scroll_padding)
  anchor = state.visible[1].placement

  return { virt_lines = virt_lines, anchor = anchor }
end

---@param placement mathlive.image.Placement
function M.index_multiline_inline(placement)
  if placement.kind ~= "inline_formula" or not placement._grid or #placement._grid <= 1 then return end

  local range = placement:get_range()
  if not range then return end

  M.unindex_multiline_inline(placement)

  local by_buf = Util.ensure_table(State.multiline_inline_rows, placement.buf)
  local by_row = Util.ensure_table(by_buf, range[1])

  by_row[placement.id] = { placement = placement, range = range }
  placement._multiline_inline_row = range[1]
end

---@param placement mathlive.image.Placement
function M.unindex_multiline_inline(placement)
  local by_buf = State.multiline_inline_rows[placement.buf]
  if not by_buf then return end

  local row = placement._multiline_inline_row
  local by_id = row and by_buf[row]

  if by_id then
    by_id[placement.id] = nil
    if not next(by_id) then
      by_buf[row] = nil
    end
  end

  placement._multiline_inline_row = nil

  if not next(by_buf) then
    State.multiline_inline_rows[placement.buf] = nil
  end
end

---@param buf         integer
---@param row         integer
---@param target_win? integer
---@param row_items?  table<integer, { placement: mathlive.image.Placement, range: Range4 }>
function M.render_multiline_inline_row(buf, row, target_win, row_items)
  row_items = row_items or (State.multiline_inline_rows[buf] and State.multiline_inline_rows[buf][row])
  if not row_items then return end

  local line_text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local placements = {}

  for id, item in pairs(row_items) do
    local p = item.placement
    local range = p:get_range()

    if not range then
      M.unindex_multiline_inline(p)
      row_items[id] = nil
    elseif range[1] == row then
      item.range = range
      placements[#placements + 1] = item
    else
      M.index_multiline_inline(p)
    end
  end

  if #placements == 0 then return end

  table.sort(placements, function (a, b)
    return a.range[2] < b.range[2]
  end)

  local visible = filter_visible_placements(placements)
  local win = resolve_target_win(buf, target_win)
  local layout = nil

  if #visible > 0 then
    layout = compute_layout({
      buf = buf,
      row = row,
      line_text = line_text,
      visible = visible,
      win = win
    })
  end

  local needs_preview_reposition = false

  for _, item in ipairs(placements) do
    local p = item.placement
    local range = item.range
    local previewed = is_previewed(p)
    local should_render = p.hidden or p._grid or previewed
    if should_render then
      local extmark = {
        row = range[1],
        col = range[2],
        end_row = range[3],
        end_col = range[4],
        virt_text_pos = "inline",
        virt_text_hide = true
      }

      if not previewed and p._grid then
        extmark.conceal = ""
        if p._grid[1] then
          extmark.virt_text = { { p._grid[1], "MathLiveImage" .. p.id } }
        end

        if layout and p == layout.anchor and layout.virt_lines then
          extmark.virt_lines = layout.virt_lines
          extmark.virt_lines_overflow = "scroll"
        end
      end

      p:_render({ extmark })
    end
    if State.preview and State.preview.float
      and vim.api.nvim_win_is_valid(State.preview.float) and p.kind == "inline_formula"
      and p.extmark == State.preview.extmark then
      needs_preview_reposition = true
    end
  end

  if needs_preview_reposition then
    vim.defer_fn(function ()
      reposition_preview_if_needed(win)
    end, 0)
  end
end

---@param size mathlive.image.Size
---@return string[]
local function generate_grid(size)
  local img = {} ---@type string[]
  local height = math.min(#Placeholders.diacritics, size.height)
  local width = math.min(#Placeholders.diacritics, size.width)

  for r = 1, height do
    local line = {} ---@type string[]
    for c = 1, width do
      line[#line + 1] = Placeholders.placeholder
      line[#line + 1] = Placeholders.diacritics[r]
      line[#line + 1] = Placeholders.diacritics[c]
    end
    img[#img + 1] = table.concat(line)
  end
  return img
end

---@param placement mathlive.image.Placement
---@param grid      string[]
---@param hl        string
function Strategies.preview_displayed_equation(placement, grid, hl)
  -- Preview mode: show virt_lines below closing $$ (no overlay, no conceal)
  local range = placement:get_range()
  if not range then return end
  local er = range[3]
  local virt_lines = {}
  for i = 1, #grid do
    virt_lines[#virt_lines + 1] = { { grid[i], hl } }
  end
  local extmark = { row = er, col = 0, virt_lines = virt_lines }
  extmark.virt_lines_overflow = "scroll"
  placement:_render({
    extmark
  })
end

---@param placement mathlive.image.Placement
---@param grid      string[]
---@param hl        string
function Strategies.displayed_equation(placement, grid, hl)
  placement._grid = grid

  local range = placement:get_range()
  if not range then return end
  local sr, sc, er, ec = range[1], range[2], range[3], range[4]
  local block_rows = er - sr + 1
  local grid_height = #grid
  local extmarks = {}

  local function line_len(row0)
    local line = vim.api.nvim_buf_get_lines(placement.buf, row0, row0 + 1, false)[1] or ""
    return #line
  end

  for k = 1, block_rows do
    local row0 = sr + (k - 1)
    local conceal_start = (row0 == sr) and sc or 0
    local conceal_end = (row0 == er) and ec or line_len(row0)

    local extmark = { row = row0, col = conceal_start, end_row = row0, end_col = conceal_end }

    if k <= grid_height then
      -- Lines with image content: conceal text and insert image inline so
      -- horizontal scrolling matches normal inline extmarks.
      extmark.conceal = ""
      extmark.virt_text_pos = "inline"
      extmark.virt_text = { { grid[k], hl } }
    else
      -- Extra formula lines beyond image height: hide completely
      extmark.conceal = ""
    end

    extmarks[#extmarks + 1] = extmark
  end

  -- If grid is taller than formula block, add virt_lines to the last extmark
  if grid_height > block_rows and #extmarks > 0 then
    local virt_lines = {}
    for i = block_rows + 1, grid_height do
      virt_lines[#virt_lines + 1] = { { grid[i], hl } }
    end
    extmarks[#extmarks].virt_lines = virt_lines
    extmarks[#extmarks].virt_lines_overflow = "scroll"
  end

  placement:_render(extmarks)
end

---@param placement mathlive.image.Placement
---@param grid      string[]
function Strategies.inline_formula(placement, grid)
  placement._grid = grid
  M.index_multiline_inline(placement)

  local range = placement:get_range()
  if not range then return end

  if #grid > 1 then
    M.render_multiline_inline_row(placement.buf, range[1])
    return
  end

  placement:_render({
    {
      row = range[1],
      col = range[2],
      end_row = range[3],
      end_col = range[4],
      virt_text_pos = "inline",
      virt_text_hide = true,
      conceal = "",
      virt_text = { { grid[1], "MathLiveImage" .. placement.id } }
    }
  })
end

---@param placement mathlive.image.Placement
---@param grid      string[]
---@param hl        string
function Strategies.preview_inline_formula(placement, grid, hl)
  -- Used for floating preview window
  -- Replaces the entire buffer content
  local height = #grid
  vim.bo[placement.buf].modifiable = true
  vim.api.nvim_buf_set_lines(placement.buf, 0, -1, false, grid)
  vim.bo[placement.buf].modifiable = false
  for r = 0, height - 1 do
    vim.hl.range(placement.buf, placement.ns, hl, { r, 0 }, { r, -1 }, {})
  end
end

---@param placement mathlive.image.Placement
---@param size      mathlive.image.Size
---@param hl        string
function M.render(placement, size, hl)
  placement._grid = placement._grid or generate_grid(size)
  Strategies[placement.kind](placement, placement._grid, hl)
end

return M

local Conceal = require("mathlive.conceal")
local Placeholders = require("mathlive.image.placeholders")
local State = require("mathlive.state")
local Util = require("mathlive.util")

---@class mathlive.image.renderer
local M = {}

---@alias mathlive.image.RowPlacement { placement: mathlive.image.Placement, range: Range4 }
---@alias mathlive.image.Position { start_col: integer, width: integer }

---@class mathlive.image.renderer.LayoutState
---@field buf       integer
---@field row       integer
---@field line_text string
---@field visible   mathlive.image.RowPlacement[]
---@field win?      integer

---@class mathlive.image.renderer.Layout
---@field virt_lines? table
---@field anchor?     mathlive.image.Placement

---@param placement mathlive.image.Placement
local function is_suppressed_by_preview(placement)
  local preview = State.preview
  return preview and preview.extmark and placement.extmark and placement.extmark == preview.extmark
end

---@param buf integer
local function get_win_for_buf(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
  return nil
end

---@param line      string
---@param start_col integer
---@param end_col   integer
local function slice_text(line, start_col, end_col)
  if end_col < start_col then
    return ""
  end
  return line:sub(start_col + 1, end_col)
end

---@param placements mathlive.image.RowPlacement[]
local function filter_visible_placements(placements)
  local visible = {} ---@type mathlive.image.RowPlacement[]
  for _, item in ipairs(placements) do
    local p = item.placement
    if not p.hidden and p._grid and not is_suppressed_by_preview(p) then
      visible[#visible + 1] = item
    end
  end
  return visible
end

---@param placements mathlive.image.RowPlacement[]
local function filter_multiline_placements(placements)
  local multiline = {} ---@type mathlive.image.RowPlacement[]
  for _, item in ipairs(placements) do
    local p = item.placement
    if p._grid and #p._grid > 1 then
      multiline[#multiline + 1] = item
    end
  end
  return multiline
end

---@param visible         mathlive.image.RowPlacement[]
---@param positions_by_id table<integer, mathlive.image.Position>
---@param max_height      integer
---@param scroll_padding  integer
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

---@param state mathlive.image.renderer.LayoutState
---@return mathlive.image.renderer.Layout
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
    local leftcol = vim.fn.winsaveview().leftcol
    local projector = nil
    if conceallevel > 0 then
      projector = Conceal.build_row_projector(state.buf, state.row, state.line_text, state.visible)
    end

    for _, item in ipairs(state.visible) do
      local p = item.placement
      local range = item.range
      local sc = range[2]
      local ec = range[4]

      if last_end < sc then
        local gap_width = projector and projector:screen_width(last_end, sc)
          or vim.fn.strdisplaywidth(slice_text(state.line_text, last_end, sc), display_col)
        display_col = display_col + gap_width
      end

      positions_by_id[p.id] = { start_col = display_col, width = Util.pixels_to_cells(p.img.size).width }

      display_col = display_col + positions_by_id[p.id].width
      if conceallevel == 0 then
        local formula_segment = slice_text(state.line_text, sc, ec)
        display_col = display_col + vim.fn.strdisplaywidth(formula_segment, display_col)
      elseif p._grid and #p._grid > 1 and conceallevel == 1 and ec > sc then
        display_col = display_col + 1
      end
      last_end = ec

      if p._grid then
        max_height = math.max(max_height, #p._grid)
      end
    end

    if projector and leftcol > 0 then
      scroll_padding = projector:scroll_padding_before(leftcol)
    end
  end

  if state.win then
    vim.api.nvim_win_call(state.win, compute_positions)
  else
    compute_positions()
  end

  virt_lines = build_virt_lines(state.visible, positions_by_id, max_height, scroll_padding)
  for _, item in ipairs(state.visible) do
    if item.placement._grid and #item.placement._grid > 1 then
      anchor = item.placement
      break
    end
  end

  return { virt_lines = virt_lines, anchor = anchor }
end

---@param placement mathlive.image.Placement
---@param range?    Range4
function M.index_multiline_inline(placement, range)
  if placement.kind ~= "inline_formula" or not placement._grid or #placement._grid <= 1 then return end

  range = range or placement:get_range()
  if not range then return end

  M.unindex_multiline_inline(placement)

  local by_buf = Util.ensure_table(State.multiline_inline_rows, placement.buf)
  by_buf[range[1]] = true
  placement._multiline_inline_row = range[1]
end

---@param buf               integer
---@param row               integer
---@param ignored_placement mathlive.image.Placement
local function row_has_multiline_inline(buf, row, ignored_placement)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, State.ns, { row, 0 }, { row, -1 }, { details = false })) do
    local entry = State.placements[buf] and State.placements[buf][mark[1]]
    local p = entry and entry.placement
    if p and p ~= ignored_placement and p.kind == "inline_formula" and p._grid and #p._grid > 1 then
      return true
    end
  end

  return false
end

---@param placement mathlive.image.Placement
function M.unindex_multiline_inline(placement)
  local by_buf = State.multiline_inline_rows[placement.buf]
  if not by_buf then return end

  local row = placement._multiline_inline_row
  if row and not row_has_multiline_inline(placement.buf, row, placement) then
    by_buf[row] = nil
  end

  placement._multiline_inline_row = nil

  if not next(by_buf) then
    State.multiline_inline_rows[placement.buf] = nil
  end
end

---@param buf integer
---@param row integer
local function collect_row_placements(buf, row)
  local placements = {} ---@type mathlive.image.RowPlacement[]

  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, State.ns, { row, 0 }, { row, -1 }, { details = false })) do
    local entry = State.placements[buf] and State.placements[buf][mark[1]]
    local p = entry and entry.placement

    if p and p.kind == "inline_formula" and p._grid then
      local range = p:get_range()

      if not range then
        p:hide()
        M.unindex_multiline_inline(p)
      elseif range[1] == row then
        placements[#placements + 1] = { placement = p, range = range }
      else
        M.index_multiline_inline(p, range)
      end
    end
  end

  table.sort(placements, function (a, b)
    return a.range[2] < b.range[2]
  end)

  return placements
end

---@param buf         integer
---@param row         integer
---@param target_win? integer
function M.render_multiline_inline_row(buf, row, target_win)
  if not (State.multiline_inline_rows[buf] and State.multiline_inline_rows[buf][row]) then return end

  local line_text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local placements = collect_row_placements(buf, row)
  local multiline = filter_multiline_placements(placements)
  if #multiline == 0 then return end

  local visible = filter_visible_placements(placements)
  local win = target_win or get_win_for_buf(buf)
  local layout = compute_layout({
    buf = buf,
    row = row,
    line_text = line_text,
    visible = visible,
    win = win
  })

  for _, item in ipairs(multiline) do
    local p = item.placement
    local range = item.range
    local suppressed = is_suppressed_by_preview(p)
    local needs_extmark = p.hidden or p._grid or suppressed
    if needs_extmark then
      local extmark = {
        row = range[1],
        col = range[2],
        end_row = range[3],
        end_col = range[4],
        virt_text_pos = "inline",
        virt_text_hide = true
      }

      if not suppressed and p._grid then
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
  end
end

---@param placement mathlive.image.Placement
---@param grid      string[]
---@param hl        string
local function render_preview_displayed_equation(placement, grid, hl)
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
local function render_displayed_equation(placement, grid, hl)
  placement._grid = grid

  local range = placement:get_range()
  if not range then return end
  local sr, sc, er, ec = range[1], range[2], range[3], range[4]
  local block_rows = er - sr + 1
  local grid_height = #grid
  local extmarks = {}

  ---@param row0 integer
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
local function render_inline_formula(placement, grid)
  placement._grid = grid
  local range = placement:get_range()
  if not range then return end

  if #grid > 1 then
    M.index_multiline_inline(placement, range)
    M.render_multiline_inline_row(placement.buf, range[1])
    return
  end

  M.unindex_multiline_inline(placement)

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

-- Used for floating window replacing entire buffer content.
---@param placement mathlive.image.Placement
---@param grid      string[]
---@param hl        string
local function render_preview_inline_formula(placement, grid, hl)
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
  placement._grid = placement._grid or Placeholders.grid(size)

  if placement.kind == "inline_formula" then
    render_inline_formula(placement, placement._grid)
  elseif placement.kind == "displayed_equation" then
    render_displayed_equation(placement, placement._grid, hl)
  elseif placement.kind == "preview_inline_formula" then
    render_preview_inline_formula(placement, placement._grid, hl)
  elseif placement.kind == "preview_displayed_equation" then
    render_preview_displayed_equation(placement, placement._grid, hl)
  end
end

return M

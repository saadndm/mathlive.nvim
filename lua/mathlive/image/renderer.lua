---@class mathlive.image.renderer
local M = {}

local State = require("mathlive.state")
local Conceal = require("mathlive.conceal")
local supports_scroll = vim.fn.has("nvim-0.11") == 1
local PLACEHOLDER = vim.fn.nr2char(0x10EEEE)
local diacritics = vim.split(
  "0305,030D,030E,0310,0312,033D,033E,033F,0346,034A,034B,034C,0350,0351,0352,0357,035B,0363,0364,0365,0366,0367,0368,0369,036A,036B,036C,036D,036E,036F,0483,0484,0485,0486,0487,0592,0593,0594,0595,0597,0598,0599,059C,059D,059E,059F,05A0,05A1,05A8,05A9,05AB,05AC,05AF,05C4,0610,0611,0612,0613,0614,0615,0616,0617,0657,0658,0659,065A,065B,065D,065E,06D6,06D7,06D8,06D9,06DA,06DB,06DC,06DF,06E0,06E1,06E2,06E4,06E7,06E8,06EB,06EC,0730,0732,0733,0735,0736,073A,073D,073F,0740,0741,0743,0745,0747,0749,074A,07EB,07EC,07ED,07EE,07EF,07F0,07F1,07F3,0816,0817,0818,0819,081B,081C,081D,081E,081F,0820,0821,0822,0823,0825,0826,0827,0829,082A,082B,082C,082D,0951,0953,0954,0F82,0F83,0F86,0F87,135D,135E,135F,17DD,193A,1A17,1A75,1A76,1A77,1A78,1A79,1A7A,1A7B,1A7C,1B6B,1B6D,1B6E,1B6F,1B70,1B71,1B72,1B73,1CD0,1CD1,1CD2,1CDA,1CDB,1CE0,1DC0,1DC1,1DC3,1DC4,1DC5,1DC6,1DC7,1DC8,1DC9,1DCB,1DCC,1DD1,1DD2,1DD3,1DD4,1DD5,1DD6,1DD7,1DD8,1DD9,1DDA,1DDB,1DDC,1DDD,1DDE,1DDF,1DE0,1DE1,1DE2,1DE3,1DE4,1DE5,1DE6,1DFE,20D0,20D1,20D4,20D5,20D6,20D7,20DB,20DC,20E1,20E7,20E9,20F0,2CEF,2CF0,2CF1,2DE0,2DE1,2DE2,2DE3,2DE4,2DE5,2DE6,2DE7,2DE8,2DE9,2DEA,2DEB,2DEC,2DED,2DEE,2DEF,2DF0,2DF1,2DF2,2DF3,2DF4,2DF5,2DF6,2DF7,2DF8,2DF9,2DFA,2DFB,2DFC,2DFD,2DFE,2DFF,A66F,A67C,A67D,A6F0,A6F1,A8E0,A8E1,A8E2,A8E3,A8E4,A8E5,A8E6,A8E7,A8E8,A8E9,A8EA,A8EB,A8EC,A8ED,A8EE,A8EF,A8F0,A8F1,AAB0,AAB2,AAB3,AAB7,AAB8,AABE,AABF,AAC1,FE20,FE21,FE22,FE23,FE24,FE25,FE26,10A0F,10A38,1D185,1D186,1D187,1D188,1D189,1D1AA,1D1AB,1D1AC,1D1AD,1D242,1D243,1D244",
  ",")
local Strategies = {}

local function is_previewed(placement)
  local preview = State.preview
  if not preview or not preview.extmark then
    return false
  end
  return placement.opts and placement.opts.extmark == preview.extmark
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

local function collect_inline_placements(row, entries)
  local placements = {}

  for extmark_id, entry in pairs(entries or {}) do
    local p = entry.placement
    if p and p.opts.type == "inline_formula" then
      local range = p:get_range()
      if not range then
        p:close()
        entries[extmark_id] = nil
      elseif range[1] == row and p:valid() then
        placements[#placements + 1] = { placement = p, range = range }
      end
    end
  end

  table.sort(placements, function(a, b)
    return a.range[2] < b.range[2]
  end)

  return placements
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
  if target_win
      and vim.api.nvim_win_is_valid(target_win)
      and vim.api.nvim_win_get_buf(target_win) == buf
  then
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
  vim.api.nvim_win_call(target_win, function()
    vim.cmd("redraw")
    local row, col = cursor_screenpos(target_win)
    vim.api.nvim_win_set_config(State.preview.float, {
      relative = "editor",
      row = row,
      col = col,
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
    local projector = Conceal.build_row_projector(
      state.buf,
      state.row,
      state.line_text,
      state.visible
    )

    for _, item in ipairs(state.visible) do
      local p = item.placement
      local range = item.range
      local sc = range[2]
      local ec = range[4]

      if last_end < sc then
        local gap_width = projector:screen_width(last_end, sc)
        display_col = display_col + gap_width
      end

      positions_by_id[p.id] = {
        start_col = display_col,
        width = p._size and p._size.width or 1,
      }

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

    if supports_scroll and conceallevel > 0 and leftcol > 0 then
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

  return {
    virt_lines = virt_lines,
    anchor = anchor,
  }
end


---@param buf integer
---@param row integer
---@param target_win? integer
function M.render_inline_row(buf, row, target_win)
  local entries = State.placements[buf]
  if not entries then return end

  local line_text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local placements = collect_inline_placements(row, entries)
  if #placements == 0 then
    return
  end

  local visible = filter_visible_placements(placements)
  local win = resolve_target_win(buf, target_win)
  local layout = nil

  if #visible > 0 then
    layout = compute_layout({
      buf = buf,
      row = row,
      line_text = line_text,
      visible = visible,
      win = win,
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
        virt_text_hide = true,
      }

      if not previewed and p._grid then
        extmark.conceal = ""
        if p._grid[1] then
          extmark.virt_text = { { p._grid[1], "MathLiveImage" .. p.id } }
        end

        if layout and p == layout.anchor and layout.virt_lines then
          extmark.virt_lines = layout.virt_lines
          if supports_scroll then
            extmark.virt_lines_overflow = "scroll"
          end
        end
      end

      p:_render({ extmark })
    end
    if State.preview
        and State.preview.float
        and vim.api.nvim_win_is_valid(State.preview.float)
        and p.opts.type == "inline_formula"
        and p.opts.extmark == State.preview.extmark
    then
      needs_preview_reposition = true
    end
  end

  if needs_preview_reposition then
    vim.defer_fn(function()
      reposition_preview_if_needed(win)
    end, 0)
  end
end

---@type table<integer, string>
local positions = {}
setmetatable(positions, {
  __index = function(_, k)
    positions[k] = vim.fn.nr2char((tonumber(diacritics[k] or "", 16) or 0))
    return positions[k]
  end,
})

---@param size mathlive.image.Size
---@return string[]
local function generate_grid(size)
  local img = {} ---@type string[]
  local height = math.min(#diacritics, size.height)
  local width = math.min(#diacritics, size.width)

  for r = 1, height do
    local line = {} ---@type string[]
    for c = 1, width do
      line[#line + 1] = PLACEHOLDER
      line[#line + 1] = positions[r]
      line[#line + 1] = positions[c]
    end
    img[#img + 1] = table.concat(line)
  end
  return img
end

---@param placement mathlive.image.Placement
---@param grid string[]
---@param hl string
function Strategies.preview_displayed_equation(placement, grid, hl)
  -- Preview mode: show virt_lines below closing $$ (no overlay, no conceal)
  local range = placement:get_range()
  if not range then return end
  local er = range[3]
  local virt_lines = {}
  for i = 1, #grid do
    virt_lines[#virt_lines + 1] = { { grid[i], hl } }
  end
  local extmark = {
    row = er,
    col = 0,
    virt_lines = virt_lines,
  }
  if supports_scroll then
    extmark.virt_lines_overflow = "scroll"
  end
  placement:_render({
    extmark
  })
end

---@param placement mathlive.image.Placement
---@param grid string[]
---@param hl string
---@param size mathlive.image.Size
function Strategies.displayed_equation(placement, grid, hl, size)
  placement._grid = grid
  placement._size = size

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

    local extmark = {
      row = row0,
      col = conceal_start,
      end_row = row0,
      end_col = conceal_end,
    }

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
    if supports_scroll then
      extmarks[#extmarks].virt_lines_overflow = "scroll"
    end
  end

  placement:_render(extmarks)
end

---@param placement mathlive.image.Placement
---@param grid string[]
---@param hl string
function Strategies.inline_formula(placement, grid, hl, size)
  placement._grid = grid
  placement._size = size

  local range = placement:get_range()
  if not range then return end

  M.render_inline_row(placement.buf, range[1])
end

---@param placement mathlive.image.Placement
---@param grid string[]
---@param hl string
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
---@param size mathlive.image.Size
---@param hl string
function M.render(placement, size, hl)
  local grid = generate_grid(size)
  local formula_type = placement.opts.type

  if formula_type and Strategies[formula_type] then
    Strategies[formula_type](placement, grid, hl, size)
  end
end

---@param placement mathlive.image.Placement
---@param state mathlive.image.State
function M.render_fallback(placement, state)
  print("Error: Rendering fallback")
end

return M

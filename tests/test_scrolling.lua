local MiniTest = require("mini.test")
local helpers = dofile("tests/helpers.lua")
local child = helpers.new_child_neovim()
local mock_child = helpers.new_child_neovim()
local expect, eq = helpers.expect, helpers.expect.equality
local new_set = MiniTest.new_set
local SAMPLE_LINES = {
  "prefix $1 + 2$ suffix", "left $sum_(n=0)^3 n$ middle $1/(1-x)$ right", "$display(sum_(n=0)^infinity) 1/2 (1/2)^n$",
  "$vec(1, 2, 3, 4, 5)$", "$$", "vec(1,2,3,4,5)", "$$"
}

local function set_window_options(target)
  target.set_size(12, 30)
  target.bo.filetype = "markdown"
  target.o.concealcursor = "nvic"
  target.wo.wrap = false
  target.o.laststatus = 0
  target.o.ruler = false
end

local function set_conceallevel(conceallevel)
  child.o.conceallevel = conceallevel
  child.wo.conceallevel = conceallevel
  mock_child.o.conceallevel = conceallevel
  mock_child.wo.conceallevel = conceallevel
end

local function display_width(text)
  return vim.fn.strdisplaywidth(text)
end

local function pad_cells(width, fill)
  return string.rep(fill or " ", math.max(width, 0))
end

local function drop_first_cell(text)
  local chars = vim.fn.strchars(text)
  local width = 0

  for i = 0, chars - 1 do
    local ch = vim.fn.strcharpart(text, i, 1)
    width = width + vim.fn.strdisplaywidth(ch)
    if width >= 1 then
      return vim.fn.strcharpart(text, i + 1)
    end
  end

  return ""
end

local function slice_text(line, start_col, end_col)
  if end_col <= start_col then return "" end
  return line:sub(start_col + 1, end_col)
end

local function append_block(model, block)
  local base = #model.lines

  for _, line in ipairs(block.lines) do
    model.lines[#model.lines + 1] = line
  end

  for _, mark in ipairs(block.extmarks) do
    model.extmarks[#model.extmarks + 1] = {
      row = base + mark.row - 1,
      col = mark.col,
      end_col = mark.end_col,
      text = mark.text
    }
  end
end

local function split_row_placements(placements)
  local displayed = nil
  local inline = {}

  for _, placement in ipairs(placements) do
    if placement.kind == "displayed_equation" and not displayed then
      displayed = placement
    elseif placement.kind == "inline_formula" then
      inline[#inline + 1] = placement
    end
  end

  return displayed, inline
end

local function row_count(placements)
  local count = 1

  for _, placement in ipairs(placements) do
    count = math.max(count, placement.height)
  end

  return count
end

local function display_line(lines, row, placement, line_index, conceallevel)
  local sc, ec = placement.range[2], placement.range[4]
  local line = lines[line_index + 1]

  if line then return line end

  local anchor_line = lines[row + 1] or ""
  local prefix = pad_cells(display_width(slice_text(anchor_line, 0, sc)))
  local formula = slice_text(anchor_line, sc, ec)
  local body = (conceallevel == 0 and line_index > row) and pad_cells(display_width(formula)) or formula
  return prefix .. body
end

local function collect_placements(target)
  return target.lua_get(
    [[
    (function()
      local State = require("mathlive.state")
      local Util = require("mathlive.util")
      local buf = vim.api.nvim_get_current_buf()
      local placements = {}

      if not State.placements[buf] then return {} end

      for _, entry in pairs(State.placements[buf]) do
        local placement = entry.placement
        if placement then
          local range = placement:get_range()
          if range then
            local size = Util.pixels_to_cells(placement.img.size)
            placements[#placements + 1] = {
              id = placement.id,
              kind = placement.kind,
              range = range,
              width = size.width,
              height = size.height,
              grid = vim.deepcopy(placement._grid or {}),
            }
          end
        end
      end

      table.sort(placements, function(a, b)
        if a.range[1] ~= b.range[1] then return a.range[1] < b.range[1] end
        if a.range[2] ~= b.range[2] then return a.range[2] < b.range[2] end
        return a.id < b.id
      end)

      return placements
    end)()
  ]]
  )
end

local function render_inline_block(lines, row, placements, conceallevel)
  local source_line = lines[row + 1] or ""
  local height = row_count(placements)

  local block = { lines = {}, extmarks = {} }

  for k = 1, height do
    local parts = {}
    local col = 0
    local cursor = 0

    for _, placement in ipairs(placements) do
      local sc, ec = placement.range[2], placement.range[4]
      local gap = slice_text(source_line, cursor, sc)
      local gap_width = display_width(gap)
      local visible_gap = (k == 1) and gap or pad_cells(gap_width)
      parts[#parts + 1] = visible_gap
      col = col + #visible_gap

      local formula = slice_text(source_line, sc, ec)
      local formula_width = display_width(formula)
      local visible_formula
      if conceallevel == 0 and k > 1 then
        visible_formula = pad_cells(formula_width)
      elseif conceallevel == 1 and k > 1 then
        visible_formula = " " .. drop_first_cell(formula)
      else
        visible_formula = formula
      end
      parts[#parts + 1] = visible_formula

      block.extmarks[#block.extmarks + 1] = {
        row = k,
        col = col,
        end_col = col + #visible_formula,
        text = placement.grid[k] or pad_cells(placement.width)
      }

      col = col + #visible_formula
      cursor = ec
    end

    local tail = slice_text(source_line, cursor, #source_line)
    local tail_width = display_width(tail)
    parts[#parts + 1] = (k == 1) and tail or pad_cells(tail_width)
    block.lines[k] = table.concat(parts)
  end

  return block
end

local function render_display_block(lines, row, placement, conceallevel)
  local sr, sc, er, ec = unpack(placement.range)
  local block = { lines = {}, extmarks = {} }

  for k = 1, math.max(er - sr + 1, placement.height) do
    local source_index = sr + k - 1
    local line = display_line(lines, row, placement, source_index, conceallevel)

    block.lines[k] = line
    local line_len = #line

    block.extmarks[#block.extmarks + 1] = {
      row = k,
      col = (source_index == sr) and sc or 0,
      end_col = (source_index <= er) and ((source_index == er) and ec or line_len) or line_len,
      text = placement.grid[k] or pad_cells(placement.width)
    }
  end

  return block
end

local function build_mock_model(source_lines, placements, conceallevel)
  local by_start_row = {}
  for _, placement in ipairs(placements) do
    local row = placement.range[1]
    by_start_row[row] = by_start_row[row] or {}
    by_start_row[row][#by_start_row[row] + 1] = placement
  end

  for _, row_placements in pairs(by_start_row) do
    table.sort(row_placements, function (a, b)
      if a.range[2] ~= b.range[2] then return a.range[2] < b.range[2] end
      return a.id < b.id
    end)
  end

  local model = { lines = {}, extmarks = {} }
  local row = 0

  while row < #source_lines do
    local row_placements = by_start_row[row] or {}
    local displayed, inline = split_row_placements(row_placements)

    if displayed then
      append_block(model, render_display_block(source_lines, row, displayed, conceallevel))
      row = displayed.range[3] + 1
    elseif #inline > 0 then
      append_block(model, render_inline_block(source_lines, row, inline, conceallevel))
      row = row + 1
    else
      model.lines[#model.lines + 1] = source_lines[row + 1]
      row = row + 1
    end
  end

  return model
end

local function mock_row_width(line, row, extmarks, conceallevel)
  local width = display_width(line)

  for _, mark in ipairs(extmarks) do
    if mark.row == row then
      local concealed = math.max(0, mark.end_col - mark.col)
      local replacement = display_width(mark.text)
      if conceallevel == 0 then
        width = width + replacement
      else
        width = width - concealed + replacement
      end
    end
  end

  return width
end

local function trail_width(model, conceallevel, win_width)
  local max_width = 0

  for row, line in ipairs(model.lines) do
    max_width = math.max(max_width, mock_row_width(line, row - 1, model.extmarks, conceallevel))
  end

  return max_width + win_width + 1
end

local function apply_mock(target, model)
  target.set_lines(model.lines)
  target.lua(
    [[
    local marks = ...
    local buf = vim.api.nvim_get_current_buf()
    local ns = vim.api.nvim_create_namespace("test")

    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

    for _, mark in ipairs(marks) do
      vim.api.nvim_buf_set_extmark(buf, ns, mark.row, mark.col, {
        end_row = mark.row,
        end_col = mark.end_col,
        conceal = "",
        virt_text_pos = "inline",
        virt_text_hide = true,
        virt_text = { { mark.text } },
        undo_restore = false,
        strict = false,
      })
    end
  ]], { model.extmarks }
  )
end

local function screenshot_text(target)
  return helpers.normalize_screenshot(target.get_screenshot()).text
end

local T = new_set({
  parametrize = { { 0 }, { 1 }, { 2 }, { 3 } },
  hooks = {
    pre_case = function ()
      child.setup()
      mock_child.setup()

      child.lua(
        [[
        require("mathlive.image.terminal").supported = true
        require("mathlive").setup()
      ]]
      )

      set_window_options(child)
      set_window_options(mock_child)
    end,
    post_once = function ()
      child.stop()
      mock_child.stop()
    end
  }
})

T["scrolling"] = function (conceallevel)
  set_conceallevel(conceallevel)
  child.set_lines(SAMPLE_LINES)

  child.lua([[vim.wait(500)]])

  local placements = collect_placements(child)
  local base_model = build_mock_model(SAMPLE_LINES, placements, conceallevel)
  local source_lines = vim.deepcopy(SAMPLE_LINES)
  source_lines[#source_lines + 1] = string.rep(" ", trail_width(base_model, conceallevel, child.o.columns))

  child.set_lines(source_lines)
  child.set_cursor(#source_lines, 0)
  child.lua([[vim.wait(500)]])

  placements = collect_placements(child)
  local model = build_mock_model(source_lines, placements, conceallevel)

  apply_mock(mock_child, model)
  mock_child.set_cursor(#model.lines, 0)

  eq(screenshot_text(child), screenshot_text(mock_child))

  while true do
    local prev_leftcol = child.lua_get([[(vim.fn.winsaveview().leftcol)]])
    child.lua([[vim.cmd("normal! zl")]])
    mock_child.lua([[vim.cmd("normal! zl")]])

    local leftcol = child.lua_get([[(vim.fn.winsaveview().leftcol)]])
    if leftcol == prev_leftcol then
      break
    end

    eq(screenshot_text(child), screenshot_text(mock_child))
  end
end

return T

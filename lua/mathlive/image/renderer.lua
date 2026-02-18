---@class mathlive.image.renderer
local M = {}

local PLACEHOLDER = vim.fn.nr2char(0x10EEEE)
local diacritics = vim.split(
  "0305,030D,030E,0310,0312,033D,033E,033F,0346,034A,034B,034C,0350,0351,0352,0357,035B,0363,0364,0365,0366,0367,0368,0369,036A,036B,036C,036D,036E,036F,0483,0484,0485,0486,0487,0592,0593,0594,0595,0597,0598,0599,059C,059D,059E,059F,05A0,05A1,05A8,05A9,05AB,05AC,05AF,05C4,0610,0611,0612,0613,0614,0615,0616,0617,0657,0658,0659,065A,065B,065D,065E,06D6,06D7,06D8,06D9,06DA,06DB,06DC,06DF,06E0,06E1,06E2,06E4,06E7,06E8,06EB,06EC,0730,0732,0733,0735,0736,073A,073D,073F,0740,0741,0743,0745,0747,0749,074A,07EB,07EC,07ED,07EE,07EF,07F0,07F1,07F3,0816,0817,0818,0819,081B,081C,081D,081E,081F,0820,0821,0822,0823,0825,0826,0827,0829,082A,082B,082C,082D,0951,0953,0954,0F82,0F83,0F86,0F87,135D,135E,135F,17DD,193A,1A17,1A75,1A76,1A77,1A78,1A79,1A7A,1A7B,1A7C,1B6B,1B6D,1B6E,1B6F,1B70,1B71,1B72,1B73,1CD0,1CD1,1CD2,1CDA,1CDB,1CE0,1DC0,1DC1,1DC3,1DC4,1DC5,1DC6,1DC7,1DC8,1DC9,1DCB,1DCC,1DD1,1DD2,1DD3,1DD4,1DD5,1DD6,1DD7,1DD8,1DD9,1DDA,1DDB,1DDC,1DDD,1DDE,1DDF,1DE0,1DE1,1DE2,1DE3,1DE4,1DE5,1DE6,1DFE,20D0,20D1,20D4,20D5,20D6,20D7,20DB,20DC,20E1,20E7,20E9,20F0,2CEF,2CF0,2CF1,2DE0,2DE1,2DE2,2DE3,2DE4,2DE5,2DE6,2DE7,2DE8,2DE9,2DEA,2DEB,2DEC,2DED,2DEE,2DEF,2DF0,2DF1,2DF2,2DF3,2DF4,2DF5,2DF6,2DF7,2DF8,2DF9,2DFA,2DFB,2DFC,2DFD,2DFE,2DFF,A66F,A67C,A67D,A6F0,A6F1,A8E0,A8E1,A8E2,A8E3,A8E4,A8E5,A8E6,A8E7,A8E8,A8E9,A8EA,A8EB,A8EC,A8ED,A8EE,A8EF,A8F0,A8F1,AAB0,AAB2,AAB3,AAB7,AAB8,AABE,AABF,AAC1,FE20,FE21,FE22,FE23,FE24,FE25,FE26,10A0F,10A38,1D185,1D186,1D187,1D188,1D189,1D1AA,1D1AB,1D1AC,1D1AD,1D242,1D243,1D244",
  ",")
local Strategies = {}

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
  placement:_render({
    {
      row = er,
      col = 0,
      virt_lines = virt_lines,
    }
  })
end

---@param placement mathlive.image.Placement
---@param grid string[]
---@param hl string
function Strategies.displayed_equation(placement, grid, hl)
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
      virt_text_hide = true,
    }

    if k <= grid_height then
      -- Lines with image content: conceal text and overlay image
      extmark.conceal = ""
      extmark.virt_text_pos = "overlay"
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
  end

  placement:_render(extmarks)
end

---@param placement mathlive.image.Placement
---@param grid string[]
---@param hl string
function Strategies.inline_formula(placement, grid, hl)
  local range = placement:get_range()
  if not range then return end
  local extmark = {
    row = range[1],
    col = range[2],
    end_row = range[3],
    end_col = range[4],
    conceal = "",
    virt_text_pos = "inline",
    virt_text = { { grid[1], hl } },
    virt_text_hide = true,
  }

  -- For multi-row grids (tall inline formulas), add additional rows as virt_lines
  if #grid > 1 then
    local padding = string.rep(" ", range[2])
    local virt_lines = {}
    for i = 2, #grid do
      table.insert(virt_lines, { { padding }, { grid[i], hl } })
    end
    extmark.virt_lines = virt_lines
  end

  placement:_render({ extmark })
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
    Strategies[formula_type](placement, grid, hl)
  end
end

---@param placement mathlive.image.Placement
---@param state mathlive.image.State
function M.render_fallback(placement, state)
  print("Error: Rendering fallback")
end

return M

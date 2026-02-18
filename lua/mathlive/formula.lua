local Placement = require("mathlive.image.placement")
local State = require("mathlive.state")
local Typst = require("mathlive.typst")
local Util = require("mathlive.util")

---@class mathlive.manager
local M = {}

---@param buf integer
---@param extmark integer
function M.extract_formula(buf, extmark)
  local range = Util.is_valid_extmark(buf, State.ns, extmark)
  if not range then return nil, nil end

  local ok, lines = pcall(vim.api.nvim_buf_get_text, buf, range[1], range[2], range[3], range[4], {})
  if not ok or not lines then return nil, nil end

  ---@cast lines string[]
  return Typst.clean_formula(table.concat(lines, "\n"))
end

---@param buf integer
---@param extmark integer
---@param formula string
---@param formula_raw string
---@param formula_type mathlive.image.Type
---@param hash string
local function compile_and_place(buf, extmark, formula, formula_raw, formula_type, hash)
  State.placements[buf] = State.placements[buf] or {}
  local placements = State.placements[buf]
  if not placements then return end

  placements[extmark] = {
    placement = nil,
    formula = formula,
    formula_raw = formula_raw,
    hash = hash,
    compiling = true,
    failed = false,
  }

  Typst.compile(formula, hash, function(obj, output_path)
    local placement = State.placements[buf] and State.placements[buf][extmark]
    if not placement or placement.hash ~= hash then return end

    if obj.code == 0 then
      local p = Placement.new(buf, output_path, {
        extmark = extmark,
        type = formula_type
      })
      State.placements[buf][extmark] = {
        placement = p,
        formula = formula,
        formula_raw = formula_raw,
        path = output_path,
        hash = hash,
        failed = false,
      }
    else
      placement.compiling = false
      placement.failed = true
    end
  end)
end

---@param buf integer
---@param range Range4
---@param formula string
---@param formula_raw string
---@param formula_type mathlive.image.Type
function M.upsert_formula(buf, range, formula, formula_raw, formula_type)
  local sr, sc, er, ec = range[1], range[2], range[3], range[4]
  local existing_extmark = Util.get_extmark(buf, State.ns, sr, sc, er, ec)
  State.placements[buf] = State.placements[buf] or {}
  local placements = State.placements[buf]
  if not placements then return end

  if existing_extmark then
    local existing = placements[existing_extmark]
    if existing and existing.placement then
      existing.placement:close()
    end
    placements[existing_extmark] = nil
  end

  local extmark = vim.api.nvim_buf_set_extmark(buf, State.ns, range[1], range[2], {
    id = existing_extmark,
    end_row = range[3],
    end_col = range[4],
    right_gravity = true,
    end_right_gravity = false,
  })

  compile_and_place(buf, extmark, formula, formula_raw, formula_type, Util.hash(formula))
end

---@param buf integer
function M.cleanup_buffer(buf)
  if not State.placements[buf] then return end

  for extmark_id, data in pairs(State.placements[buf]) do
    if data.placement then
      data.placement:close()
    end
    pcall(vim.api.nvim_buf_del_extmark, buf, State.ns, extmark_id)
  end

  State.placements[buf] = nil
end

return M

local Placement = require("mathlive.image.placement")
local Preview = require("mathlive.preview")
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
  local existing = placements[extmark]

  placements[extmark] = {
    placement = existing and existing.placement or nil,
    formula = formula,
    formula_raw = formula_raw,
    formula_type = formula_type,
    hash = hash,
    compiling = true,
    failed = false,
  }

  Typst.compile(formula, hash, function(obj, output_path)
    local entry = State.placements[buf] and State.placements[buf][extmark]
    if not entry or entry.hash ~= hash then return end

    if obj.code == 0 then
      local p
      if entry.placement then
        p = entry.placement
        p:replace(output_path)
      else
        p = Placement.new(buf, output_path, {
          extmark = extmark,
          type = formula_type,
        })
      end

      State.placements[buf][extmark] = {
        placement = p,
        formula = formula,
        formula_raw = formula_raw,
        formula_type = formula_type,
        path = output_path,
        hash = hash,
        failed = false,
      }

      if State.preview and State.preview.extmark == extmark and (State.preview.p or State.preview.float) then
        p:hide()
      else
        p:render_when_ready()
      end
    else
      entry.compiling = false
      entry.failed = true
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

  local extmark = vim.api.nvim_buf_set_extmark(buf, State.ns, range[1], range[2], {
    id = existing_extmark,
    end_row = range[3],
    end_col = range[4],
    right_gravity = true,
    end_right_gravity = false,
  })

  compile_and_place(buf, extmark, formula, formula_raw, formula_type, Typst.hash(formula))
end

---@param buf integer
---@param extmark integer
---@param range Range4
---@param formula string
---@param formula_raw string
function M.update_formula_data(buf, extmark, range, formula, formula_raw)
  local entry = State.placements[buf] and State.placements[buf][extmark]
  if not entry then return end

  vim.api.nvim_buf_set_extmark(buf, State.ns, range[1], range[2], {
    id = extmark,
    end_row = range[3],
    end_col = range[4],
    right_gravity = true,
    end_right_gravity = false,
  })

  entry.formula = formula
  entry.formula_raw = formula_raw
end

---@param buf integer
---@param extmark integer
function M.compile_formula(buf, extmark)
  local entry = State.placements[buf] and State.placements[buf][extmark]
  if not entry then return end

  compile_and_place(buf, extmark, entry.formula, entry.formula_raw, entry.formula_type, Typst.hash(entry.formula))
end

---@param buf integer
---@param extmark integer
function M.remove_formula(buf, extmark)
  local entry = State.placements[buf] and State.placements[buf][extmark]
  if entry and entry.placement then
    entry.placement:close()
  end

  if State.placements[buf] then
    State.placements[buf][extmark] = nil
  end

  if State.preview and State.preview.buf == buf and State.preview.extmark == extmark then
    Preview.close_preview()
  end

  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_del_extmark, buf, State.ns, extmark)
  end
end

---@param buf integer
function M.cleanup_buffer(buf)
  if not State.placements[buf] then return end

  for extmark_id, _ in pairs(State.placements[buf]) do
    M.remove_formula(buf, extmark_id)
  end

  State.placements[buf] = nil
end

return M

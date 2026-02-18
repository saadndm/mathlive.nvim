local Config = require("mathlive.config")
local Formula = require("mathlive.formula")
local Preview = require("mathlive.preview")
local Scanner = require("mathlive.scanner")
local State = require("mathlive.state")
local Typst = require("mathlive.typst")
local Util = require("mathlive.util")

---@class mathlive
local M = {}

function M.setup(opts)
  Config.setup(opts)
  State.setup()
  M.setup_autocmds()
end

function M.setup_autocmds()
  local group = vim.api.nvim_create_augroup("mathlive", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    pattern = table.concat(Config.filetypes, ","),
    group = group,
    callback = function(e)
      if not vim.api.nvim_buf_is_valid(e.buf) then return end

      Formula.cleanup_buffer(e.buf)
      Scanner.detach(e.buf)

      Scanner.attach(e.buf, function(buf, formula_nodes)
        for _, node in ipairs(formula_nodes) do
          local text = vim.treesitter.get_node_text(node, buf)
          local formula, formula_type = Typst.clean_formula(text)
          if formula and formula_type then
            local sr, sc, er, ec = node:range()
            Formula.upsert_formula(buf, { sr, sc, er, ec }, formula, text, formula_type)
          end
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = function(e)
      if not vim.tbl_contains(Config.filetypes, vim.bo[e.buf].filetype) then return end

      M.handle_cursor_moved(e.buf)
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    group = group,
    callback = function(e)
      if not vim.tbl_contains(Config.filetypes, vim.bo[e.buf].filetype) then return end

      M.update_preview(e.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufLeave", {
    group = group,
    callback = function()
      if not State.preview then return end

      local entry = State.placements[State.preview.buf]
          and State.placements[State.preview.buf][State.preview.extmark]
      if entry.placement then
        entry.placement:show()
      end
      Preview.close_preview()
    end,
  })

  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout", "BufDelete" }, {
    group = group,
    callback = function(e)
      if State.preview and State.preview.buf == e.buf then
        Preview.close_preview()
      end
      if State.placements[e.buf] then
        Formula.cleanup_buffer(e.buf)
      end
      Scanner.detach(e.buf)
    end
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      Preview.close_preview()
    end
  })
end

---@param buf integer
function M.handle_cursor_moved(buf)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))

  local prev_extmark = State.preview and State.preview.extmark
  local cur_extmark = Util.get_extmark(buf, State.ns, row - 1, col)

  -- Deleted formula
  if prev_extmark and not Util.is_valid_extmark(buf, State.ns, prev_extmark) then
    Preview.close_preview()
    return
  end

  -- Exited formula
  if prev_extmark and cur_extmark ~= prev_extmark then
    Preview.close_preview()
    local entry = State.placements[buf] and State.placements[buf][prev_extmark]
    if entry.placement then
      entry.placement:show()
    end
  end

  -- Entered formula
  if cur_extmark and cur_extmark ~= prev_extmark then
    local entry = State.placements[buf] and State.placements[buf][cur_extmark]
    if not entry or not entry.placement then return end

    entry.placement:hide()
    Preview.create(buf, cur_extmark, entry)
    Typst.watch(Preview.update)
    Typst.write_temp_formula(entry.formula)
  end

  -- Moved within formula
  if cur_extmark and cur_extmark == prev_extmark and State.preview and State.preview.float then
    vim.schedule(function()
      if State.preview and State.preview.float and vim.api.nvim_win_is_valid(State.preview.float) then
        vim.api.nvim_win_set_config(State.preview.float, {
          relative = 'editor',
          row = vim.fn.screenrow(),
          col = vim.fn.screencol(),
        })
      end
    end)
  end
end

---@param buf integer
function M.update_preview(buf)
  if not State.preview or State.preview.buf ~= buf then return end

  local formula = Formula.extract_formula(buf, State.preview.extmark)
  if formula then
    Typst.write_temp_formula(formula)
  end
end

return M

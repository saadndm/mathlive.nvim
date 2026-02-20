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
            local extmark = Util.get_extmark(buf, State.ns, sr, sc, er, ec)
            local is_active_preview = State.preview and State.preview.buf == buf and State.preview.extmark == extmark

            local is_editing = false

            -- Only calculate in real buffers
            if buf == vim.api.nvim_get_current_buf() and vim.bo[buf].buftype == "" then
              local cursor = vim.api.nvim_win_get_cursor(0)
              local row, col = cursor[1] - 1, cursor[2]
              is_editing = (row > sr or (row == sr and col >= sc))
                  and (row < er or (row == er and col <= ec))
            end

            if is_active_preview and extmark then
              Formula.update_formula_data(buf, extmark, { sr, sc, er, ec }, formula, text)
            elseif is_editing then
              if not extmark then
                extmark = vim.api.nvim_buf_set_extmark(buf, State.ns, sr, sc, {
                  end_row = er,
                  end_col = ec,
                  right_gravity = true,
                  end_right_gravity = false,
                })
              end

              State.placements[buf] = State.placements[buf] or {}
              State.placements[buf][extmark] = State.placements[buf][extmark] or {
                placement = nil,
                formula = formula,
                formula_raw = text,
                formula_type = formula_type,
                hash = Util.hash(formula),
                compiling = false,
                failed = false,
              }

              Formula.update_formula_data(buf, extmark, { sr, sc, er, ec }, formula, text)
            else
              Formula.upsert_formula(buf, { sr, sc, er, ec }, formula, text, formula_type)
            end
          end
        end
        vim.schedule(function()
          M.handle_cursor_moved(buf)
        end)
      end)

      vim.schedule(function()
        M.handle_cursor_moved(e.buf)
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

      local entry = State.placements[State.preview.buf] and State.placements[State.preview.buf][State.preview.extmark]
      if entry and entry.placement then
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
  if buf ~= vim.api.nvim_get_current_buf() or vim.bo[buf].buftype ~= "" then
    return
  end

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
    if entry then
      if not entry.placement then
        Formula.compile_formula(buf, prev_extmark)
      elseif entry.hash ~= Util.hash(entry.formula) then
        Formula.compile_formula(buf, prev_extmark)
      else
        entry.placement:show()
      end
    end
  end

  -- Entered formula
  if cur_extmark and cur_extmark ~= prev_extmark then
    local entry = State.placements[buf] and State.placements[buf][cur_extmark]
    if not entry then return end

    if entry.placement then
      entry.placement:hide()
    end

    if entry.path then
      -- Existing formula with cached image
      Preview.create(buf, cur_extmark, entry)
      Typst.watch(Preview.update_debounced)
    else
      -- Brand new formula
      State.preview = {
        buf = buf,
        extmark = cur_extmark,
        path = "temp.png",
        formula_type = entry.formula_type
      }
      Typst.watch(function()
        if State.preview and not State.preview.p then
          Preview.create(buf, cur_extmark, entry)
        else
          Preview.update_debounced()
        end
      end)
    end

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

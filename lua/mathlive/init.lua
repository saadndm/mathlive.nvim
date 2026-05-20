local Config = require("mathlive.config")
local Formula = require("mathlive.formula")
local Preview = require("mathlive.preview")
local Scanner = require("mathlive.scanner")
local State = require("mathlive.state")
local Renderer = require("mathlive.image.renderer")
local Terminal = require("mathlive.image.terminal")
local Typst = require("mathlive.typst")
local Util = require("mathlive.util")

---@class mathlive
local M = {}
local autocmds_initialized = false

local function should_render_buf(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return false end
  if vim.bo[buf].buftype ~= "" then return false end
  return vim.tbl_contains(Config.filetypes, vim.bo[buf].filetype)
end

local function on_formula_nodes(buf, formula_nodes)
  for _, node in ipairs(formula_nodes) do
    local text = vim.treesitter.get_node_text(node, buf)
    local formula, kind = Typst.clean_formula(text)
    if formula and kind then
      local sr, sc, er, ec = node:range()
      local extmark = Util.get_extmark(buf, State.ns, sr, sc, er, ec)
      local is_active_preview = State.preview and State.preview.buf == buf and State.preview.extmark == extmark

      local is_editing = false

      -- Only calculate in real buffers
      if buf == vim.api.nvim_get_current_buf() and vim.bo[buf].buftype == "" then
        local cursor = vim.api.nvim_win_get_cursor(0)
        local row, col = cursor[1] - 1, cursor[2]
        is_editing = (row > sr or (row == sr and col >= sc)) and (row < er or (row == er and col <= ec))
      end

      if is_active_preview and extmark then
        Formula.update_formula_data(buf, extmark, { sr, sc, er, ec }, formula, text, kind)
      elseif is_editing then
        if not extmark then
          extmark = vim.api.nvim_buf_set_extmark(buf, State.ns, sr, sc, {
            end_row = er,
            end_col = ec,
            right_gravity = true,
            end_right_gravity = false
          })
        end

        local placements = Util.ensure_table(State.placements, buf)
        placements[extmark] = placements[extmark]
          or {
            placement = nil,
            formula = formula,
            formula_raw = text,
            kind = kind,
            hash = Typst.hash(formula),
            compiling = false,
            failed = false
          }

        Formula.update_formula_data(buf, extmark, { sr, sc, er, ec }, formula, text, kind)
      else
        Formula.upsert_formula(buf, { sr, sc, er, ec }, formula, text, kind)
      end
    end
  end

  vim.schedule(function ()
    M.handle_cursor_moved(buf)
  end)
end

local function attach_buffer(buf)
  if not should_render_buf(buf) then return end

  Formula.cleanup_buffer(buf)
  Scanner.detach(buf)

  -- Start scanning immediately, stop later if terminal detection fails
  Terminal.detect(function (supported)
    if supported or not vim.api.nvim_buf_is_valid(buf) then return end
    Formula.cleanup_buffer(buf)
    Scanner.detach(buf)
  end)

  Scanner.attach(buf, on_formula_nodes)

  vim.schedule(function ()
    M.handle_cursor_moved(buf)
  end)
end

function M.setup(opts)
  Config.setup(opts)
  M.setup_autocmds()
  attach_buffer(vim.api.nvim_get_current_buf())
end

function M.setup_autocmds()
  if autocmds_initialized then return end
  autocmds_initialized = true

  local group = vim.api.nvim_create_augroup("mathlive", { clear = true })
  local provider_rows_by_win = {}

  vim.api.nvim_set_decoration_provider(State.ns, {
    on_win = function (_, win, buf, top, bot)
      if win ~= vim.api.nvim_get_current_win() then
        provider_rows_by_win[win] = nil
        return false
      end
      if vim.api.nvim_win_get_buf(win) ~= buf or not should_render_buf(buf) then
        provider_rows_by_win[win] = nil
        return false
      end

      local rows_by_buf = State.multiline_inline_rows[buf]
      if not rows_by_buf then
        provider_rows_by_win[win] = nil
        return false
      end

      local rows = {}
      for row = top, bot - 1 do
        if rows_by_buf[row] then
          rows[row] = true
        end
      end

      provider_rows_by_win[win] = rows
      return next(rows)
    end,
    on_line = function (_, win, buf, row)
      local rows = provider_rows_by_win[win]
      if not rows or not rows[row] then
        return
      end

      if not (State.multiline_inline_rows[buf] and State.multiline_inline_rows[buf][row]) then return end
      Renderer.render_multiline_inline_row(buf, row, win)
    end,
    on_end = function ()
      provider_rows_by_win = {}
    end
  })

  vim.api.nvim_create_autocmd("FileType", {
    pattern = "*",
    group = group,
    callback = function (e)
      attach_buffer(e.buf)
    end
  })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = function (e)
      if not vim.tbl_contains(Config.filetypes, vim.bo[e.buf].filetype) then return end

      M.handle_cursor_moved(e.buf)
    end
  })

  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    group = group,
    callback = function (e)
      if not vim.tbl_contains(Config.filetypes, vim.bo[e.buf].filetype) then return end

      M.update_preview(e.buf)
    end
  })

  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function ()
      if not State.preview or State.preview.buf ~= vim.api.nvim_get_current_buf() then return end

      M.handle_cursor_moved(State.preview.buf)
    end
  })

  vim.api.nvim_create_autocmd("BufLeave", {
    group = group,
    callback = function ()
      if not State.preview then return end

      local entry = State.placements[State.preview.buf] and State.placements[State.preview.buf][State.preview.extmark]
      if entry and entry.placement then
        entry.placement:show()
      end
      Preview.close_preview()
    end
  })

  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout", "BufDelete" }, {
    group = group,
    callback = function (e)
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
    callback = function ()
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

  -- Cleanup is scheduled, so cursor handling can see stale extmarks after edits.
  if cur_extmark then
    local formula = Formula.extract_formula(buf, cur_extmark)
    if not formula then
      Formula.remove_formula(buf, cur_extmark)
      cur_extmark = nil
    end
  end

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
      elseif entry.hash ~= Typst.hash(entry.formula) then
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

    if entry.path and entry.hash == Typst.hash(entry.formula) then
      -- Existing formula with cached image
      Preview.create(buf, cur_extmark, entry)
      Typst.watch(Preview.update_debounced)
    else
      -- Brand new or edited formula without a matching cached image
      State.preview = { buf = buf, extmark = cur_extmark, kind = entry.kind }
      Typst.watch(function ()
        if not State.preview or State.preview.buf ~= buf or State.preview.extmark ~= cur_extmark then return end

        if not State.preview.p then
          Preview.create(buf, cur_extmark, State.preview)
        else
          Preview.update_debounced()
        end
      end)
    end

    Typst.write_temp_formula(entry.formula)
  end

  -- Moved within formula
  if cur_extmark and cur_extmark == prev_extmark and State.preview and State.preview.float then
    vim.schedule(function ()
      if State.preview and State.preview.float and vim.api.nvim_win_is_valid(State.preview.float) then
        vim.api.nvim_win_set_config(State.preview.float, {
          relative = 'editor',
          row = vim.fn.screenrow(),
          col = vim.fn.screencol()
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

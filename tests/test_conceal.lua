local MiniTest = require("mini.test")
local helpers = dofile("tests/helpers.lua")

local child = helpers.new_child_neovim()
local expect, eq = helpers.expect, helpers.expect.equality
local new_set = MiniTest.new_set
local SAMPLE_LINE = "[[link]] `code` *strong* _italics_ ~~strikethrough~~ [text](url) [[link|display text]]|"

local function set_window_options(target)
  target.set_size(3, 120)
  target.bo.filetype = "markdown"
  target.o.concealcursor = "nvic"
  target.wo.wrap = false
  target.o.laststatus = 0
  target.o.ruler = false
end

local function set_conceallevel(conceallevel)
  child.o.conceallevel = conceallevel
  child.wo.conceallevel = conceallevel
end

local function display_width(text)
  return vim.fn.strdisplaywidth(text)
end

local function visible_width_from_screenshot()
  local screenshot = child.get_screenshot()
  local visible_line = helpers.clean_line(table.concat(screenshot.text[1]))
  expect.reference_screenshot(screenshot, nil, { ignore_attr = true })
  return display_width(visible_line)
end

local function add_test_extmarks()
  child.lua([=[
    local buf = vim.api.nvim_get_current_buf()
    local row = 0
    local ns = vim.api.nvim_create_namespace("test")
    local text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]

    local function span(pat, init)
      local s, e = text:find(pat, init or 1, true)
      assert(s and e, "pattern not found: " .. pat)
      return s - 1, e
    end

    local link_s, link_e = span("[[link]]")
    local code_s, code_e = span("`code`")
    local strong_s, strong_e = span("*strong*")
    local italics_s, italics_e = span("_italics_")
    local strike_s, strike_e = span("~~strikethrough~~")
    local textlink_s, textlink_e = span("[text](url)")
    local wiki_s, wiki_e = span("[[link|display text]]")

    -- Zero-width extmark, no conceal, inline virt_text
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
      virt_text_pos = "inline", virt_text = { { ">>" } },
    })

    -- Zero-width extmark, empty conceal, inline virt_text
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
      end_row = row, end_col = 0, conceal = "",
      virt_text_pos = "inline", virt_text = { { "  " } },
    })

    -- Zero-width extmark, no conceal, inline virt_text
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
      virt_text_pos = "inline", virt_text = { { "--" } },
    })

    -- Range extmark, non-empty conceal, no virt_text
    vim.api.nvim_buf_set_extmark(buf, ns, row, link_s, {
      end_row = row, end_col = link_e, conceal = "L",
    })

    -- Range extmark, empty conceal, no virt_text
    vim.api.nvim_buf_set_extmark(buf, ns, row, code_s, {
      end_row = row, end_col = code_e, conceal = "",
    })

    -- Range extmark, non-empty conceal, inline virt_text
    vim.api.nvim_buf_set_extmark(buf, ns, row, strong_s, {
      end_row = row, end_col = strong_e, conceal = "S",
      virt_text_pos = "inline", virt_text = { { "+" } },
    })

    -- Range extmark, empty conceal, inline virt_text
    vim.api.nvim_buf_set_extmark(buf, ns, row, italics_s, {
      end_row = row, end_col = italics_e, conceal = "",
      virt_text_pos = "inline", virt_text = { { "<>" } },
    })

    -- Range extmark, no conceal, inline virt_text
    vim.api.nvim_buf_set_extmark(buf, ns, row, strike_s, {
      end_row = row, end_col = strike_e,
      virt_text_pos = "inline", virt_text = { { "-" } },
    })

    -- Range extmark, non-empty conceal, no virt_text
    vim.api.nvim_buf_set_extmark(buf, ns, row, textlink_s, {
      end_row = row, end_col = textlink_e, conceal = "T",
    })

    -- Range extmark, empty conceal, inline virt_text
    vim.api.nvim_buf_set_extmark(buf, ns, row, textlink_s, {
      end_row = row, end_col = textlink_e, conceal = "",
      virt_text_pos = "inline", virt_text = { { "=" } },
    })

    -- Range extmark, non-empty conceal, inline virt_text
    vim.api.nvim_buf_set_extmark(buf, ns, row, wiki_s, {
      end_row = row, end_col = wiki_e, conceal = "W",
      virt_text_pos = "inline", virt_text = { { ">" } },
    })

    -- Range extmark, empty conceal, no virt_text
    vim.api.nvim_buf_set_extmark(buf, ns, row, wiki_s + 2, {
      end_row = row, end_col = wiki_e - 2, conceal = "",
    })
  ]=])
end

local T = new_set({
  parametrize = { { 0 }, { 1 }, { 2 }, { 3 } },
  hooks = {
    pre_case = function()
      child.setup()

      child.lua([[M = require("mathlive.conceal")]])

      set_window_options(child)
    end,
    post_once = child.stop(),
  },
})

T["ts_conceal_delta"] = function(conceallevel)
  set_conceallevel(conceallevel)
  child.set_lines(SAMPLE_LINE)

  local visible_width = visible_width_from_screenshot()

  local delta = child.lua_get([[
    (function ()
      local buf = vim.api.nvim_get_current_buf()
      local row = 0
      local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
      local spans = M.collect_ts_spans(buf, row)
      local delta = M.ts_conceal_delta(0, #line, {}, spans)
      return delta
    end)()
  ]])

  eq(visible_width, display_width(SAMPLE_LINE) - delta)
end

T["extmark_conceal_delta"] = function(conceallevel)
  set_conceallevel(conceallevel)

  -- Disable other conceal sources
  child.g.markdown_syntax_conceal = 0
  child.lua([[
    local buf = vim.api.nvim_get_current_buf()

    local highlighter = vim.treesitter.highlighter.active[buf]
    if highlighter then
      highlighter:destroy()
    end
  ]])

  child.set_lines(SAMPLE_LINE)
  add_test_extmarks()

  local visible_width = visible_width_from_screenshot()

  local delta = child.lua_get([[
    (function ()
      local buf = vim.api.nvim_get_current_buf()
      local row = 0
      local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
      local extmarks = M.collect_extmarks(buf, row)
      local delta = M.extmark_conceal_delta(0, #line, extmarks)
      return delta
    end)()
  ]])

  eq(visible_width, display_width(SAMPLE_LINE) - delta)
end

T["projector:screen_width"] = function(conceallevel)
  set_conceallevel(conceallevel)
  child.set_lines(SAMPLE_LINE)
  add_test_extmarks()

  local visible_width = visible_width_from_screenshot()

  local width = child.lua_get([[
    (function ()
      local buf = vim.api.nvim_get_current_buf()
      local row = 0
      local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
      local projector = M.build_row_projector(buf, row, line, {})
      return projector:screen_width(0, #line)
    end)()
  ]])

  eq(visible_width, width)
end

T["projector:scroll_padding_before"] = function(conceallevel)
  set_conceallevel(conceallevel)
  child.set_lines(SAMPLE_LINE)
  add_test_extmarks()

  local padding = child.lua_get([[
    (function()
      local buf = vim.api.nvim_get_current_buf()
      local row = 0
      local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
      local start_col = assert(line:find("`code`", 1, true)) - 1
      local end_col = start_col + #"`code`"

      local projector = M.build_row_projector(buf, row, line, {
        {
          range = { row, start_col, row, end_col },
          placement = {
            state = function()
              return { size = { width = 3 } }
            end,
          },
        },
      })
      local before = projector:screen_width(0, start_col)
      local replacement_width = (vim.wo.conceallevel == 1) and 1 or 0

      return {
        before_replacement = projector:scroll_padding_before(before + 3),
        at_hidden = projector:scroll_padding_before(before + 3 + replacement_width),
      }
    end)()
  ]])

  if conceallevel == 1 then
    eq(padding.at_hidden - padding.before_replacement, 1)
  else
    eq(padding.at_hidden - padding.before_replacement, 0)
  end
end

return T

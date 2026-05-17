local MiniTest = require("mini.test")
local helpers = dofile("tests/helpers.lua")

local child = helpers.new_child_neovim()
local eq = helpers.expect.equality
local new_set = MiniTest.new_set

local function set_cursor(row, col)
  child.set_cursor(row, col)
  child.lua([[require("mathlive").handle_cursor_moved(vim.api.nvim_get_current_buf())]])
end

local function placements()
  return child.lua_get(
    [[
    (function()
      local State = require("mathlive.state")
      local Util = require("mathlive.util")
      local buf = vim.api.nvim_get_current_buf()
      local out = {}

      for extmark, entry in pairs(State.placements[buf] or {}) do
        local range = Util.is_valid_extmark(buf, State.ns, extmark)
        if range then
          out[#out + 1] = {
            formula = entry.formula,
            formula_raw = entry.formula_raw,
            kind = entry.kind,
            range = range,
            valid = true,
          }
        end
      end

      table.sort(out, function(a, b)
        if a.range[1] ~= b.range[1] then return a.range[1] < b.range[1] end
        if a.range[2] ~= b.range[2] then return a.range[2] < b.range[2] end
        return a.formula_raw < b.formula_raw
      end)

      return out
    end)()
  ]]
  )
end

local function stale_placement_count()
  return child.lua_get(
    [[
    (function()
      local State = require("mathlive.state")
      local Util = require("mathlive.util")
      local buf = vim.api.nvim_get_current_buf()
      local n = 0

      for extmark, _ in pairs(State.placements[buf] or {}) do
        if not Util.is_valid_extmark(buf, State.ns, extmark) then
          n = n + 1
        end
      end

      return n
    end)()
  ]]
  )
end

local function preview_state()
  return child.lua_get(
    [[
    (function()
      local State = require("mathlive.state")
      local Util = require("mathlive.util")
      local preview = State.preview
      if not preview then return false end

      return {
        kind = preview.kind,
        range = Util.is_valid_extmark(preview.buf, State.ns, preview.extmark),
        closed = preview.p and preview.p.closed or false,
      }
    end)()
  ]]
  )
end

local T = new_set({
  hooks = {
    pre_case = function ()
      child.setup()

      child.lua(
        [[
        _G.mathlive_test = { closed_previews = 0 }
        require("mathlive.image.terminal").supported = true

        local Typst = require("mathlive.typst")
        Typst.compile = function(_, _, callback)
          callback({ code = 1, signal = 0 }, "")
        end
        Typst.watch = function(callback)
          _G.mathlive_test.watch_callback = callback
        end
        Typst.write_temp_formula = function() end

        local Preview = require("mathlive.preview")
        Preview.create = function(buf, extmark, prev_preview)
          local kind = prev_preview.kind

          require("mathlive.state").preview = {
            buf = buf,
            extmark = extmark,
            kind = kind,
            p = {
              closed = false,
              close = function(self)
                self.closed = true
                _G.mathlive_test.closed_previews = _G.mathlive_test.closed_previews + 1
              end,
            },
          }
        end
        Preview.close_preview = function()
          local State = require("mathlive.state")
          if State.preview and State.preview.p then
            State.preview.p:close()
          end
          State.preview = nil
        end
      ]]
      )

      child.bo.filetype = "markdown"
    end,
    post_once = child.stop()
  }
})

T["adds inline equation"] = function ()
  child.set_lines({ "prefix $x + 1$ suffix" })

  eq(placements(), {
    {
      formula = "x + 1",
      formula_raw = "$x + 1$",
      kind = "inline_formula",
      range = { 0, 7, 0, 14 },
      valid = true
    }
  })
end

T["adds displayed equation"] = function ()
  child.set_lines({ "before", "$$", "x + 1", "$$", "after" })

  eq(placements(), {
    {
      formula = "\nx + 1\n",
      formula_raw = "$$\nx + 1\n$$",
      kind = "displayed_equation",
      range = { 1, 0, 3, 2 },
      valid = true
    }
  })
end

T["adds multiple inline equations on one line"] = function ()
  child.set_lines({ "a $x$ b $y + 1$ c" })

  eq(placements(), {
    { formula = "x", formula_raw = "$x$", kind = "inline_formula", range = { 0, 2, 0, 5 }, valid = true },
    {
      formula = "y + 1",
      formula_raw = "$y + 1$",
      kind = "inline_formula",
      range = { 0, 8, 0, 15 },
      valid = true
    }
  })
end

T["adds mixed inline and displayed equations"] = function ()
  child.set_lines({ "top $a$", "$$", "b + c", "$$", "bottom $d$" })

  eq(placements(), {
    { formula = "a", formula_raw = "$a$", kind = "inline_formula", range = { 0, 4, 0, 7 }, valid = true },
    {
      formula = "\nb + c\n",
      formula_raw = "$$\nb + c\n$$",
      kind = "displayed_equation",
      range = { 1, 0, 3, 2 },
      valid = true
    },
    { formula = "d", formula_raw = "$d$", kind = "inline_formula", range = { 4, 7, 4, 10 }, valid = true }
  })
end

T["updates inline equation text"] = function ()
  child.set_lines({ "prefix $x$ suffix" })
  child.set_lines({ "prefix $x + 1$ suffix" }, 0, 1)

  eq(placements(), {
    {
      formula = "x + 1",
      formula_raw = "$x + 1$",
      kind = "inline_formula",
      range = { 0, 7, 0, 14 },
      valid = true
    }
  })
end

T["updates displayed equation text"] = function ()
  child.set_lines({ "$$", "x", "$$" })
  child.set_lines({ "x + 1" }, 1, 2)

  eq(placements(), {
    {
      formula = "\nx + 1\n",
      formula_raw = "$$\nx + 1\n$$",
      kind = "displayed_equation",
      range = { 0, 0, 2, 2 },
      valid = true
    }
  })
end

T["removes inline equation when delimiters are deleted"] = function ()
  child.set_lines({ "prefix $x$ suffix" })
  child.set_lines({ "prefix x suffix" }, 0, 1)

  eq(placements(), {})
  eq(stale_placement_count(), 0)
end

T["removes displayed equation block"] = function ()
  child.set_lines({ "before", "$$", "x", "$$", "after" })
  child.set_lines({}, 1, 4)

  eq(placements(), {})
  eq(stale_placement_count(), 0)
end

T["removes only deleted equation from line"] = function ()
  child.set_lines({ "$x$ and $y$" })
  child.set_lines({ "$x$ and y" }, 0, 1)

  eq(placements(), {
    { formula = "x", formula_raw = "$x$", kind = "inline_formula", range = { 0, 0, 0, 3 }, valid = true }
  })
  eq(stale_placement_count(), 0)
end

T["updates inline range after text inserted before it"] = function ()
  child.set_lines({ "a $x$" })
  child.set_lines({ "prefix a $x$" }, 0, 1)

  eq(placements(), {
    { formula = "x", formula_raw = "$x$", kind = "inline_formula", range = { 0, 9, 0, 12 }, valid = true }
  })
end

T["updates displayed range after lines inserted before it"] = function ()
  child.set_lines({ "$$", "x", "$$" })
  child.set_lines({ "one", "two" }, 0, 0)

  eq(placements(), {
    {
      formula = "\nx\n",
      formula_raw = "$$\nx\n$$",
      kind = "displayed_equation",
      range = { 2, 0, 4, 2 },
      valid = true
    }
  })
end

T["closes inline preview when equation line is deleted"] = function ()
  child.set_lines({ "before", "prefix $x$ suffix", "after" })
  set_cursor(2, 9)
  eq(preview_state().kind, "inline_formula")

  child.set_lines({}, 1, 2)
  child.lua([[require("mathlive").handle_cursor_moved(vim.api.nvim_get_current_buf())]])

  eq(preview_state(), false)
end

T["closes displayed preview when equation block is deleted"] = function ()
  child.set_lines({ "before", "$$", "x", "$$", "after" })
  set_cursor(3, 0)
  eq(preview_state().kind, "displayed_equation")

  child.set_lines({}, 1, 4)
  child.lua([[require("mathlive").handle_cursor_moved(vim.api.nvim_get_current_buf())]])

  eq(preview_state(), false)
end

T["keeps edited preview data and closes after cursor exits"] = function ()
  child.set_lines({ "prefix $x$ suffix" })
  set_cursor(1, 9)

  child.set_lines({ "prefix $x + 1$ suffix" }, 0, 1)
  set_cursor(1, 18)

  eq(preview_state(), false)
  eq(placements(), {
    {
      formula = "x + 1",
      formula_raw = "$x + 1$",
      kind = "inline_formula",
      range = { 0, 7, 0, 14 },
      valid = true
    }
  })
end

T["shows existing placement after edited preview compiles"] = function ()
  child.set_lines({ "prefix $x$ suffix" })

  child.lua(
    [[
    local State = require("mathlive.state")
    local Typst = require("mathlive.typst")
    local buf = vim.api.nvim_get_current_buf()
    local extmark = next(State.placements[buf])

    State.placements[buf][extmark].placement = {
      hidden = true,
      hide = function(self) self.hidden = true end,
      show = function(self) self.hidden = false; self.rendered = true end,
      render = function(self) self.rendered = true end,
      replace = function(self, path) self.path = path end,
    }
    State.placements[buf][extmark].formula = "x + 1"
    State.placements[buf][extmark].formula_raw = "$x + 1$"
    State.placements[buf][extmark].path = "old.png"
    State.placements[buf][extmark].hash = Typst.hash("x")

    Typst.compile = function(_, _, callback)
      callback({ code = 0, signal = 0 }, "test.png")
    end

    require("mathlive.formula").compile_formula(buf, extmark)
  ]]
  )

  eq(
    child.lua_get(
      [[
      (function()
        local State = require("mathlive.state")
        local buf = vim.api.nvim_get_current_buf()
        local extmark = next(State.placements[buf])
        local p = State.placements[buf][extmark].placement
        return { hidden = p.hidden, rendered = p.rendered, path = p.path }
      end)()
    ]]
    ), { hidden = false, rendered = true, path = "test.png" }
  )
end

T["ignores stale preview watch callback after cursor exits"] = function ()
  child.set_lines({ "prefix $x$ suffix" })
  set_cursor(1, 9)
  local watch_callback = child.lua_get([[_G.mathlive_test.watch_callback ~= nil]])
  eq(watch_callback, true)

  set_cursor(1, 18)
  eq(preview_state(), false)

  child.lua([[_G.mathlive_test.watch_callback()]])

  eq(preview_state(), false)
end

T["cleans placements when buffer is wiped"] = function ()
  child.set_lines({ "prefix $x$ suffix" })
  local buf = child.api.nvim_get_current_buf()
  eq(#placements(), 1)

  child.cmd("enew")
  child.api.nvim_buf_delete(buf, { force = true })

  eq(child.lua_get([[require("mathlive.state").placements[...] == nil]], { buf }), true)
end

return T

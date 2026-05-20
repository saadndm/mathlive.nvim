local Config = require("mathlive.config")
local State = require("mathlive.state")
local Util = require("mathlive.util")

---@class mathlive.typst
local M = {}

---@param formula string
---@return string?
---@return mathlive.image.Kind?
function M.clean_formula(formula)
  local display_content = formula:match("^%$%$(.*)%$%$$")
  if display_content then
    return display_content, "displayed_equation"
  end

  local inline_content = formula:match("^%$(.*)%$$")
  if inline_content then
    return inline_content, "inline_formula"
  end

  return nil, nil
end

---@param formula string
local function get_typst_input(formula)
  local cell = Util.size()

  return string.format(
    [=[#set page(width: auto, height: auto, margin: 0pt, fill: none)
      #set math.text(top-edge: "bounds", bottom-edge: "bounds")
      #set text(size: %s, fill: rgb("%s"))
      #let cell-w = %.8fpt
      #let cell-h = %.8fpt
      %s

      #let snap-to-grid(body) = context {
        let s = measure(body)
        let cols = calc.ceil(s.width / cell-w)
        let rows = calc.ceil(s.height / cell-h)

        box(width: cols * cell-w, height: rows * cell-h)[
          #align(center + horizon, body)
        ]
      }

      #snap-to-grid[$%s$]]=], M.text_size(cell), Config.color_hex, cell.width * 72 / Config.ppi,
    cell.height * 72 / Config.ppi, Config.preamble, formula
  )
end

---@param cell mathlive.image.Size
function M.text_size(cell)
  return string.format("%.4fpt", cell.height * 72 / Config.ppi * Config.text_scale)
end

---@param formula string
function M.hash(formula)
  local cell_size = Util.size()
  return Util.hash(table.concat({
      formula,
      Config.color_hex,
      Config.preamble,
      M.text_size(cell_size),
      tostring(Config.ppi),
      string.format("%.4f", cell_size.width),
      string.format("%.4f", cell_size.height),
    }, "\n"))
end

---@param formula  string
---@param hash     string
---@param callback fun(obj: vim.SystemCompleted, output_path: string)
function M.compile(formula, hash, callback)
  local output_path = State.cache_path .. hash .. ".png"

  if vim.fn.filereadable(output_path) == 1 then
    callback({ code = 0, signal = 0 }, output_path)
    return
  end

  local typst_input = get_typst_input(formula)

  vim.system({
    "typst",
    "compile",
    "--format",
    "png",
    "--ppi",
    tostring(Config.ppi),
    "--pages",
    "1",
    "-",
    output_path,
  },
    { stdin = typst_input }, function (obj)
      vim.schedule(function ()
        callback(obj, output_path)
      end)
    end)
end

---@param formula string
function M.write_temp_formula(formula)
  local typst_input = get_typst_input(formula)
  local file = io.open(State.cache_path .. "temp.typ", "w")
  if file then
    file:write(typst_input)
    file:close()
  else
    print("Error: Could not open file for writing")
  end
end

---@param callback fun()
function M.watch(callback)
  State.typst_process = vim.system({
    "typst",
    "watch",
    "--ppi",
    tostring(Config.ppi),
    State.cache_path .. "temp.typ",
    State.cache_path .. "temp.png",
  },
    {
      text = true,
      stderr = function (err, data)
        if err then return end
        if data and data:find("compiled") then
          vim.schedule(callback)
        end
      end,
    })
end

return M

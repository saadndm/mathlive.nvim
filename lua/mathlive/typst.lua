local Config = require("mathlive.config")
local State = require("mathlive.state")

---@class mathlive.typst
local M = {}

---@param formula string
---@return string?
---@return mathlive.image.Type?
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
  return string.format(
    [[#set page(width: auto, height: auto, margin: (x: 0pt, y: 1pt), fill: none)
      #set math.text(top-edge: "bounds", bottom-edge: "bounds")
      #set text(fill: rgb("%s"))
      $%s$]],
    Config.color_hex,
    formula
  )
end

---@param formula string
---@param hash string
---@param callback fun(obj: vim.SystemCompleted, output_path: string)
function M.compile(formula, hash, callback)
  local output_path = State.cache_path .. hash .. ".png"

  if vim.fn.filereadable(output_path) == 1 then
    callback({ code = 0, signal = 0 }, output_path)
    return
  end

  local typst_input = get_typst_input(formula)

  vim.system({
    "typst", "compile", "--format", "png", "--pages", "1", "-", output_path,
  }, { stdin = typst_input }, function(obj)
    vim.schedule(function()
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
    "typst", "watch", State.cache_path .. "temp.typ", State.cache_path .. "temp.png",
  }, {
    text = true,
    stderr = function(err, data)
      if err then return end
      if data and data:find("compiled successfully") then
        vim.schedule(callback)
      end
    end,
  })
end

return M

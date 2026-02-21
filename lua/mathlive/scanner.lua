local State = require("mathlive.state")

---@class mathlive.scanner
local M = {}

local attached_trees = {} ---@type table<integer, table<TSTree, boolean>?>

local math_query = vim.treesitter.query.parse("latex", [[
  (inline_formula) @m
  (displayed_equation) @m
]])

---@param buf integer
---@param tree TSTree
---@return TSNode[]
local function scan_tree(buf, tree)
  local changed_nodes = {}
  local map = {}
  local extmarks = vim.api.nvim_buf_get_extmarks(buf, State.ns, 0, -1, { details = false })

  for _, mark in ipairs(extmarks) do
    local id, sr, sc = mark[1], mark[2], mark[3]
    map[sr .. ":" .. sc] = id
  end

  for _, node in math_query:iter_captures(tree:root(), buf) do
    local ok, text = pcall(vim.treesitter.get_node_text, node, buf)
    if not ok then goto continue end
    local sr, sc, _, _ = node:range()
    local id = map[sr .. ":" .. sc]

    local p = id and State.placements[buf] and State.placements[buf][id]
    if not p or p.formula_raw ~= text then
      table.insert(changed_nodes, node)
    end
    ::continue::
  end

  return changed_nodes
end

---@param buf integer
---@param on_change fun(buf: integer, formula_nodes: TSNode[])
function M.attach(buf, on_change)
  if attached_trees[buf] then return end

  State.placements[buf] = State.placements[buf] or {}
  attached_trees[buf] = {}

  local main_parser = vim.treesitter.get_parser(buf)
  if not main_parser then return end
  main_parser:parse(true)

  local function on_tree_change(_, tree)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) then return end
      local changed = scan_tree(buf, tree)
      if #changed > 0 then
        on_change(buf, changed)
      end
    end)
  end

  local function monitor_ltree(ltree)
    if attached_trees[buf][ltree] then return end
    attached_trees[buf][ltree] = true
    ltree:register_cbs({ on_changedtree = on_tree_change })
  end

  main_parser:register_cbs({
    on_child_added = function(ltree)
      if ltree:lang() ~= "latex" then return end
      monitor_ltree(ltree)
    end,
  }, true)

  main_parser:for_each_tree(function(tree, ltree)
    if ltree:lang() == "latex" then
      monitor_ltree(ltree)
      local changed = scan_tree(buf, tree)
      on_change(buf, changed)
    end
  end)
end

function M.detach(buf)
  attached_trees[buf] = nil
end

return M

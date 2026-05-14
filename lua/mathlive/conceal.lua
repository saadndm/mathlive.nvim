local Util = require("mathlive.util")

local M = {}

---@class mathlive.conceal.InlineItem
---@field placement mathlive.image.Placement
---@field range     Range4

---@class mathlive.conceal.Extmark
---@field id      integer
---@field row     integer
---@field col     integer
---@field details vim.api.keyset.extmark_details

---@class mathlive.conceal.TSSpan
---@field start_col integer
---@field end_col   integer
---@field conceal   string

---@class mathlive.conceal.RowProjector
---@field buf                   integer
---@field row                   integer
---@field line_text             string
---@field inline_items          mathlive.conceal.InlineItem[]
---@field extmarks              mathlive.conceal.Extmark[]
---@field ts_spans              mathlive.conceal.TSSpan[]
---@field cache_key             string
---@field screen_width          fun(self: mathlive.conceal.RowProjector, start_col: integer, end_col: integer): integer
---@field scroll_padding_before fun(self: mathlive.conceal.RowProjector, leftcol: integer): integer

---@type table<string, vim.treesitter.Query | false>
local ts_query_cache = {}
local our_ns = vim.api.nvim_create_namespace("mathlive.image")

---@param details vim.api.keyset.extmark_details
---@return integer
local function inline_virt_text_width(details)
  if details.virt_text_hide or details.virt_text_pos ~= "inline" then return 0 end

  local chunks = details.virt_text
  if not chunks then return 0 end

  local width = 0
  for _, chunk in ipairs(chunks) do
    width = width + vim.fn.strdisplaywidth(chunk[1])
  end
  return width
end

---@param conceal      string
---@param conceallevel integer
local function conceal_replacement_width(conceal, conceallevel)
  if conceallevel >= 3 then return 0 end

  if conceal == "" then
    return (conceallevel == 1 and 1 or 0)
  end

  local width = vim.fn.strdisplaywidth(conceal)
  if conceallevel == 1 and width == 0 then
    width = 1
  end
  return width
end

---@param extmarks     mathlive.conceal.Extmark[]
---@param ts_spans     mathlive.conceal.TSSpan[]
---@param conceallevel integer
local function build_column_map(extmarks, ts_spans, conceallevel)
  local inline_at = {} ---@type table<integer, integer>
  local covered = {} ---@type table<integer, true?>
  local replacement_at = {} ---@type table<integer, integer>
  local concealed = {} ---@type { id: integer, start_col: integer, end_col: integer, conceal: string } []

  for _, mark in ipairs(extmarks) do
    local d = mark.details
    local inline_width = inline_virt_text_width(d)
    if inline_width > 0 then
      inline_at[mark.col] = (inline_at[mark.col] or 0) + inline_width
    end

    if d.conceal ~= nil and d.end_col and conceallevel > 0 then
      concealed[#concealed + 1] = { id = mark.id, start_col = mark.col, end_col = d.end_col, conceal = d.conceal }
      for col = mark.col, d.end_col - 1 do
        covered[col] = true
      end
    end
  end

  table.sort(concealed, function (a, b)
    if a.start_col ~= b.start_col then return a.start_col < b.start_col end
    if a.id ~= b.id then return a.id > b.id end
    return a.end_col > b.end_col
  end)

  local i = 1
  while i <= #concealed do
    local winner = concealed[i]
    local group_start = winner.start_col
    local j = i + 1
    while j <= #concealed and concealed[j].start_col == group_start do
      j = j + 1
    end
    replacement_at[group_start] = conceal_replacement_width(winner.conceal, conceallevel)
    i = j
  end

  if conceallevel > 0 then
    for _, span in ipairs(ts_spans) do
      local run_start = nil ---@type integer?
      for col = span.start_col, span.end_col - 1 do
        if not covered[col] then
          covered[col] = true
          run_start = run_start or col
        elseif run_start then
          replacement_at[run_start] = conceal_replacement_width(span.conceal, conceallevel)
          run_start = nil
        end
      end
      if run_start then
        replacement_at[run_start] = conceal_replacement_width(span.conceal, conceallevel)
      end
    end
  end

  return inline_at, covered, replacement_at
end

---@param line_text      string
---@param start_col      integer
---@param end_col        integer
---@param inline_at      table<integer, integer>
---@param covered        table<integer, true?>
---@param replacement_at table<integer, integer>
---@param conceallevel   integer
---@param cb             fun(hidden: boolean, width: integer): boolean?
local function walk_gap(line_text, start_col, end_col, inline_at, covered, replacement_at, conceallevel, cb)
  local col = math.max(0, start_col)
  local stop_col = math.max(col, math.min(end_col, #line_text))

  while col < stop_col do
    local inline_width = inline_at[col] or 0
    if inline_width > 0 and cb(false, inline_width) then
      return
    end

    if covered[col] then
      local hidden_start = col
      local replacement_width = replacement_at[hidden_start] or 0

      repeat
        col = col + 1
      until col >= stop_col or not covered[col] or replacement_at[col] ~= nil or (inline_at[col] or 0) > 0

      local hidden_width = math.max(0, (col - hidden_start) - replacement_width)
      if conceallevel == 1 and replacement_width > 0 then
        if cb(false, replacement_width) then
          return
        end
        if hidden_width > 0 and cb(true, hidden_width) then
          return
        end
      else
        if hidden_width > 0 and cb(true, hidden_width) then
          return
        end
        if replacement_width > 0 and cb(false, replacement_width) then
          return
        end
      end
    else
      local width = vim.fn.strdisplaywidth(line_text:sub(col + 1, col + 1))
      col = col + 1
      if width > 0 and cb(false, width) then
        return
      end
    end
  end
end

---@param buf integer
---@param row integer
function M.collect_ts_spans(buf, row)
  local seen = {}
  local spans = {} ---@type mathlive.conceal.TSSpan[]
  if not vim.treesitter.highlighter.active[buf] then
    return spans
  end

  local ok_parser, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok_parser or not parser then
    return spans
  end
  ---@cast parser vim.treesitter.LanguageTree

  ---@param lang string
  local function get_query(lang)
    local cached = ts_query_cache[lang]
    if cached ~= nil then return cached or nil end

    local ok_query, query = pcall(vim.treesitter.query.get, lang, "highlights")
    if not ok_query or not query then
      ts_query_cache[lang] = false
      return nil
    end

    ---@cast query vim.treesitter.Query
    ts_query_cache[lang] = query
    return query
  end

  ---@param trees table<integer, TSTree>
  ---@param lang  string
  local function handle_tree(trees, lang)
    local query = get_query(lang)
    if not query then return end

    for _, tree in ipairs(trees) do
      local root = tree:root()
      for _, node, metadata in query:iter_captures(root, buf, row, row + 1) do
        if metadata and metadata.conceal ~= nil then
          local sr, sc, er, ec = node:range()
          if row < sr or row > er then goto continue end

          local s = (sr == row) and sc or 0
          local e = (er == row) and ec or 9999
          if e > s then
            local key = string.format("%d:%d:%d:%d:%s", sr, sc, er, ec, metadata.conceal)
            if not seen[key] then
              seen[key] = true
              spans[#spans + 1] = { start_col = s, end_col = e, conceal = metadata.conceal }
            end
          end
        end
        ::continue::
      end
    end
  end

  ---@param lang_tree vim.treesitter.LanguageTree
  local function trees_on_row(lang_tree)
    local trees = lang_tree:parse()
    if not trees then return nil end

    for _, tree in ipairs(trees) do
      local root = tree:root()
      local sr, _, er, ec = root:range()
      if sr <= row and (row < er or (row == er and ec > 0)) then
        return trees
      end
    end

    return nil
  end

  ---@param lang_tree vim.treesitter.LanguageTree
  local function walk(lang_tree)
    local trees = trees_on_row(lang_tree)
    if not trees then return end

    handle_tree(trees, lang_tree:lang())
    for _, child in pairs(lang_tree:children()) do
      walk(child)
    end
  end

  walk(parser)

  return spans
end

---@param start_col integer
---@param end_col   integer
---@param covered   table<integer, true?>
---@param ts_spans  mathlive.conceal.TSSpan[]
function M.ts_conceal_delta(start_col, end_col, covered, ts_spans)
  local conceallevel = vim.wo.conceallevel
  if conceallevel == 0 or end_col < start_col then
    return 0
  end
  local delta = 0

  for _, span in ipairs(ts_spans) do
    local s = math.max(start_col, span.start_col)
    local e = math.min(end_col, span.end_col)

    if e > s then
      local uncovered = 0
      for i = s, e - 1 do
        if not covered[i] then
          uncovered = uncovered + 1
        end
      end

      if uncovered > 0 then
        local replacement_width = conceal_replacement_width(span.conceal, conceallevel)
        delta = delta + (uncovered - replacement_width)
      end
    end
  end

  return delta
end

---@param buf integer
---@param row integer
function M.collect_extmarks(buf, row)
  local marks = {} ---@type mathlive.conceal.Extmark[]
  for _, ns_id in pairs(vim.api.nvim_get_namespaces()) do
    if ns_id == our_ns then goto continue end

    local extmarks = vim.api.nvim_buf_get_extmarks(buf, ns_id, { row, 0 }, { row, -1 }, { details = true })

    for _, mark in ipairs(extmarks) do
      local id, r, c, details = mark[1], mark[2], mark[3], mark[4]
      if details then
        marks[#marks + 1] = { id = id, row = r, col = c, details = details }
      end
    end
    ::continue::
  end
  return marks
end

---@param start_col integer
---@param end_col   integer
---@param extmarks  mathlive.conceal.Extmark[]
function M.extmark_conceal_delta(start_col, end_col, extmarks)
  local covered = {} ---@type table<integer, true?>
  local conceallevel = vim.wo.conceallevel
  local inline_total = 0
  local concealed = {} ---@type { id: integer, start_col: integer, end_col: integer, conceal: string } []

  for _, mark in ipairs(extmarks) do
    local d = mark.details
    local inline_width = inline_virt_text_width(d)
    if inline_width > 0 and mark.col >= start_col and mark.col < end_col then
      inline_total = inline_total + inline_width
    end

    if d.conceal ~= nil and d.end_col and conceallevel > 0 then
      local s = math.max(mark.col, start_col)
      local e = math.min(d.end_col, end_col)
      if e > s then
        for i = s, e - 1 do
          covered[i] = true
        end

        concealed[#concealed + 1] = { id = mark.id, start_col = mark.col, end_col = e, conceal = d.conceal }
      end
    end
  end

  local hidden_total = 0
  for col = start_col, end_col - 1 do
    if covered[col] then
      hidden_total = hidden_total + 1
    end
  end

  table.sort(concealed, function (a, b)
    if a.start_col ~= b.start_col then return a.start_col < b.start_col end
    if a.id ~= b.id then return a.id > b.id end
    return a.end_col > b.end_col
  end)

  local total_replacement = 0
  local i = 1
  while i <= #concealed do
    local winner = concealed[i]
    if not winner then break end

    local group_start = winner.start_col
    local j = i + 1

    while j <= #concealed do
      if not concealed[j] or concealed[j].start_col ~= group_start then break end
      j = j + 1
    end

    if group_start >= start_col then
      total_replacement = total_replacement + conceal_replacement_width(winner.conceal, conceallevel)
    end
    i = j
  end

  return hidden_total - total_replacement - inline_total, covered
end

---@param buf          integer
---@param row          integer
---@param line_text    string
---@param inline_items mathlive.conceal.InlineItem[]
function M.build_row_projector(buf, row, line_text, inline_items)
  local projector = {
    buf = buf,
    row = row,
    line_text = line_text,
    inline_items = inline_items,
    extmarks = M.collect_extmarks(buf, row),
    ts_spans = M.collect_ts_spans(buf, row),
    cache_key = string.format("%d:%d", buf, row)
  }

  function projector:screen_width(start_col, end_col)
    local width = vim.fn.strdisplaywidth(line_text:sub(start_col + 1, end_col))
    local extmark_delta, covered = M.extmark_conceal_delta(start_col, end_col, self.extmarks)
    local ts_delta = M.ts_conceal_delta(start_col, end_col, covered, self.ts_spans)
    return width - extmark_delta - ts_delta
  end

  function projector:scroll_padding_before(leftcol)
    if leftcol <= 0 then
      return 0
    end

    local conceallevel = vim.wo.conceallevel
    local inline_at, covered, replacement_at = build_column_map(self.extmarks, self.ts_spans, conceallevel)
    local scroll_col = 0
    local padding = 0
    local last_end = 0

    local function consume(hidden, width)
      if width <= 0 or scroll_col >= leftcol then
        return scroll_col >= leftcol
      end

      local take = math.min(width, leftcol - scroll_col)
      if hidden then
        padding = padding + take
      end
      scroll_col = scroll_col + take
      return scroll_col >= leftcol
    end

    for _, item in ipairs(inline_items) do
      local p, range = item.placement, item.range
      local sc, ec = range[2], range[4]

      if last_end < sc then
        local done = false
        walk_gap(self.line_text, last_end, sc, inline_at, covered, replacement_at, conceallevel, function (
          hidden, width
        )
          done = consume(hidden, width)
          return done
        end)
        if done then
          return padding
        end
      end

      if consume(false, Util.pixels_to_cells(p.img.size).width) then
        return padding
      end

      if conceallevel == 0 then
        if consume(false, vim.fn.strdisplaywidth(self.line_text:sub(sc + 1, ec))) then
          return padding
        end
      else
        local replacement_width = conceal_replacement_width("", conceallevel)
        local hidden_width = math.max(0, (ec - sc) - replacement_width)
        if conceallevel == 1 and replacement_width > 0 then
          if consume(false, replacement_width) then
            return padding
          end
          if consume(true, hidden_width) then
            return padding
          end
        else
          if consume(true, hidden_width) then
            return padding
          end
          if replacement_width > 0 and consume(false, replacement_width) then
            return padding
          end
        end
      end

      last_end = ec
    end

    if last_end < #self.line_text then
      walk_gap(
        self.line_text,
        last_end,
        #self.line_text,
        inline_at,
        covered,
        replacement_at,
        conceallevel,
        function (hidden, width)
          if consume(hidden, width) then
            return true
          end
        end
      )
    end

    return padding
  end

  ---@cast projector mathlive.conceal.RowProjector
  return projector
end

return M

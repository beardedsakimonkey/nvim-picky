---All listed buffers, most recently used first. Buffers on screen in a window
---of the current tabpage have their name painted with `PickyBufVisible`.

local parsers = require("picky.parsers")

---@return table<number, true>
local function visible_bufs()
  local visible = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    visible[vim.api.nvim_win_get_buf(win)] = true
  end
  return visible
end

---Highlight the buffer's name in its display. `file_item` always emits a
---`name` field chunk; the `[No Name]` fallback has no display, so its bare
---`text` is materialized into one.
---@param item PickyItem
local function mark_visible(item)
  local display = item.display
  if type(display) ~= "table" then
    item.display = { { field = "text", hl = "PickyBufVisible" } }
    return
  end
  for _, chunk in ipairs(display) do
    if chunk.field == "name" then
      chunk.hl = "PickyBufVisible"
      return
    end
  end
end

---@return PickySource
return function()
  return {
    name = "Buffers",
    refresh = "once",
    start = function(_, ctx)
      local visible = visible_bufs()
      local bufs = vim.fn.getbufinfo({ buflisted = 1 })
      table.sort(bufs, function(a, b)
        return a.lastused > b.lastused
      end)
      local items = {}
      for _, buf in ipairs(bufs) do
        local item = buf.name ~= "" and parsers.file_item(buf.name) or { text = "[No Name]" }
        item.id = buf.bufnr
        item.bufnr = buf.bufnr
        if visible[buf.bufnr] then
          mark_visible(item)
        end
        items[#items + 1] = item
      end
      ctx.emit(items)
      ctx.finish()
    end,
  }
end

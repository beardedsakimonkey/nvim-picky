---All listed buffers, most recently used first.

local parsers = require("picky.parsers")

---@return PickySource
return function()
  return {
    name = "Buffers",
    refresh = "once",
    start = function(_, ctx)
      local bufs = vim.fn.getbufinfo({ buflisted = 1 })
      table.sort(bufs, function(a, b)
        return a.lastused > b.lastused
      end)
      local items = {}
      for _, buf in ipairs(bufs) do
        local item = buf.name ~= "" and parsers.file_item(buf.name) or { text = "[No Name]" }
        item.id = buf.bufnr
        item.bufnr = buf.bufnr
        items[#items + 1] = item
      end
      ctx.emit(items)
      ctx.finish()
    end,
  }
end

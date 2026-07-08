---All listed buffers, including the one that is current.

local parsers = require("picky.parsers")

---@return PickySource
return function()
  return {
    name = "Buffers",
    refresh = "once",
    bonus = require("picky.frecency").bonus,
    start = function(_, ctx)
      local items = {}
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[bufnr].buflisted then
          local name = vim.api.nvim_buf_get_name(bufnr)
          local item = name ~= "" and parsers.file_item(name) or { text = "[No Name]" }
          item.id = bufnr
          item.bufnr = bufnr
          items[#items + 1] = item
        end
      end
      ctx.emit(items)
      ctx.finish()
    end,
  }
end

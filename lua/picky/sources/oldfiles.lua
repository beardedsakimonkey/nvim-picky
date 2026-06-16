---Existing files from vim.v.oldfiles.

local parsers = require("picky.parsers")

---@param opts { limit: number? }?
---@return PickySource
return function(opts)
  opts = opts or {}
  return {
    name = "Oldfiles",
    refresh = "once",
    bonus = require("picky.frecency").bonus,
    start = function(_, ctx)
      local items = {}
      for _, path in ipairs(vim.v.oldfiles or {}) do
        if vim.uv.fs_stat(path) then
          local item = parsers.file_item(path)
          item.id = path
          items[#items + 1] = item
          if opts.limit and #items >= opts.limit then
            break
          end
        end
      end
      ctx.emit(items)
      ctx.finish()
    end,
  }
end

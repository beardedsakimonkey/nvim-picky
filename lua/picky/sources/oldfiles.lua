---Existing files from vim.v.oldfiles.

---@param opts { limit: number? }?
---@return PickySource
return function(opts)
  opts = opts or {}
  return {
    name = "Oldfiles",
    refresh = "once",
    start = function(_, ctx)
      local items = {}
      for _, path in ipairs(vim.v.oldfiles or {}) do
        if vim.uv.fs_stat(path) then
          items[#items + 1] = {
            id = path,
            text = vim.fn.fnamemodify(path, ":~:."),
            path = path,
          }
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

---Listed buffers, excluding the buffer that was current when the source was
---created (creation time matters: by the time the source starts, the picker's
---prompt buffer is current).

---@param opts { current: number? }?
---@return PickySource
return function(opts)
  opts = opts or {}
  local exclude = opts.current or vim.api.nvim_get_current_buf()
  return {
    name = "Buffers",
    refresh = "once",
    start = function(_, ctx)
      local items = {}
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[bufnr].buflisted and bufnr ~= exclude then
          local name = vim.api.nvim_buf_get_name(bufnr)
          items[#items + 1] = {
            id = bufnr,
            bufnr = bufnr,
            text = name ~= "" and vim.fn.fnamemodify(name, ":~:.") or "[No Name]",
            path = name ~= "" and name or nil,
          }
        end
      end
      ctx.emit(items)
      ctx.finish()
    end,
  }
end

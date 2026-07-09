---Help tags read from every doc/tags file on the runtime path.

---@param ctx PickySourceContext
local function emit_tags(ctx)
  local seen = {}
  local items = {}
  for _, tagfile in ipairs(vim.api.nvim_get_runtime_file("doc/tags", true)) do
    local f = io.open(tagfile)
    if f then
      for line in f:lines() do
        local tag = line:match("^([^\t]+)\t")
        if tag and not seen[tag] then
          seen[tag] = true
          items[#items + 1] = { id = tag, text = tag, tag = tag }
        end
      end
      f:close()
    end
  end
  ctx.emit(items)
  ctx.finish()
end

---@return PickySource
return function()
  return {
    name = "Help",
    refresh = "once",
    start = function(_, ctx)
      emit_tags(ctx)
    end,
  }
end

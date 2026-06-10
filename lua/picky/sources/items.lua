---Static item source: emits the given items once and finishes.

---@param items PickyItem[]?
---@return PickySource
return function(items)
  return {
    name = "Items",
    refresh = "once",
    start = function(_, ctx)
      ctx.emit(items or {})
      ctx.finish()
    end,
  }
end

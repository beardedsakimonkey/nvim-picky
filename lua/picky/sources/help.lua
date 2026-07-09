---Help tags, or live text search through runtime documentation.
---
---The default source reads every doc/tags file on the runtime path. With
---`live = true` the grep source searches the doc directories per query; emitted
---items carry `tag` (the doc file's basename, which `:help` accepts) plus
---`path`/`lnum` so opening jumps to the matched line.

local grep = require("picky.sources.grep")

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

---@class PickyHelpOpts
---@field live boolean?
---@field executable string? defaults to rg when available, otherwise grep (live only)
---@field debounce number?

---@param opts PickyHelpOpts?
---@return PickySource|PickyCommandSource
return function(opts)
  opts = opts or {}

  if not opts.live then
    return {
      name = "Help",
      refresh = "once",
      start = function(_, ctx)
        emit_tags(ctx)
      end,
    }
  end

  local doc_dirs = vim.api.nvim_get_runtime_file("doc", true)
  local source = grep({
    debounce = opts.debounce,
    executable = opts.executable,
    paths = doc_dirs,
    smart_case = true,
    colors = false,
    transform = function(item)
      item.tag = vim.fs.basename(item.path)
      item.display = {
        { field = "tag", hl = "Comment" },
        { text = "  " },
        { field = "text" },
      }
      item.fields = { "text", "tag" }
      return item
    end,
  })
  source.name = "Help"
  return source
end

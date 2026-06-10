---Help tags, or live text search through runtime documentation.
---
---The default source reads every doc/tags file on the runtime path. With
---`live = true` ripgrep searches the doc directories per query; emitted
---items carry `tag` (the doc file's basename, which `:help` accepts) plus
---`path`/`lnum` so opening jumps to the matched line.

local command = require("picky.sources.command")
local parsers = require("picky.parsers")

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
---@field executable string? defaults to "rg" (live only)
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
  return command({
    name = "Help",
    refresh = "query",
    debounce = opts.debounce,
    skip_empty_query = true,
    success_codes = { 0, 1 },
    command = function(ctx)
      local cmd = { opts.executable or "rg", "--vimgrep", "--no-heading", "--color=never", "--smart-case", "--" }
      cmd[#cmd + 1] = ctx.query
      vim.list_extend(cmd, doc_dirs)
      return cmd
    end,
    parse = function(line)
      local item = parsers.vimgrep(line)
      if not item then
        return nil
      end
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
end

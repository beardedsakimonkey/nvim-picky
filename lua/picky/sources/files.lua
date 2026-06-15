---File source backed by fd. With `live = true` the command restarts for
---each query, passing the query as a fixed string to fd; an empty query
---lists everything.

local command = require("picky.sources.command")
local parsers = require("picky.parsers")

---@class PickyFilesOpts
---@field cwd string?
---@field live boolean?
---@field hidden boolean?
---@field follow boolean?
---@field limit number?
---@field args string[]? extra fd arguments
---@field executable string? defaults to "fd"
---@field debounce number?
---@field colors boolean? show fd's coloring in the result window (default true)

---@param opts PickyFilesOpts?
---@return PickyCommandSource
return function(opts)
  opts = opts or {}
  local colors = opts.colors ~= false
  return command({
    name = "Files",
    cwd = opts.cwd,
    refresh = opts.live and "query" or "once",
    debounce = opts.debounce,
    command = function(ctx)
      local cmd = { opts.executable or "fd", colors and "--color=always" or "--color=never", "--type=file" }
      if opts.hidden then
        cmd[#cmd + 1] = "--hidden"
      end
      if opts.follow then
        cmd[#cmd + 1] = "--follow"
      end
      if opts.limit then
        cmd[#cmd + 1] = "--max-results=" .. opts.limit
      end
      vim.list_extend(cmd, opts.args or {})
      if opts.live then
        vim.list_extend(cmd, { "--fixed-strings", "--", ctx.query, "." })
      end
      return cmd
    end,
    -- With colors on, fd's LS_COLORS output already conveys structure, so the
    -- whole path stays one searchable text field carrying ANSI highlights.
    parse = colors and function(line)
      if line == "" then
        return nil
      end
      local text, highlights = require("picky.ansi").parse(line)
      if text == "" then
        return nil
      end
      local item = { id = text, text = text, path = text, highlights = highlights }
      return require("picky.icons").annotate(item, text)
    end or function(line)
      local item = parsers.path(line)
      return item and require("picky.icons").annotate(item, item.path) or nil
    end,
  })
end

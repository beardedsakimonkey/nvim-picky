---Structured ripgrep locations. With a fixed `pattern` the command runs
---once and the picker query filters the results; without one the source is
---live and the query itself is the ripgrep pattern.

local command = require("picky.sources.command")
local parsers = require("picky.parsers")

---@class PickyGrepOpts
---@field pattern string? fixed pattern; omit for live grep
---@field cwd string?
---@field paths string[]? defaults to { "." }
---@field fixed_strings boolean?
---@field smart_case boolean?
---@field args string[]? extra rg arguments
---@field executable string? defaults to "rg"
---@field debounce number?

---@param opts PickyGrepOpts?
---@return PickyCommandSource
return function(opts)
  opts = opts or {}
  local live = opts.pattern == nil
  return command({
    name = "Grep",
    cwd = opts.cwd,
    refresh = live and "query" or "once",
    debounce = opts.debounce,
    skip_empty_query = live,
    -- rg exits 1 when nothing matched; that is not an error.
    success_codes = { 0, 1 },
    command = function(ctx)
      local cmd = { opts.executable or "rg", "--vimgrep", "--no-heading", "--color=never" }
      if opts.fixed_strings then
        cmd[#cmd + 1] = "--fixed-strings"
      end
      if opts.smart_case then
        cmd[#cmd + 1] = "--smart-case"
      end
      vim.list_extend(cmd, opts.args or {})
      cmd[#cmd + 1] = "--"
      cmd[#cmd + 1] = live and ctx.query or opts.pattern
      vim.list_extend(cmd, opts.paths or { "." })
      return cmd
    end,
    parse = parsers.vimgrep,
  })
end

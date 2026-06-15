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
---@field colors boolean? show rg's match coloring in the result window (default true)

---Parse a colored `rg --vimgrep` line: keep the structured location fields and
---map rg's match color (the spans inside the text region) onto the rendered
---line. Path/line/col coloring is dropped so PickyDir dimming is preserved.
---@param line string
---@return PickyItem?
local function colored_vimgrep(line)
  local clean, spans = require("picky.ansi").parse(line)
  local item = parsers.vimgrep(clean)
  if not item then
    return nil
  end
  if #spans > 0 then
    -- `clean` is `path:lnum:col:text`; the rendered line is `path` .. "  " .. `text`.
    local text_start = #clean - #item.text
    local shift = #item.path + 2 - text_start
    local highlights = {}
    for _, s in ipairs(spans) do
      if s.from >= text_start then
        highlights[#highlights + 1] = { from = s.from + shift, to = s.to + shift, hl = s.hl }
      end
    end
    if #highlights > 0 then
      item.highlights = highlights
    end
  end
  return item
end

---@param opts PickyGrepOpts?
---@return PickyCommandSource
return function(opts)
  opts = opts or {}
  local live = opts.pattern == nil
  local colors = opts.colors ~= false
  return command({
    name = "Grep",
    cwd = opts.cwd,
    refresh = live and "query" or "once",
    debounce = opts.debounce,
    skip_empty_query = live,
    -- rg exits 1 when nothing matched; that is not an error.
    success_codes = { 0, 1 },
    command = function(ctx)
      local cmd =
        { opts.executable or "rg", "--vimgrep", "--no-heading", colors and "--color=always" or "--color=never" }
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
    parse = colors and colored_vimgrep or parsers.vimgrep,
  })
end

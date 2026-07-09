---Structured text-search locations. Ripgrep is preferred when available, with
---plain grep as a fallback. With a fixed `pattern` the command runs once and
---the picker query filters the results; without one the source is live and the
---query itself is the search pattern.

local command = require("picky.sources.command")
local parsers = require("picky.parsers")

---@class PickyGrepOpts
---@field pattern string? fixed pattern; omit for live grep
---@field cwd string?
---@field paths string[]? defaults to { "." }
---@field fixed_strings boolean?
---@field smart_case boolean?
---@field args string[]? extra arguments for the selected executable
---@field executable string? defaults to rg when available, otherwise grep
---@field debounce number?
---@field colors boolean? show match coloring in the result window (default true)
---@field transform fun(item: PickyItem, ctx: PickySourceContext): PickyItem? transform each parsed match

---@param executable string
---@return boolean
local function is_grep(executable)
  executable = vim.fs.basename(executable)
  return executable == "grep" or executable == "ggrep"
end

---@param item PickyItem
---@param clean string
---@param spans { from: number, to: number, hl: string }[]
local function apply_text_highlights(item, clean, spans)
  -- `clean` is a structured location; the rendered line is
  -- `path` .. "  " .. `text`. Drop prefix coloring so PickyDir dimming is
  -- preserved and move match spans onto the rendered text.
  local text_start = #clean - #item.text
  local shift = #item.path + 2 - text_start
  local highlights = {}
  for _, span in ipairs(spans) do
    if span.from >= text_start then
      highlights[#highlights + 1] = {
        from = span.from + shift,
        to = span.to + shift,
        hl = span.hl,
      }
    end
  end
  if #highlights > 0 then
    item.highlights = highlights
  end
end

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
    apply_text_highlights(item, clean, spans)
  end
  return item
end

---@param text string
---@param pattern string
---@return number?
local function fixed_string_col(text, pattern)
  local col = text:find(pattern, 1, true)
  if col then
    return col
  end
  -- This also handles an explicit `-i` in opts.args. Byte offsets are retained
  -- for the normal ASCII case; colored output remains authoritative otherwise.
  return vim.fn.tolower(text):find(vim.fn.tolower(pattern), 1, true)
end

---Parse grep's `path:lnum:text` output into the same item shape as vimgrep.
---grep does not report a match column, so use the first colored match (or a
---fixed-string lookup when colors are disabled) and conservatively fall back
---to the beginning of the line for uncolored regular expressions.
---@param line string
---@param pattern string
---@param fixed_strings boolean?
---@param colors boolean
---@return PickyItem?
local function parse_grep(line, pattern, fixed_strings, colors)
  local clean, spans = require("picky.ansi").parse(line)
  local path, lnum, text = clean:match("^(..-):(%d+):(.*)$")
  if not path then
    return nil
  end

  local text_start = #clean - #text
  local col
  for _, span in ipairs(spans) do
    if span.from >= text_start then
      col = span.from - text_start + 1
      break
    end
  end
  if not col and fixed_strings then
    col = fixed_string_col(text, pattern)
  end
  col = col or 1

  ---@type PickyItem
  local item = {
    id = ("%s:%s:%d"):format(path, lnum, col),
    path = path,
    lnum = tonumber(lnum),
    col = col,
    text = text,
    fields = { "path", "text" },
    display = {
      { field = "path", hl = "PickyDir" },
      { text = "  " },
      { field = "text" },
    },
  }
  if colors and #spans > 0 then
    apply_text_highlights(item, clean, spans)
  end
  return item
end

---@param opts PickyGrepOpts?
---@return PickyCommandSource
return function(opts)
  opts = opts or {}
  local live = opts.pattern == nil
  local colors = opts.colors ~= false
  local executable = opts.executable or (vim.fn.executable("rg") == 1 and "rg" or "grep")
  local use_grep = is_grep(executable)
  local parse = not use_grep and (colors and colored_vimgrep or parsers.vimgrep) or function(line, ctx)
    local pattern = live and ctx.query or assert(opts.pattern)
    return parse_grep(line, pattern, opts.fixed_strings, colors)
  end
  if opts.transform then
    local base_parse = parse
    parse = function(line, ctx)
      local item = base_parse(line, ctx)
      if item then
        return opts.transform(item, ctx)
      end
    end
  end
  return command({
    name = "Grep",
    cwd = opts.cwd,
    refresh = live and "query" or "once",
    debounce = opts.debounce,
    skip_empty_query = live,
    -- Both rg and grep exit 1 when nothing matched; that is not an error.
    success_codes = { 0, 1 },
    command = function(ctx)
      local pattern = live and ctx.query or assert(opts.pattern)
      if not use_grep then
        local cmd = { executable, "--vimgrep", "--no-heading", colors and "--color=always" or "--color=never" }
        if opts.fixed_strings then
          cmd[#cmd + 1] = "--fixed-strings"
        end
        if opts.smart_case then
          cmd[#cmd + 1] = "--smart-case"
        end
        vim.list_extend(cmd, opts.args or {})
        cmd[#cmd + 1] = "--"
        cmd[#cmd + 1] = pattern
        vim.list_extend(cmd, opts.paths or { "." })
        return cmd
      end

      -- -r/-n/-H/-I are supported by BSD, GNU, and BusyBox grep. Extended
      -- regular expressions are the closest portable match for rg's syntax.
      local cmd = { executable, "-r", "-n", "-H", "-I", opts.fixed_strings and "-F" or "-E" }
      if colors then
        cmd[#cmd + 1] = "--color=always"
      end
      if opts.smart_case and vim.fn.tolower(pattern) == pattern then
        cmd[#cmd + 1] = "-i"
      end
      vim.list_extend(cmd, opts.args or {})
      cmd[#cmd + 1] = "-e"
      cmd[#cmd + 1] = pattern
      cmd[#cmd + 1] = "--"
      vim.list_extend(cmd, opts.paths or { "." })
      return cmd
    end,
    parse = parse,
  })
end

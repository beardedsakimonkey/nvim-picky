---File source backed by fd, run once. fd lists the tree; picky filters and
---ranks locally, which lets frecency contribute to the order (and, on an empty
---query, drive it). Paths render relative to the cwd but carry their absolute
---form for opening and frecency lookups.

local command = require("picky.sources.command")

---Absolute, normalized path for an fd line relative to the search cwd.
---@param line string
---@param cwd string?
---@return string
local function absolute(line, cwd)
  return vim.fs.normalize(vim.fs.joinpath(cwd or assert(vim.uv.cwd()), line))
end

---@class PickyFilesOpts
---@field cwd string?
---@field hidden boolean?
---@field follow boolean?
---@field limit number?
---@field args string[]? extra fd arguments
---@field executable string? defaults to "fd"
---@field colors boolean? show fd's coloring in the result window (default true)
---@field frecency boolean? rank by frecency (default true)

---@param opts PickyFilesOpts?
---@return PickyCommandSource
return function(opts)
  opts = opts or {}
  local colors = opts.colors ~= false
  local source = command({
    name = "Files",
    cwd = opts.cwd,
    refresh = "once",
    command = function()
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
      return cmd
    end,
    -- With colors on, fd's LS_COLORS output already conveys structure, so the
    -- relative path stays one searchable text field carrying ANSI highlights;
    -- `path` holds the absolute form for opening and frecency.
    parse = colors and function(line, ctx)
      if line == "" then
        return nil
      end
      local text, highlights = require("picky.ansi").parse(line)
      if text == "" then
        return nil
      end
      local path = absolute(text, ctx and ctx.cwd)
      local item = { id = path, text = text, path = path, highlights = highlights }
      return require("picky.icons").annotate(item, text)
    end or function(line, ctx)
      if line == "" then
        return nil
      end
      local path = absolute(line, ctx and ctx.cwd)
      local item = { id = path, text = line, path = path }
      return require("picky.icons").annotate(item, line)
    end,
  })
  if opts.frecency ~= false then
    source.bonus = require("picky.frecency").bonus
  end
  return source
end

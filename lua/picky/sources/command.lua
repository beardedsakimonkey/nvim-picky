---Generic command source: runs an argument-array command and parses its
---output lines into items. All specialized command sources (files, grep,
---live help) are thin wrappers over this.

local process = require("picky.process")

---@class PickyCommandOpts
---@field command string[]|fun(ctx: PickySourceContext): string[]?
---@field parse (fun(line: string, ctx: PickySourceContext): PickyItem|PickyItem[]|nil)?
---@field name string?
---@field cwd string?
---@field env table<string, string>?
---@field refresh "once"|"query"?
---@field debounce number?
---@field success_codes number[]? exit codes treated as success, default { 0 }
---@field skip_empty_query boolean? finish without running when the query is empty
---@field ansi boolean? parse ANSI color codes in output into highlights (ignored when `parse` is set)

---@class PickyCommandSource : PickySource
---@field _opts PickyCommandOpts the options the source was built from; exposed for tests

---@param opts PickyCommandOpts
---@return PickyCommandSource
return function(opts)
  assert(opts and opts.command, "picky.sources.command: command is required")

  local source = {
    name = opts.name or "Command",
    cwd = opts.cwd,
    refresh = opts.refresh or "once",
    debounce = opts.debounce,
    -- Exposed for argv inspection in tests; not part of the source contract.
    _opts = opts,
  }

  local handle

  local function parse_line(line, ctx)
    if opts.parse then
      return opts.parse(line, ctx)
    end
    if opts.ansi then
      return require("picky.parsers").ansi(line)
    end
    if line ~= "" then
      return { text = line }
    end
  end

  function source:start(ctx)
    if opts.skip_empty_query and ctx.query == "" then
      ctx.finish()
      return
    end
    ---@type string[]?
    local cmd
    if type(opts.command) == "function" then
      cmd = opts.command(ctx)
    else
      cmd = opts.command --[[@as string[] ]]
    end
    if not cmd then
      ctx.finish()
      return
    end
    handle = process.run({
      cmd = cmd,
      cwd = ctx.cwd,
      env = opts.env,
      on_lines = function(lines)
        local items = {}
        for _, line in ipairs(lines) do
          local parsed = parse_line(line, ctx)
          if parsed then
            if parsed[1] ~= nil then
              vim.list_extend(items, parsed)
            elseif next(parsed) ~= nil then
              items[#items + 1] = parsed
            end
          end
        end
        if #items > 0 then
          ctx.emit(items)
        end
      end,
      on_exit = function(code, stderr)
        handle = nil
        if vim.tbl_contains(opts.success_codes or { 0 }, code) then
          ctx.finish()
        else
          local message = stderr:match("^%s*(.-)%s*$")
          if message == "" then
            message = ("%s exited with code %d"):format(cmd[1], code)
          end
          ctx.finish(message)
        end
      end,
    })
  end

  function source:stop()
    if handle then
      handle.kill()
      handle = nil
    end
  end

  return source
end

---vim.system() wrapper with line buffering and cancellation.
---
---Guarantees:
---  - complete lines are delivered in order via on_lines, batched per
---    event-loop tick;
---  - a final unterminated line is flushed before on_exit;
---  - spawn failures are reported through on_exit, never thrown;
---  - after kill() no further callbacks fire.

local M = {}

---@class PickyProcessOpts
---@field cmd string[] argument array; never a shell string
---@field cwd string?
---@field env table<string, string>?
---@field on_lines fun(lines: string[])
---@field on_exit fun(code: number, stderr: string)

---@class PickyProcessHandle
---@field kill fun()

---@param opts PickyProcessOpts
---@return PickyProcessHandle
function M.run(opts)
  local killed = false
  local partial = ""
  local pending = {}
  local flush_scheduled = false
  local stderr_chunks = {}

  local function flush()
    flush_scheduled = false
    if killed or #pending == 0 then
      return
    end
    local lines = pending
    pending = {}
    opts.on_lines(lines)
  end

  local function queue_flush()
    if not flush_scheduled then
      flush_scheduled = true
      vim.schedule(flush)
    end
  end

  local function on_stdout(err, data)
    if err or data == nil or killed then
      return
    end
    partial = partial .. data
    local lines = vim.split(partial, "\n", { plain = true })
    partial = table.remove(lines)
    if #lines > 0 then
      vim.list_extend(pending, lines)
      queue_flush()
    end
  end

  local function on_stderr(err, data)
    if not err and data ~= nil then
      stderr_chunks[#stderr_chunks + 1] = data
    end
  end

  local function on_exit(out)
    vim.schedule(function()
      if killed then
        return
      end
      if partial ~= "" then
        pending[#pending + 1] = partial
        partial = ""
      end
      flush()
      opts.on_exit(out.code, table.concat(stderr_chunks))
    end)
  end

  local ok, proc = pcall(vim.system, opts.cmd, {
    cwd = opts.cwd,
    env = opts.env,
    stdout = on_stdout,
    stderr = on_stderr,
  }, on_exit)

  if not ok then
    -- Spawn failure (ENOENT, bad cwd, ...). vim.system raised before any
    -- handles were created, so there is nothing to release.
    vim.schedule(function()
      if not killed then
        opts.on_exit(-1, tostring(proc))
      end
    end)
    return { kill = function() killed = true end }
  end

  return {
    kill = function()
      if killed then
        return
      end
      killed = true
      proc:kill("sigterm")
    end,
  }
end

return M

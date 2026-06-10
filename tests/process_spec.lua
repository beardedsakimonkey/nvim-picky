local t = require("helpers")
local process = require("picky.process")

local function collect(opts)
  local result = { lines = {}, exited = false }
  local handle = process.run({
    cmd = opts.cmd,
    cwd = opts.cwd,
    env = opts.env,
    on_lines = function(lines)
      vim.list_extend(result.lines, lines)
    end,
    on_exit = function(code, stderr)
      result.exited = true
      result.code = code
      result.stderr = stderr
    end,
  })
  result.handle = handle
  if opts.wait ~= false then
    t.wait(function()
      return result.exited
    end)
  end
  return result
end

t.describe("process", function()
  t.it("emits complete lines in order", function()
    local result = collect({ cmd = { "printf", "one\ntwo\nthree\n" } })
    t.eq({ "one", "two", "three" }, result.lines)
    t.eq(0, result.code)
  end)

  t.it("flushes a final unterminated line", function()
    local result = collect({ cmd = { "printf", "one\ntwo" } })
    t.eq({ "one", "two" }, result.lines)
  end)

  t.it("reports the exit code and stderr", function()
    local result = collect({ cmd = { "sh", "-c", "echo oops >&2; exit 3" } })
    t.eq(3, result.code)
    t.ok(result.stderr:find("oops"), "stderr should be captured")
    t.eq({}, result.lines)
  end)

  t.it("respects cwd", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local result = collect({ cmd = { "pwd" }, cwd = dir })
    t.ok(result.lines[1]:find(vim.fs.basename(dir), 1, true), "pwd should run in cwd")
  end)

  t.it("reports spawn failures through on_exit", function()
    local result = collect({ cmd = { "picky-definitely-not-a-command" } })
    t.ok(result.code ~= 0)
    t.ok(#result.stderr > 0, "spawn error message expected")
  end)

  t.it("suppresses callbacks after kill", function()
    local result = collect({ cmd = { "sleep", "5" }, wait = false })
    result.handle.kill()
    vim.wait(100)
    t.eq(false, result.exited)
    t.eq({}, result.lines)
  end)
end)

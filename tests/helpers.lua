---Minimal test framework for `nvim -l tests/run.lua`. No dependencies.

local M = {}

local queue = {}
local prefix = ""

function M.describe(name, fn)
  local saved = prefix
  prefix = prefix .. name .. " :: "
  fn()
  prefix = saved
end

function M.it(name, fn)
  queue[#queue + 1] = { name = prefix .. name, fn = fn }
end

function M.eq(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    error(
      ("%sexpected:\n%s\ngot:\n%s"):format(
        message and (message .. "\n") or "",
        vim.inspect(expected),
        vim.inspect(actual)
      ),
      2
    )
  end
end

function M.ok(condition, message)
  if not condition then
    error(message or "expected condition to be truthy", 2)
  end
end

---Pump the event loop until the predicate holds.
function M.wait(predicate, timeout)
  if not vim.wait(timeout or 2000, predicate, 10) then
    error("timed out waiting for condition", 2)
  end
end

---A scripted source for session tests. Captures every start context so
---tests can emit/finish manually, including from stale generations.
function M.fake_source(opts)
  opts = opts or {}
  local source = {
    name = "Fake",
    refresh = opts.refresh,
    debounce = opts.debounce,
    cwd = opts.cwd,
    started = 0,
    stopped = 0,
    contexts = {},
  }
  function source:start(ctx)
    self.started = self.started + 1
    self.contexts[#self.contexts + 1] = ctx
    if opts.on_start then
      opts.on_start(ctx, self.started)
    end
  end
  function source:stop()
    self.stopped = self.stopped + 1
  end
  return source
end

---@param filter string?
---@return boolean all_passed
function M.run(filter)
  local failures = {}
  local ran = 0
  for _, test in ipairs(queue) do
    if not filter or test.name:find(filter, 1, true) then
      ran = ran + 1
      local ok, err = xpcall(test.fn, debug.traceback)
      if not ok then
        failures[#failures + 1] = { name = test.name, err = err }
      end
    end
  end
  for _, failure in ipairs(failures) do
    io.write("FAIL  ", failure.name, "\n", failure.err, "\n\n")
  end
  io.write(("%d tests, %d failures\n"):format(ran, #failures))
  return #failures == 0
end

return M

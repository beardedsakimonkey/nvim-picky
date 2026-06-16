---@diagnostic disable: missing-fields, need-check-nil, missing-parameter
local t = require("helpers")
local sources = require("picky.sources")

---Drive a source manually and collect its output.
local function run_source(source, ctx_opts)
  local result = { items = {}, finished = false }
  local ctx = vim.tbl_extend("force", {
    query = "",
    cwd = assert(vim.uv.cwd()),
    emit = function(items)
      vim.list_extend(result.items, items)
    end,
    finish = function(err)
      result.finished = true
      result.error = err
    end,
  }, ctx_opts or {})
  source:start(ctx)
  return result
end

local function wait_finished(result)
  t.wait(function()
    return result.finished
  end)
end

t.describe("sources.items", function()
  t.it("emits the given items once and finishes", function()
    local items = { { id = "a", text = "a" }, { id = "b", text = "b" } }
    local result = run_source(sources.items(items))
    t.eq(true, result.finished)
    t.eq(items, result.items)
  end)
end)

t.describe("sources.command", function()
  t.it("parses lines into items with the default parser", function()
    local source = sources.command({ command = { "printf", "one\ntwo\n" } })
    local result = run_source(source)
    wait_finished(result)
    t.eq(nil, result.error)
    t.eq({ { text = "one" }, { text = "two" } }, result.items)
  end)

  t.it("supports command functions receiving the context", function()
    local source = sources.command({
      command = function(ctx)
        return { "printf", "%s\n", ctx.query }
      end,
      refresh = "query",
    })
    local result = run_source(source, { query = "hello" })
    wait_finished(result)
    t.eq({ { text = "hello" } }, result.items)
  end)

  t.it("lets parsers return one item, a list, or nil", function()
    local source = sources.command({
      command = { "printf", "one\nskip\ntwo\n" },
      parse = function(line)
        if line == "skip" then
          return nil
        elseif line == "two" then
          return { { text = "two" }, { text = "two-bis" } }
        end
        return { text = line }
      end,
    })
    local result = run_source(source)
    wait_finished(result)
    t.eq({ { text = "one" }, { text = "two" }, { text = "two-bis" } }, result.items)
  end)

  t.it("treats unexpected exit codes as errors with stderr", function()
    local source = sources.command({ command = { "sh", "-c", "echo broken >&2; exit 2" } })
    local result = run_source(source)
    wait_finished(result)
    t.eq("broken", result.error)
  end)

  t.it("accepts configured success codes", function()
    local source = sources.command({
      command = { "sh", "-c", "exit 1" },
      success_codes = { 0, 1 },
    })
    local result = run_source(source)
    wait_finished(result)
    t.eq(nil, result.error)
  end)

  t.it("skips empty queries when configured", function()
    local source = sources.command({
      command = { "printf", "never\n" },
      skip_empty_query = true,
      refresh = "query",
    })
    local result = run_source(source, { query = "" })
    t.eq(true, result.finished)
    t.eq({}, result.items)
  end)

  t.it("reports missing executables as source errors", function()
    local source = sources.command({ command = { "picky-no-such-tool" } })
    local result = run_source(source)
    wait_finished(result)
    t.ok(result.error ~= nil, "expected a spawn error")
  end)

  t.it("passes env to the command", function()
    local source = sources.command({
      command = { "sh", "-c", "echo $PICKY_TEST" },
      env = { PICKY_TEST = "from-env" },
    })
    local result = run_source(source)
    wait_finished(result)
    t.eq({ { text = "from-env" } }, result.items)
  end)
end)

t.describe("sources.files", function()
  t.it("builds the fd argument array", function()
    local source = sources.files({ colors = false, hidden = true, follow = true, limit = 10, args = { "--extra" } })
    local cmd = source._opts.command({ query = "", cwd = "." })
    t.eq({ "fd", "--color=never", "--type=file", "--hidden", "--follow", "--max-results=10", "--extra" }, cmd)
    t.eq("once", source.refresh)
  end)

  t.it("runs once and attaches a frecency bonus", function()
    local source = sources.files({ colors = false })
    t.eq("once", source.refresh)
    t.eq("function", type(source.bonus))
    local without = sources.files({ colors = false, frecency = false })
    t.eq(nil, without.bonus)
  end)

  t.it("colorizes output by default, keeping the relative text but absolute path", function()
    local source = sources.files()
    local cmd = source._opts.command({ query = "", cwd = "." })
    t.eq("--color=always", cmd[2])
    local item = assert(source._opts.parse("\27[1;34m" .. "lua" .. "\27[0m/init.lua", { cwd = "/work" }))
    t.eq("lua/init.lua", item.text)
    t.eq("/work/lua/init.lua", item.path)
    t.eq({ from = 0, to = 3, hl = item.highlights[1].hl }, item.highlights[1])
  end)
end)

t.describe("sources.grep", function()
  t.it("builds the rg argument array for a fixed pattern", function()
    local source = sources.grep({
      colors = false,
      pattern = "update_input",
      fixed_strings = true,
      smart_case = true,
      paths = { "lua" },
    })
    local cmd = source._opts.command({ query = "", cwd = "." })
    t.eq({
      "rg",
      "--vimgrep",
      "--no-heading",
      "--color=never",
      "--fixed-strings",
      "--smart-case",
      "--",
      "update_input",
      "lua",
    }, cmd)
    t.eq("once", source.refresh)
    t.eq({ 0, 1 }, source._opts.success_codes)
  end)

  t.it("greps the query when no pattern is given", function()
    local source = sources.grep()
    t.eq("query", source.refresh)
    t.eq(true, source._opts.skip_empty_query)
    local cmd = source._opts.command({ query = "needle", cwd = "." })
    t.eq("needle", cmd[#cmd - 1])
  end)

  t.it("colorizes matches by default, keeping the location fields", function()
    local source = sources.grep()
    local cmd = source._opts.command({ query = "x", cwd = "." })
    t.eq("--color=always", cmd[4])
    -- rg --vimgrep --color=always: path/line/col then a colored match in text.
    local line = "a.lua:12:5:before \27[1m\27[31mNEEDLE\27[0m after"
    local item = assert(source._opts.parse(line))
    t.eq("a.lua", item.path)
    t.eq(12, item.lnum)
    t.eq(5, item.col)
    t.eq("before NEEDLE after", item.text)
    -- Rendered line is `path` .. "  " .. `text`; "NEEDLE" starts after "before ".
    local match_col = #item.path + 2 + #"before "
    t.eq(1, #item.highlights)
    t.eq(match_col, item.highlights[1].from)
    t.eq(match_col + #"NEEDLE", item.highlights[1].to)
  end)
end)

t.describe("sources.buffers", function()
  t.it("lists listed buffers except the current one", function()
    local current = vim.api.nvim_get_current_buf()
    local listed = vim.fn.bufadd(vim.fn.tempname())
    vim.bo[listed].buflisted = true
    local unlisted = vim.api.nvim_create_buf(false, true)
    local source = sources.buffers()
    local result = run_source(source)
    t.eq(true, result.finished)
    local ids = vim.tbl_map(function(item)
      return item.bufnr
    end, result.items)
    t.ok(vim.tbl_contains(ids, listed), "listed buffer expected")
    t.ok(not vim.tbl_contains(ids, current), "current buffer must be excluded")
    t.ok(not vim.tbl_contains(ids, unlisted), "unlisted buffer must be excluded")
    vim.api.nvim_buf_delete(listed, { force = true })
    vim.api.nvim_buf_delete(unlisted, { force = true })
  end)
end)

t.describe("sources.oldfiles", function()
  t.it("keeps only existing files, in order, up to limit", function()
    local exists_a = vim.fn.tempname()
    local exists_b = vim.fn.tempname()
    vim.fn.writefile({}, exists_a)
    vim.fn.writefile({}, exists_b)
    vim.v.oldfiles = { exists_a, exists_a .. ".missing", exists_b }

    local all = run_source(sources.oldfiles())
    t.eq({ exists_a, exists_b }, vim.tbl_map(function(item)
      return item.path
    end, all.items))

    local limited = run_source(sources.oldfiles({ limit = 1 }))
    t.eq(1, #limited.items)

    vim.fn.delete(exists_a)
    vim.fn.delete(exists_b)
  end)
end)

t.describe("sources.help", function()
  t.it("emits help tags with a tag field", function()
    local result = run_source(sources.help())
    t.eq(true, result.finished)
    t.ok(#result.items > 100, "runtime help tags expected")
    local by_tag = {}
    for _, item in ipairs(result.items) do
      by_tag[item.tag] = item
    end
    t.ok(by_tag["help"], "the 'help' tag should exist")
    t.eq("help", by_tag["help"].text)
  end)

  t.it("decorates live matches with a doc-file tag", function()
    local source = sources.help({ live = true })
    t.eq("query", source.refresh)
    local item = assert(source._opts.parse("/runtime/doc/motion.txt:12:3:some text"))
    t.eq("motion.txt", item.tag)
    t.eq(12, item.lnum)
    t.eq({ "text", "tag" }, item.fields)
  end)
end)

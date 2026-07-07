---@diagnostic disable: missing-fields, need-check-nil, missing-parameter, duplicate-set-field
local t = require("helpers")
local config = require("picky.config")
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
  local function tree(paths)
    local template = vim.fs.joinpath(assert(vim.uv.os_tmpdir()), "picky-files-XXXXXX")
    local root = assert(vim.uv.fs_mkdtemp(template))
    for _, rel in ipairs(paths) do
      vim.fn.mkdir(vim.fs.dirname(vim.fs.joinpath(root, rel)), "p")
      assert(io.open(vim.fs.joinpath(root, rel), "w")):close()
    end
    return root
  end

  local function paths_of(items)
    local paths = vim.tbl_map(function(item)
      return item.path
    end, items)
    table.sort(paths)
    return paths
  end

  t.it("scans the tree into file items", function()
    local root = tree({ "a.lua", "sub/b.lua" })
    local result = run_source(sources.files(), { cwd = root })
    wait_finished(result)
    t.eq(nil, result.error)
    t.eq({ vim.fs.joinpath(root, "a.lua"), vim.fs.joinpath(root, "sub/b.lua") }, paths_of(result.items))
    for _, item in ipairs(result.items) do
      t.eq(item.path, item.id)
      t.eq("string", type(item.name))
      t.ok(vim.tbl_contains(item.fields, "name"), "expected file_item fields")
    end
  end)

  t.it("passes hidden and ignore through to the scanner", function()
    local root = tree({ "keep.txt", ".dot.txt", "vendor/x.js" })
    local default = run_source(sources.files(), { cwd = root })
    wait_finished(default)
    t.eq({ vim.fs.joinpath(root, "keep.txt"), vim.fs.joinpath(root, "vendor/x.js") }, paths_of(default.items))
    local tuned = run_source(sources.files({ hidden = true, ignore = { "vendor" } }), { cwd = root })
    wait_finished(tuned)
    t.eq({ vim.fs.joinpath(root, ".dot.txt"), vim.fs.joinpath(root, "keep.txt") }, paths_of(tuned.items))
  end)

  t.it("reports an unreadable root as a source error", function()
    local result = run_source(sources.files(), { cwd = "/picky-no-such-root" })
    wait_finished(result)
    t.ok(result.error ~= nil, "expected a scan error")
  end)

  t.it("runs once and attaches a frecency bonus", function()
    local source = sources.files()
    t.eq("once", source.refresh)
    t.eq("function", type(source.bonus))
    local without = sources.files({ frecency = false })
    t.eq(nil, without.bonus)
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

t.describe("sources.git_status", function()
  local function fg(group)
    local hl = vim.api.nvim_get_hl(0, { name = group })
    return hl.fg and ("#%06x"):format(hl.fg) or nil
  end

  t.it("builds the git status argument array", function()
    local source = sources.git_status({
      executable = "git-test",
      untracked = "normal",
      ignored = true,
      args = { "--renames" },
    })
    local cmd = source._opts.command({ query = "", cwd = "." })
    t.eq({
      "git-test",
      "-c",
      "status.relativePaths=true",
      "-c",
      "color.status=always",
      "-c",
      "core.quotePath=false",
      "status",
      "--untracked-files=normal",
      "--ignored",
      "--renames",
    }, cmd)
    t.eq("Git status", source.name)
    t.eq("once", source.refresh)
  end)

  t.it("parses staged entries from regular colorized git status", function()
    local source = sources.git_status()
    source._opts.parse("Changes to be committed:")
    local item = assert(source._opts.parse("\t\27[32mnew file:   lua/new.lua\27[m"))
    t.eq("lua/new.lua", item.path)
    t.eq("new file", item.status_text)
    t.eq("changes to be committed", item.section)
    t.eq("new file:   lua/new.lua", item.text)
    t.eq({ "text", "path", "status_text" }, item.fields)
    t.eq(1, #item.highlights)
    t.eq(0, item.highlights[1].from)
    t.eq(#item.text, item.highlights[1].to)
    t.eq("#00cd00", fg(item.highlights[1].hl))
  end)

  t.it("parses worktree and untracked entries with git's red ANSI span", function()
    local source = sources.git_status()
    source._opts.parse("Changes not staged for commit:")
    local changed = assert(source._opts.parse("\t\27[31mmodified:   lua/changed.lua\27[m"))
    t.eq("lua/changed.lua", changed.path)
    t.eq("modified", changed.status_text)
    t.eq("modified:   lua/changed.lua", changed.text)
    t.eq("#cd0000", fg(changed.highlights[1].hl))

    source._opts.parse("Untracked files:")
    local untracked = assert(source._opts.parse("\t\27[31mlua/new.lua\27[m"))
    t.eq("lua/new.lua", untracked.path)
    t.eq("untracked", untracked.status_text)
    t.eq("lua/new.lua", untracked.text)
    t.eq("#cd0000", fg(untracked.highlights[1].hl))

    local weird_name = assert(source._opts.parse("\t\27[31mfoo: bar -> baz\27[m"))
    t.eq("foo: bar -> baz", weird_name.path)
    t.eq("untracked", weird_name.status_text)
  end)

  t.it("opens the new path for renamed entries", function()
    local source = sources.git_status()
    local item = assert(source._opts.parse("\t\27[32mrenamed:    lua/old.lua -> lua/new.lua\27[m"))
    t.eq("lua/new.lua", item.path)
    t.eq("renamed", item.status_text)
    t.eq("renamed:    lua/old.lua -> lua/new.lua", item.path_display)
  end)

  t.it("parses ignored entries from their section and skips non-file lines", function()
    local source = sources.git_status()
    source._opts.parse("Ignored files:")
    local ignored = assert(source._opts.parse("\t\27[31mbuild/out.o\27[m"))
    t.eq("ignored", ignored.status_text)
    t.eq("build/out.o", ignored.path)
    t.eq(nil, source._opts.parse("not-a-status-line"))
    t.eq(nil, source._opts.parse("  (use \"git add <file>...\" to update what will be committed)"))
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

t.describe("sources.symbols", function()
  local function with_icons(enabled, fn)
    local saved_icons = config.options.icons
    config.options.icons = enabled
    local ok, err = pcall(fn)
    config.options.icons = saved_icons
    if not ok then
      error(err, 0)
    end
  end

  local function with_clients(clients, fn)
    local saved = vim.lsp.get_clients
    vim.lsp.get_clients = function()
      return clients
    end
    local ok, err = pcall(fn)
    vim.lsp.get_clients = saved
    if not ok then
      error(err, 0)
    end
  end

  ---A fake client whose request() records the call and answers synchronously
  ---(with `result`, an `error`, or never when `hang`).
  local function fake_client(opts)
    opts = opts or {}
    local client = {
      id = opts.id or 1,
      name = opts.name or "fake",
      offset_encoding = opts.encoding or "utf-16",
      requests = {},
      cancelled = {},
    }
    function client:request(method, params, handler)
      self.requests[#self.requests + 1] = { method = method, params = params }
      if opts.error then
        handler({ message = opts.error }, nil)
      elseif not opts.hang then
        handler(nil, opts.result or {})
      end
      return true, #self.requests
    end
    function client:cancel_request(id)
      self.cancelled[#self.cancelled + 1] = id
    end
    return client
  end

  local function scratch(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end

  local function range(lnum, col)
    return { start = { line = lnum, character = col }, ["end"] = { line = lnum, character = col } }
  end

  t.it("flattens hierarchical document symbols with containers", function()
    local buf = scratch({ "class Shape:", "  def area(self):", "    pass", "", "def main():" })
    local client = fake_client({
      result = {
        {
          name = "Shape",
          kind = 5, -- Class
          range = range(0, 0),
          selectionRange = range(0, 6),
          children = { { name = "area", kind = 6, range = range(1, 2), selectionRange = range(1, 6) } },
        },
        { name = "main", kind = 12, range = range(4, 0), selectionRange = range(4, 4) },
      },
    })
    with_clients({ client }, function()
      local source = sources.symbols({ bufnr = buf })
      t.eq("once", source.refresh)
      local result = run_source(source)
      t.eq(true, result.finished)
      t.eq(nil, result.error)
      t.eq("textDocument/documentSymbol", client.requests[1].method)
      t.eq(3, #result.items)
      local shape, area, main = result.items[1], result.items[2], result.items[3]
      t.eq({ "Shape", "Class", nil, buf, 1, 7 }, { shape.text, shape.kind, shape.container, shape.bufnr, shape.lnum, shape.col })
      t.eq({ { field = "kind_icon", hl = "PickyKind" }, { text = " " }, { field = "text" } }, main.display)
      t.eq("󰊕", main.kind_icon)
      t.eq({ "area", "Method", "Shape", 2, 7 }, { area.text, area.kind, area.container, area.lnum, area.col })
      t.eq({ "main", "Function", 5, 5 }, { main.text, main.kind, main.lnum, main.col })
    end)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  t.it("falls back to symbol kind labels when icons are disabled", function()
    local buf = scratch({ "local function main() end" })
    local client = fake_client({
      result = { { name = "main", kind = 12, range = range(0, 0), selectionRange = range(0, 15) } },
    })
    with_icons(false, function()
      with_clients({ client }, function()
        local result = run_source(sources.symbols({ bufnr = buf }))
        local item = result.items[1]
        t.eq("Function", item.kind)
        t.eq({
          { field = "kind", hl = "PickyKind" },
          { text = "  " },
          { field = "text" },
        }, item.display)
      end)
    end)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  t.it("maps SymbolInformation locations to path items", function()
    local buf = scratch({ "" })
    local client = fake_client({
      result = {
        {
          name = "answer",
          kind = 13, -- Variable
          containerName = "config",
          location = { uri = "file:///tmp/x.lua", range = range(9, 4) },
        },
      },
    })
    with_clients({ client }, function()
      local result = run_source(sources.symbols({ bufnr = buf }))
      local item = result.items[1]
      t.eq({ "/tmp/x.lua", 10, 5, "config" }, { item.path, item.lnum, item.col, item.container })
      t.eq(nil, item.bufnr)
    end)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  t.it("converts utf-16 symbol columns to byte columns", function()
    local buf = scratch({ "éé foo = 1" })
    local client = fake_client({
      result = { { name = "foo", kind = 13, range = range(0, 3), selectionRange = range(0, 3) } },
    })
    with_clients({ client }, function()
      local result = run_source(sources.symbols({ bufnr = buf }))
      -- character 3 (utf-16) lands after the two 2-byte é's and the space.
      t.eq(6, result.items[1].col)
    end)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  t.it("sends the query in workspace mode and emits path items", function()
    local cwd = assert(vim.uv.cwd())
    local client = fake_client({
      result = {
        {
          name = "needle_fn",
          kind = 12,
          location = { uri = vim.uri_from_fname(vim.fs.joinpath(cwd, "lua/a.lua")), range = range(3, 8) },
        },
      },
    })
    with_clients({ client }, function()
      local source = sources.symbols({ workspace = true })
      t.eq("query", source.refresh)
      local result = run_source(source, { query = "needle" })
      t.eq("workspace/symbol", client.requests[1].method)
      t.eq({ query = "needle" }, client.requests[1].params)
      local item = result.items[1]
      t.eq({ vim.fs.joinpath(cwd, "lua/a.lua"), "lua/a.lua", 4, 9 }, { item.path, item.rel, item.lnum, item.col })
    end)
  end)

  t.it("sends empty workspace queries", function()
    local cwd = assert(vim.uv.cwd())
    local client = fake_client({
      result = {
        {
          name = "initial_fn",
          kind = 12,
          location = { uri = vim.uri_from_fname(vim.fs.joinpath(cwd, "lua/initial.lua")), range = range(1, 2) },
        },
      },
    })
    with_clients({ client }, function()
      local result = run_source(sources.symbols({ workspace = true }), { query = "" })
      t.eq(true, result.finished)
      t.eq("workspace/symbol", client.requests[1].method)
      t.eq({ query = "" }, client.requests[1].params)
      t.eq("initial_fn", result.items[1].text)
    end)
  end)

  t.it("reports missing clients as a source error", function()
    with_clients({}, function()
      local result = run_source(sources.symbols())
      t.eq(true, result.finished)
      t.ok(result.error ~= nil, "expected a no-client error")
    end)
  end)

  t.it("succeeds when one of several clients fails, errors when all do", function()
    local buf = scratch({ "" })
    local good = fake_client({
      id = 1,
      result = { { name = "ok_fn", kind = 12, range = range(0, 0), selectionRange = range(0, 0) } },
    })
    local bad = fake_client({ id = 2, name = "broken", error = "boom" })
    with_clients({ good, bad }, function()
      local result = run_source(sources.symbols({ bufnr = buf }))
      t.eq(nil, result.error)
      t.eq("ok_fn", result.items[1].text)
    end)
    local bad2 = fake_client({ id = 3, name = "worse", error = "bang" })
    with_clients({ bad, bad2 }, function()
      local result = run_source(sources.symbols({ bufnr = buf }))
      t.ok(result.error:find("broken: boom", 1, true) and result.error:find("worse: bang", 1, true), result.error)
    end)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  t.it("cancels in-flight requests on stop", function()
    local buf = scratch({ "" })
    local client = fake_client({ hang = true })
    with_clients({ client }, function()
      local source = sources.symbols({ bufnr = buf })
      local result = run_source(source)
      t.eq(false, result.finished)
      source:stop()
      t.eq({ 1 }, client.cancelled)
    end)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  t.it("filters by kind but keeps children of dropped symbols", function()
    local buf = scratch({ "class Shape:", "  def area(self):" })
    local client = fake_client({
      result = {
        {
          name = "Shape",
          kind = 5,
          range = range(0, 0),
          selectionRange = range(0, 6),
          children = { { name = "area", kind = 6, range = range(1, 2), selectionRange = range(1, 6) } },
        },
      },
    })
    with_clients({ client }, function()
      local result = run_source(sources.symbols({ bufnr = buf, kinds = { "Method" } }))
      t.eq(1, #result.items)
      t.eq("area", result.items[1].text)
    end)
    vim.api.nvim_buf_delete(buf, { force = true })
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

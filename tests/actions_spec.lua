local t = require("helpers")
local actions = require("picky.actions")

local function make_ctx(targets, opts)
  opts = opts or {}
  local ctx = {
    current = targets[1],
    targets = targets,
    query = "",
    cwd = opts.cwd or assert(vim.uv.cwd()),
    closed = false,
    refreshed = false,
  }
  ctx.close = function()
    ctx.closed = true
  end
  ctx.refresh = function()
    ctx.refreshed = true
  end
  return ctx
end

local function tempfile(lines)
  local path = vim.fn.tempname()
  vim.fn.writefile(lines or { "one", "two", "three" }, path)
  return path
end

---Buffer names may resolve symlinks (macOS /var -> /private/var); compare
---real paths.
local function realpath(path)
  return vim.uv.fs_realpath(path) or path
end

t.describe("actions.edit", function()
  t.it("opens a path item and jumps to lnum/col", function()
    local path = tempfile()
    local ctx = make_ctx({ { path = path, lnum = 2, col = 3 } })
    actions.edit(ctx)
    t.eq(true, ctx.closed)
    t.eq(realpath(path), realpath(vim.api.nvim_buf_get_name(0)))
    t.eq({ 2, 2 }, vim.api.nvim_win_get_cursor(0))
  end)

  t.it("resolves relative paths against ctx.cwd", function()
    local dir = vim.fn.fnamemodify(vim.fn.tempname(), ":h")
    local path = tempfile()
    local relative = vim.fs.basename(path)
    actions.edit(make_ctx({ { path = relative } }, { cwd = dir }))
    t.eq(realpath(vim.fs.joinpath(dir, relative)), realpath(vim.api.nvim_buf_get_name(0)))
  end)

  t.it("opens a bufnr item", function()
    local bufnr = vim.api.nvim_create_buf(true, false)
    actions.edit(make_ctx({ { bufnr = bufnr } }))
    t.eq(bufnr, vim.api.nvim_get_current_buf())
  end)

  t.it("does nothing without targets", function()
    local ctx = make_ctx({})
    actions.edit(ctx)
    t.eq(false, ctx.closed)
  end)
end)

t.describe("actions.split", function()
  t.it("opens in a new window", function()
    local path = tempfile()
    local windows_before = #vim.api.nvim_list_wins()
    actions.split(make_ctx({ { path = path } }))
    t.eq(windows_before + 1, #vim.api.nvim_list_wins())
    t.eq(realpath(path), realpath(vim.api.nvim_buf_get_name(0)))
    vim.cmd("only")
  end)
end)

t.describe("actions.tabedit", function()
  t.it("opens in a new tab", function()
    local path = tempfile()
    local tabs_before = #vim.api.nvim_list_tabpages()
    actions.tabedit(make_ctx({ { path = path } }))
    t.eq(tabs_before + 1, #vim.api.nvim_list_tabpages())
    vim.cmd("tabclose")
  end)
end)

t.describe("actions on commit items", function()
  local function git(args, cwd)
    local cmd = vim.list_extend({ "git" }, args)
    local result = vim.system(cmd, {
      cwd = cwd,
      text = true,
      env = { GIT_CONFIG_GLOBAL = "/dev/null", GIT_CONFIG_SYSTEM = "/dev/null" },
    }):wait()
    t.eq(0, result.code, ("git %s failed: %s"):format(table.concat(args, " "), result.stderr or ""))
    return vim.trim(result.stdout or "")
  end

  ---One throwaway repo with a single commit, shared across the tests below.
  local repo_dir, head
  local function repo()
    if not repo_dir then
      repo_dir = vim.fn.tempname()
      vim.fn.mkdir(repo_dir, "p")
      git({ "init" }, repo_dir)
      git({
        "-c",
        "user.name=picky",
        "-c",
        "user.email=picky@example.com",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "--allow-empty",
        "-m",
        "picky test commit",
      }, repo_dir)
      head = git({ "rev-parse", "HEAD" }, repo_dir)
    end
    return repo_dir, head
  end

  t.it("edit shows the commit in a git-filetype scratch buffer", function()
    local cwd, hash = repo()
    local ctx = make_ctx({ { commit = hash } }, { cwd = cwd })
    actions.edit(ctx)
    t.eq(true, ctx.closed)
    local bufnr = vim.api.nvim_get_current_buf()
    t.eq("picky://git/" .. hash, vim.api.nvim_buf_get_name(bufnr))
    t.eq("git", vim.bo[bufnr].filetype)
    t.eq(false, vim.bo[bufnr].modifiable)
    local content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    t.ok(content:find(hash, 1, true) ~= nil, "buffer must contain the commit hash")
    t.ok(content:find("picky test commit", 1, true) ~= nil, "buffer must contain the subject")

    vim.cmd("enew")
    actions.edit(make_ctx({ { commit = hash } }, { cwd = cwd }))
    t.eq(bufnr, vim.api.nvim_get_current_buf(), "the same commit must reuse its buffer")
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  t.it("notifies and opens nothing for an unknown commit", function()
    local cwd = repo()
    local notified
    local saved = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(message)
      notified = message
    end
    local before = vim.api.nvim_get_current_buf()
    actions.edit(make_ctx({ { commit = "deadbeef" } }, { cwd = cwd }))
    vim.notify = saved
    t.eq(before, vim.api.nvim_get_current_buf())
    t.ok(notified and notified:find("deadbeef", 1, true) ~= nil, "expected a git show failure notification")
  end)
end)

t.describe("actions.quickfix", function()
  t.it("fills the quickfix list from location items", function()
    local path = tempfile()
    local ctx = make_ctx({
      { path = path, lnum = 2, col = 3, end_lnum = 2, end_col = 5, text = "match" },
      { path = path, lnum = 3, col = 1, text = "other" },
    })
    actions.quickfix(ctx)
    t.eq(true, ctx.closed)
    local list = vim.fn.getqflist()
    t.eq(2, #list)
    t.eq(2, list[1].lnum)
    t.eq(3, list[1].col)
    t.eq(2, list[1].end_lnum)
    t.eq(5, list[1].end_col)
    t.eq("match", list[1].text)
    t.eq("picky", vim.fn.getqflist({ title = 0 }).title)
    vim.cmd("cclose")
  end)

  t.it("does nothing without location data", function()
    local ctx = make_ctx({ { text = "no path" } })
    actions.quickfix(ctx)
    t.eq(false, ctx.closed)
  end)
end)

t.describe("actions.close", function()
  t.it("closes via the context", function()
    local ctx = make_ctx({})
    actions.close(ctx)
    t.eq(true, ctx.closed)
  end)
end)

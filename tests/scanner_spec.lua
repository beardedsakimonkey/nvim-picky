local t = require("helpers")
local scanner = require("picky.scanner")

local function write_file(path)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "w"))
  f:write("x")
  f:close()
end

---Create a temp tree from relative paths; entries ending in "/" become
---(possibly empty) directories, everything else a file. Returns the root.
local function tree(paths)
  local template = vim.fs.joinpath(assert(vim.uv.os_tmpdir()), "picky-scan-XXXXXX")
  local root = assert(vim.uv.fs_mkdtemp(template))
  for _, rel in ipairs(paths or {}) do
    if rel:sub(-1) == "/" then
      vim.fn.mkdir(vim.fs.joinpath(root, rel), "p")
    else
      write_file(vim.fs.joinpath(root, rel))
    end
  end
  return root
end

---Run a scan over `root` to completion; returns sorted paths plus the error.
local function scan(root, opts)
  local result = { paths = {}, finished = false }
  opts = opts or {}
  opts.cwd = root
  opts.on_paths = function(paths)
    vim.list_extend(result.paths, paths)
  end
  opts.on_done = function(err)
    result.finished = true
    result.error = err
  end
  scanner.scan(opts)
  t.wait(function()
    return result.finished
  end)
  table.sort(result.paths)
  return result
end

t.describe("scanner", function()
  t.it("lists files recursively as cwd-relative paths", function()
    local root = tree({ "a.txt", "sub/b.txt", "sub/deep/c.txt", "empty/" })
    local result = scan(root)
    t.eq(nil, result.error)
    t.eq({ "a.txt", "sub/b.txt", "sub/deep/c.txt" }, result.paths)
  end)

  t.it("skips dotfiles unless hidden is set, still pruning .git", function()
    local root = tree({ "a.txt", ".hidden.txt", ".dir/inside.txt", ".git/config" })
    t.eq({ "a.txt" }, scan(root).paths)
    t.eq({ ".dir/inside.txt", ".hidden.txt", "a.txt" }, scan(root, { hidden = true }).paths)
  end)

  t.it("matches slashless ignore patterns against names anywhere", function()
    local root = tree({ "keep.txt", "skip.log", "node_modules/x.js", "sub/node_modules/y.js" })
    local result = scan(root, { ignore = { "node_modules", "*.log" } })
    t.eq({ "keep.txt" }, result.paths)
  end)

  t.it("matches ignore patterns containing / against relative paths", function()
    local root = tree({ "keep.md", "docs/skip.md", "sub/docs/keep.md" })
    local result = scan(root, { ignore = { "docs/*.md" } })
    t.eq({ "keep.md", "sub/docs/keep.md" }, result.paths)
  end)

  t.it("stops at the limit", function()
    local root = tree({ "a.txt", "b.txt", "c.txt", "d.txt" })
    local result = scan(root, { limit = 2 })
    t.eq(nil, result.error)
    t.eq(2, #result.paths)
  end)

  t.it("ignores symlinks unless follow is set", function()
    local root = tree({ "real.txt", "target/inside.txt" })
    assert(vim.uv.fs_symlink(vim.fs.joinpath(root, "real.txt"), vim.fs.joinpath(root, "file_link")))
    assert(vim.uv.fs_symlink(vim.fs.joinpath(root, "target"), vim.fs.joinpath(root, "dir_link")))
    t.eq({ "real.txt", "target/inside.txt" }, scan(root).paths)
    t.eq(
      { "dir_link/inside.txt", "file_link", "real.txt", "target/inside.txt" },
      scan(root, { follow = true }).paths
    )
  end)

  t.it("prunes symlink cycles but lists parallel link routes", function()
    local root = tree({ "a/f.txt" })
    -- A cycle back to the root and a second, non-cyclic route into the same dir.
    assert(vim.uv.fs_symlink(root, vim.fs.joinpath(root, "a", "loop")))
    assert(vim.uv.fs_symlink(vim.fs.joinpath(root, "a"), vim.fs.joinpath(root, "again")))
    local result = scan(root, { follow = true })
    t.eq(nil, result.error)
    t.eq({ "a/f.txt", "again/f.txt" }, result.paths)
  end)

  t.it("fires no callbacks after cancel", function()
    local root = tree({ "a.txt", "sub/b.txt" })
    local fired = false
    local handle = scanner.scan({
      cwd = root,
      on_paths = function()
        fired = true
      end,
      on_done = function()
        fired = true
      end,
    })
    handle.cancel()
    vim.wait(100, function()
      return fired
    end, 10)
    t.eq(false, fired)
  end)

  t.it("reports an unreadable root through on_done", function()
    local result = scan("/picky-no-such-root")
    t.ok(result.error and result.error:find("ENOENT"), "expected an ENOENT error")
    t.eq({}, result.paths)
  end)
end)

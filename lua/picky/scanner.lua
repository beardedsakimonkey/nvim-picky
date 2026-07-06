---Async recursive file scanner on libuv, the local analogue of
---`picky.process` for listing a directory tree without an external command.
---
---Guarantees:
---  - cwd-relative file paths are delivered in discovery order via on_paths,
---    batched per event-loop tick;
---  - on_done fires exactly once, after the final batch;
---  - an unreadable root is reported through on_done, never thrown;
---    unreadable subdirectories are skipped;
---  - after cancel() no further callbacks fire.

local M = {}

-- Directory reads in flight at once. Each read is one threadpool round trip;
-- a little overlap hides that latency without fanning out unboundedly.
local CONCURRENCY = 4

---@class PickyScanOpts
---@field cwd string root directory to scan
---@field hidden boolean? include dotfiles (default false)
---@field follow boolean? follow symlinks (default false)
---@field limit number? stop after this many files
---@field ignore string[]? glob patterns to skip; matching directories are pruned. A pattern without `/` matches entry names anywhere in the tree, one with `/` matches cwd-relative paths (default { ".git", "node_modules" })
---@field on_paths fun(paths: string[]) batches of cwd-relative file paths
---@field on_done fun(error: string?)

---@class PickyScanHandle
---@field cancel fun()

---@param opts PickyScanOpts
---@return PickyScanHandle
function M.scan(opts)
  local root = opts.cwd
  local cancelled = false
  local done = false
  local pending = {}
  local flush_scheduled = false
  local found = 0

  -- Breadth-first directory queue, consumed by up to CONCURRENCY concurrent
  -- reads. Entries are { rel, chain } where rel is the cwd-relative path (""
  -- is the root) and chain — kept only when following symlinks — is a linked
  -- list of stat identities ({ key, parent }) for the directory and its
  -- ancestors. A link that resolves to an identity already on its chain is a
  -- cycle and is pruned; parallel links into the same directory are not
  -- ancestors of each other and scan normally, as fd -L does.
  local queue, next_dir = {}, 1
  local inflight = 0

  local function in_chain(key, chain)
    while chain do
      if chain.key == key then
        return true
      end
      chain = chain.parent
    end
    return false
  end

  local ignore = {}
  for _, pattern in ipairs(opts.ignore or { ".git", "node_modules" }) do
    ignore[#ignore + 1] = {
      glob = vim.glob.to_lpeg(pattern),
      on_path = pattern:find("/", 1, true) ~= nil,
    }
  end

  local function is_ignored(name, rel)
    for _, ig in ipairs(ignore) do
      if ig.glob:match(ig.on_path and rel or name) then
        return true
      end
    end
    return false
  end

  local function absolute(rel)
    return rel == "" and root or vim.fs.joinpath(root, rel)
  end

  local function flush()
    flush_scheduled = false
    if cancelled or #pending == 0 then
      return
    end
    local paths = pending
    pending = {}
    opts.on_paths(paths)
  end

  local function queue_flush()
    if not flush_scheduled then
      flush_scheduled = true
      vim.schedule(flush)
    end
  end

  ---Finish exactly once. Scheduled so it runs after any already-queued flush,
  ---then drains what that flush had not seen yet.
  local function finish(err)
    if done then
      return
    end
    done = true
    vim.schedule(function()
      if cancelled then
        return
      end
      flush()
      opts.on_done(err)
    end)
  end

  local function add_file(rel)
    if opts.limit and found >= opts.limit then
      return
    end
    found = found + 1
    pending[#pending + 1] = rel
    queue_flush()
    if opts.limit and found >= opts.limit then
      finish()
    end
  end

  local scan_dir

  local function pump()
    if cancelled or done then
      return
    end
    while inflight < CONCURRENCY and next_dir <= #queue do
      local entry = queue[next_dir]
      next_dir = next_dir + 1
      scan_dir(entry.rel, entry.chain)
    end
    if inflight == 0 and next_dir > #queue then
      finish()
    end
  end

  ---Enqueue a directory. When following symlinks every directory is stat'ed
  ---first to extend the identity chain and reject cycles.
  local function enqueue_dir(rel, chain)
    if not opts.follow then
      queue[#queue + 1] = { rel = rel }
      return
    end
    inflight = inflight + 1
    vim.uv.fs_stat(absolute(rel), function(err, stat)
      inflight = inflight - 1
      if cancelled or done then
        return
      end
      if not err and stat then
        local key = stat.dev .. ":" .. stat.ino
        if not in_chain(key, chain) then
          queue[#queue + 1] = { rel = rel, chain = { key = key, parent = chain } }
        end
      end
      pump()
    end)
  end

  ---Place an entry whose kind must come from stat: a symlink being followed,
  ---or an entry the filesystem reported without a type.
  local function stat_and_place(rel, chain)
    inflight = inflight + 1
    vim.uv.fs_stat(absolute(rel), function(err, stat)
      inflight = inflight - 1
      if cancelled or done then
        return
      end
      if not err and stat then
        if stat.type == "file" then
          add_file(rel)
        elseif stat.type == "directory" then
          local key = stat.dev .. ":" .. stat.ino
          if not in_chain(key, chain) then
            queue[#queue + 1] = { rel = rel, chain = opts.follow and { key = key, parent = chain } or nil }
          end
        end
      end
      pump()
    end)
  end

  local function on_entry(dir_rel, name, kind, chain)
    if not opts.hidden and name:sub(1, 1) == "." then
      return
    end
    local rel = dir_rel == "" and name or dir_rel .. "/" .. name
    if is_ignored(name, rel) then
      return
    end
    if kind == "file" then
      add_file(rel)
    elseif kind == "directory" then
      enqueue_dir(rel, chain)
    elseif kind == "link" then
      if opts.follow then
        stat_and_place(rel, chain)
      end
    elseif kind == nil then
      -- The filesystem gave no entry type; lstat to classify, keeping the
      -- follow semantics for what turns out to be a symlink.
      inflight = inflight + 1
      vim.uv.fs_lstat(absolute(rel), function(err, stat)
        inflight = inflight - 1
        if cancelled or done then
          return
        end
        if not err and stat then
          if stat.type == "file" then
            add_file(rel)
          elseif stat.type == "directory" then
            enqueue_dir(rel, chain)
          elseif stat.type == "link" and opts.follow then
            stat_and_place(rel, chain)
          end
        end
        pump()
      end)
    end
  end

  scan_dir = function(rel, chain)
    inflight = inflight + 1
    vim.uv.fs_scandir(absolute(rel), function(err, dir)
      inflight = inflight - 1
      if cancelled or done then
        return
      end
      if err or not dir then
        if rel == "" then
          finish(err or ("cannot read directory: " .. root))
          return
        end
      else
        while true do
          local name, kind = vim.uv.fs_scandir_next(dir)
          if not name then
            break
          end
          on_entry(rel, name, kind, chain)
          if done then
            return
          end
        end
      end
      pump()
    end)
  end

  if opts.follow then
    -- Seed the chain with the root's identity so a link straight back to the
    -- root is recognized as a cycle.
    inflight = 1
    vim.uv.fs_stat(root, function(_, stat)
      inflight = 0
      if cancelled then
        return
      end
      local chain = stat and { key = stat.dev .. ":" .. stat.ino } or nil
      queue[#queue + 1] = { rel = "", chain = chain }
      pump()
    end)
  else
    queue[1] = { rel = "" }
    pump()
  end

  return {
    cancel = function()
      cancelled = true
    end,
  }
end

return M

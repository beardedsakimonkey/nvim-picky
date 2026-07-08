---File source backed by picky's own libuv scanner, run once. The scanner
---lists the tree; picky filters and ranks locally. Items render as
---`filename dir` via parsers.file_item and carry the absolute path for
---opening.

local parsers = require("picky.parsers")
local scanner = require("picky.scanner")

---@class PickyFilesOpts
---@field cwd string?
---@field hidden boolean? include dotfiles (default false)
---@field follow boolean? follow symlinks (default false)
---@field limit number? safety cap on paths loaded; unset means load every file so local matching is exhaustive
---@field ignore string[]? glob patterns to skip; matching directories are pruned (default { ".git", "node_modules" })

---@param opts PickyFilesOpts?
---@return PickySource
return function(opts)
  opts = opts or {}
  local handle
  local source = {
    name = "Files",
    cwd = opts.cwd,
    refresh = "once",
  }

  function source:start(ctx)
    local root = vim.fs.normalize(ctx.cwd)
    handle = scanner.scan({
      cwd = root,
      hidden = opts.hidden,
      follow = opts.follow,
      limit = opts.limit,
      ignore = opts.ignore,
      on_paths = function(paths)
        local items = {}
        for i, rel in ipairs(paths) do
          local path = vim.fs.joinpath(root, rel)
          local item = parsers.file_item(path)
          item.id = path
          items[i] = item
        end
        ctx.emit(items)
      end,
      on_done = function(err)
        handle = nil
        ctx.finish(err)
      end,
    })
  end

  function source:stop()
    if handle then
      handle.cancel()
      handle = nil
    end
  end

  return source
end

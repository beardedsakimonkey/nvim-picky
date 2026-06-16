---picky: a small, dependency-free picker built around structured items.

require("picky.types")

local M = {}

M.sources = require("picky.sources")
M.parsers = require("picky.parsers")
M.actions = require("picky.actions")

---Establish global defaults. Optional; `open()` works without it.
---@param opts PickyConfigOpts?
function M.setup(opts)
  opts = opts or {}
  require("picky.config").setup(opts)
  require("picky.frecency").setup(require("picky.config").options.frecency)
end

---Open a picker. The only picker entry point: static and live behavior are
---properties of the source.
---@param opts { source: PickySource, window: table?, keymaps: table?, debounce: number? }
---@return PickySession
function M.open(opts)
  opts = opts or {}
  assert(type(opts.source) == "table", "picky.open: opts.source (table) is required")
  local config = require("picky.config").merge({
    window = opts.window,
    keymaps = opts.keymaps,
    debounce = opts.debounce,
  })
  local session = require("picky.session").new({ source = opts.source, config = config })
  local ui = require("picky.ui").new(session, config)
  ui:open()
  session:start()
  return session
end

return M

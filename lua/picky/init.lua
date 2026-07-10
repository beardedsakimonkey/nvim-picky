---picky: a small, dependency-free picker built around structured items.

require("picky.types")

---Picker-level overrides accepted by every convenience wrapper alongside its
---source options; they mean what they do in `open()`.
---@class PickyPickerOpts
---@field window table?
---@field preview table?
---@field keymaps table?
---@field debounce number?

---The `picky` module. The per-source convenience wrappers are generated in a
---loop below; these `@field` declarations give them their signatures without a
---hand-written function each.
---@class Picky
---@field sources PickySources
---@field parsers PickyParsers
---@field actions PickyActions
---@field setup fun(opts?: PickyConfigOpts)
---@field open fun(opts: { source: PickySource, window: table?, preview: table?, keymaps: table?, debounce: number? }): PickySession
---@field command fun(opts: PickyCommandOpts|PickyPickerOpts): PickySession
---@field files fun(opts?: PickyFilesOpts|PickyPickerOpts): PickySession
---@field buffers fun(opts?: PickyPickerOpts): PickySession
---@field git_status fun(opts?: PickyGitStatusOpts|PickyPickerOpts): PickySession
---@field git_log fun(opts?: PickyGitLogOpts|PickyPickerOpts): PickySession
---@field oldfiles fun(opts?: { limit: number? }|PickyPickerOpts): PickySession
---@field grep fun(opts?: PickyGrepOpts|PickyPickerOpts): PickySession
---@field symbols fun(opts?: PickySymbolsOpts|PickyPickerOpts): PickySession
---@field help fun(opts?: PickyPickerOpts): PickySession
---@field helpgrep fun(opts?: PickyHelpgrepOpts|PickyPickerOpts): PickySession
local M = {}

M.sources = require("picky.sources")
M.parsers = require("picky.parsers")
M.actions = require("picky.actions")

-- Convenience wrappers, one per built-in source (excluding `sources.items`).
-- Each is shorthand for `picky.open({ source = picky.sources.<name>(opts) })`.
-- The single opts table doubles as the source's own options and picker-level
-- overrides.
for name, build in pairs(M.sources) do
  if name ~= "items" then
    assert(M[name] == nil, "picky: source name shadows an existing field: " .. name)
    M[name] = function(opts)
      opts = opts or {}
      return M.open(vim.tbl_extend("force", opts, { source = build(opts) }))
    end
  end
end

---Establish global defaults. Optional; `open()` works without it.
---@param opts PickyConfigOpts?
function M.setup(opts)
  opts = opts or {}
  require("picky.config").setup(opts)
end

---Open a picker. The only picker entry point: static and live behavior are
---properties of the source.
---@param opts { source: PickySource, window: table?, preview: table?, keymaps: table?, debounce: number? }
---@return PickySession
function M.open(opts)
  opts = opts or {}
  assert(type(opts.source) == "table", "picky.open: opts.source (table) is required")
  local config = require("picky.config").merge({
    window = opts.window,
    preview = opts.preview,
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

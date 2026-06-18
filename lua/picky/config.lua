---Global defaults and per-instance option merging.

local M = {}

---@class PickyWindowConfig
---@field border string Border style passed to nvim_open_win (e.g. "single", "rounded", "none").
---@field width number Window width: a fraction of the editor width when <= 1, or an absolute number of columns when > 1.
---@field height number Window height: a fraction of the editor height when <= 1, or an absolute number of rows when > 1. When `shrink` is set this is the maximum height.
---@field shrink boolean Shrink the result window to fit the number of matches, up to `height`.
---@field input_position "top"|"bottom" Where the query input is placed relative to the result list.

---@class PickyWindowConfigOpts
---@field border string?
---@field width number?
---@field height number?
---@field shrink boolean?
---@field input_position "top"|"bottom"?

---@class PickyFrecencyConfig
---@field enabled boolean Track file reads/writes and rank file sources by frecency.
---@field path string? Path to the mpack store; defaults to stdpath("state")/picky/frecency.mpack.

---@class PickyFrecencyConfigOpts
---@field enabled boolean?
---@field path string?

---@class PickyConfig
---@field window PickyWindowConfig Floating window appearance.
---@field keymaps table<string, string> Maps keys (in the input buffer) to action names.
---@field debounce integer Milliseconds to wait after a keystroke before refiltering.
---@field match_batch integer Items matched per event-loop slice for local (non-live) sources.
---@field icons boolean Whether file-type icons are enabled when nvim-web-devicons is available.
---@field frecency PickyFrecencyConfig Frecency tracking for file sources.

---@class PickyConfigOpts
---@field window PickyWindowConfigOpts?
---@field keymaps table<string, string>?
---@field debounce integer?
---@field match_batch integer?
---@field icons boolean?
---@field frecency PickyFrecencyConfigOpts?

---@type PickyConfig
M.defaults = {
  window = {
    border = "rounded",
    width = 0.7,
    height = 0.8,
    shrink = false,
    input_position = "top",
  },
  keymaps = {
    ["<Esc>"] = "close",
    ["<CR>"] = "edit",
    ["<C-s>"] = "split",
    ["<C-v>"] = "vsplit",
    ["<C-t>"] = "tabedit",
    ["<C-q>"] = "quickfix",
    ["<C-j>"] = "next",
    ["<C-k>"] = "previous",
    ["<Down>"] = "next",
    ["<Up>"] = "previous",
    ["<ScrollWheelDown>"] = "scroll_down",
    ["<ScrollWheelUp>"] = "scroll_up",
    ["<PageDown>"] = "page_down",
    ["<PageUp>"] = "page_up",
    ["<C-f>"] = "page_down",
    ["<C-b>"] = "page_up",
    ["<Home>"] = "first",
    ["<End>"] = "last",
    ["<Tab>"] = "toggle",
    ["<C-a>"] = "toggle_all",
  },
  debounce = 40,
  -- Items a local source matches per event-loop slice. Matching streams across
  -- ticks above this, keeping the UI responsive and interruptible on a large
  -- list; a query change abandons the in-flight pass. Higher means fewer slices
  -- (less overhead) but longer per-slice pauses.
  match_batch = 4000,
  icons = true,
  frecency = {
    enabled = true,
    -- path defaults to stdpath("state")/picky/frecency.mpack inside the module.
  },
}

M.options = vim.deepcopy(M.defaults)

---Sets up global default options.
---@param opts PickyConfigOpts? Partial config overriding the defaults.
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

---Merge per-picker options over the global options.
---@param opts PickyConfigOpts? Partial config overriding the global options.
---@return PickyConfig
function M.merge(opts)
  return vim.tbl_deep_extend("force", vim.deepcopy(M.options), opts or {})
end

return M

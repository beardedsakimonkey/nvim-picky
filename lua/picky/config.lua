---Global defaults and per-instance option merging.

local M = {}

---@class PickyWindowConfig
---@field border string Border style passed to nvim_open_win (e.g. "single", "rounded", "none").
---@field width number Window width as a fraction of the editor width (0-1).
---@field height number Window height as a fraction of the editor height (0-1).
---@field input_position "top"|"bottom" Where the query input is placed relative to the result list.

---@class PickyConfig
---@field window PickyWindowConfig Floating window appearance.
---@field keymaps table<string, string> Maps keys (in the input buffer) to action names.
---@field debounce integer Milliseconds to wait after a keystroke before refiltering.

---@type PickyConfig
M.defaults = {
  window = {
    border = "single",
    width = 0.7,
    height = 0.8,
    input_position = "top",
  },
  keymaps = {
    ["<Esc>"] = "close",
    ["<CR>"] = "edit",
    ["<C-s>"] = "split",
    ["<C-l>"] = "vsplit",
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
}

M.options = vim.deepcopy(M.defaults)

---Sets up global default options.
---@param opts PickyConfig? Partial config overriding the defaults.
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

---Merge per-picker options over the global options.
---@param opts PickyConfig? Partial config overriding the global options.
---@return PickyConfig
function M.merge(opts)
  return vim.tbl_deep_extend("force", vim.deepcopy(M.options), opts or {})
end

return M

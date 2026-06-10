---Global defaults and per-picker option merging.

local M = {}

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
    ["<Tab>"] = "toggle",
    ["<C-a>"] = "toggle_all",
  },
  debounce = 40,
}

M.options = vim.deepcopy(M.defaults)

---@param opts table?
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

---Merge per-picker options over the global options.
---@param opts table?
---@return table
function M.merge(opts)
  return vim.tbl_deep_extend("force", vim.deepcopy(M.options), opts or {})
end

return M

local M = {}

---Group -> default link target.
M.links = {
  PickyMatch = "Special", -- matched characters
  PickyPrompt = "Comment", -- the "> " prompt symbol
  PickyCounter = "Comment", -- the n/total counter
  PickySelected = "Visual", -- multi-selected rows
  PickyError = "ErrorMsg", -- source error text
  PickyEmpty = "Comment", -- the "no results" placeholder
  PickyNormal = "NormalFloat", -- result/prompt window text and background
  PickyBorder = "FloatBorder", -- result/prompt window border
  PickyDir = "Comment", -- dimmed directory / path context
  PickyKind = "Type", -- symbol kind glyphs
  PickyGitHash = "Identifier", -- commit hashes
}

---Register the default links. Exposed for testing.
function M.setup()
  for group, link in pairs(M.links) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

M.setup()

return M

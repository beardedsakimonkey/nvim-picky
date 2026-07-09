---Live text search through runtime documentation. Uses the grep source for
---query execution and parsing, then decorates matches so normal actions open
---the corresponding help document at the matched line.

local grep = require("picky.sources.grep")

---@class PickyHelpgrepOpts
---@field executable string? defaults to rg when available, otherwise grep
---@field debounce number?

---@param opts PickyHelpgrepOpts?
---@return PickyCommandSource
return function(opts)
  opts = opts or {}
  local source = grep({
    debounce = opts.debounce,
    executable = opts.executable,
    paths = vim.api.nvim_get_runtime_file("doc", true),
    smart_case = true,
    colors = false,
    transform = function(item)
      item.tag = vim.fs.basename(item.path)
      item.display = {
        { field = "tag", hl = "Comment" },
        { text = "  " },
        { field = "text" },
      }
      item.fields = { "text", "tag" }
      return item
    end,
  })
  source.name = "Helpgrep"
  return source
end

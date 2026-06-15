local t = require("helpers")
local highlights = require("picky.highlights")

t.describe("highlights", function()
  t.it("registers every group as a default link", function()
    for group, link in pairs(highlights.links) do
      local hl = vim.api.nvim_get_hl(0, { name = group })
      t.eq(link, hl.link)
    end
  end)

  t.it("lets a user override a group without losing the default link", function()
    vim.api.nvim_set_hl(0, "PickyNormal", { fg = "#ff0000" })
    highlights.setup()
    -- A non-default user definition must survive re-registration.
    t.eq(nil, vim.api.nvim_get_hl(0, { name = "PickyNormal" }).link)
    -- Untouched groups keep their default link.
    t.eq("FloatBorder", vim.api.nvim_get_hl(0, { name = "PickyBorder" }).link)
    -- Restore the default so later tests see a clean slate.
    vim.api.nvim_set_hl(0, "PickyNormal", { link = highlights.links.PickyNormal })
  end)
end)

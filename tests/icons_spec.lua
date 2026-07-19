local t = require("helpers")
local config = require("picky.config")
local icons = require("picky.icons")

-- A devicons-like stub. The glyph is multi-byte to exercise the offset math.
local GLYPH = "λ"
local fake = {
  get_icon = function()
    return GLYPH, "DevIconLua"
  end,
}

local function with_provider(provider, enabled, fn)
  local saved_icons = config.options.icons
  icons._set_provider(provider)
  config.options.icons = enabled
  local ok, err = pcall(fn)
  config.options.icons = saved_icons
  icons._set_provider(nil)
  if not ok then
    error(err, 0)
  end
end

t.describe("icons.annotate", function()
  t.it("prepends a highlighted icon chunk", function()
    with_provider(fake, true, function()
      local item = icons.annotate({
        text = "main.lua",
        name = "main.lua",
        display = { { field = "name" } },
      })
      t.eq({
        { text = GLYPH, hl = "DevIconLua" },
        { text = " " },
        { field = "name" },
      }, item.display)
    end)
  end)

  t.it("materializes an implicit text display", function()
    with_provider(fake, true, function()
      local item = icons.annotate({ text = "main.lua", path = "main.lua" })
      t.eq({
        { text = GLYPH, hl = "DevIconLua" },
        { text = " " },
        { field = "text" },
      }, item.display)
    end)
  end)

  t.it("uses a directory icon instead of the provider's file fallback", function()
    local calls = 0
    local provider = {
      get_icon = function()
        calls = calls + 1
        return GLYPH, "DevIconLua"
      end,
    }
    with_provider(provider, true, function()
      local item = icons.annotate({
        text = "project",
        display = { { field = "text" } },
      }, "project", "directory")
      t.eq({
        { text = "", hl = "Directory" },
        { text = " " },
        { field = "text" },
      }, item.display)
      t.eq(0, calls)
    end)
  end)

  t.it("shifts line-relative highlights past the icon prefix", function()
    with_provider(fake, true, function()
      local item = icons.annotate({
        text = "main.lua",
        path = "main.lua",
        highlights = { { from = 0, to = 4, hl = "String" } },
      })
      local shift = #GLYPH + 1
      t.eq({ { from = shift, to = 4 + shift, hl = "String" } }, item.highlights)
    end)
  end)

  t.it("is a no-op when icons are inactive", function()
    with_provider(fake, false, function()
      local item = icons.annotate({ text = "main.lua", display = { { field = "text" } } })
      t.eq({ { field = "text" } }, item.display)
    end)
  end)

  t.it("leaves an opaque string display untouched", function()
    local calls = 0
    local provider = {
      get_icon = function()
        calls = calls + 1
        return GLYPH, "DevIconLua"
      end,
    }
    with_provider(provider, true, function()
      local item = icons.annotate({ text = "main.lua", path = "main.lua", display = "main.lua" })
      t.eq("main.lua", item.display)
      t.eq(0, calls)
    end)
  end)
end)

local t = require("helpers")
local picky = require("picky")

t.describe("convenience wrappers", function()
  t.it("exposes a top-level shortcut for every built-in source but items", function()
    for name in pairs(picky.sources) do
      if name == "items" then
        t.eq("nil", type(picky[name]), "items must not get a shortcut")
      else
        t.eq("function", type(picky[name]), name .. " shortcut missing")
      end
    end
  end)

  t.it("builds the matching source and returns a session", function()
    local session = picky.buffers()
    t.eq("Buffers", session.source.name)
    t.eq("function", type(session.close))
    session:close()
  end)

  t.it("forwards source options to the source constructor", function()
    -- The source's name confirms the right constructor ran with our opts.
    local session = picky.oldfiles({ limit = 1 })
    t.eq("Oldfiles", session.source.name)
    session:close()
  end)

  t.it("forwards picker-level overrides to open", function()
    local session = picky.buffers({
      keymaps = { ["<C-x>"] = "close" },
      window = { width = 0.5 },
    })
    t.eq("close", session.config.keymaps["<C-x>"])
    t.eq(0.5, session.config.window.width)
    session:close()
  end)

  t.it("does not mutate the caller's opts table", function()
    local opts = { limit = 1 }
    local session = picky.oldfiles(opts)
    t.eq({ limit = 1 }, opts)
    session:close()
  end)
end)

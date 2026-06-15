local t = require("helpers")
local ansi = require("picky.ansi")

---Resolved foreground (gui) of a highlight group, as #rrggbb.
local function fg(group)
  local hl = vim.api.nvim_get_hl(0, { name = group })
  return hl.fg and ("#%06x"):format(hl.fg) or nil
end

t.describe("ansi.parse", function()
  t.it("returns plain lines untouched with no spans", function()
    local text, spans = ansi.parse("lua/picky/init.lua")
    t.eq("lua/picky/init.lua", text)
    t.eq({}, spans)
  end)

  t.it("strips codes and reports a span over the colored run", function()
    local text, spans = ansi.parse("a\27[31mred\27[0mb")
    t.eq("ared", text:sub(1, 4))
    t.eq("aredb", text)
    t.eq(1, #spans)
    t.eq(1, spans[1].from)
    t.eq(4, spans[1].to)
    t.eq("#cd0000", fg(spans[1].hl))
  end)

  t.it("honors g:terminal_color overrides for the base palette", function()
    local saved = vim.g.terminal_color_1
    vim.g.terminal_color_1 = "#abcdef"
    -- A fresh state key for this color avoids reusing a cached default group.
    local _, spans = ansi.parse("\27[31m\27[1mx\27[0m")
    t.eq("#abcdef", fg(spans[1].hl))
    vim.g.terminal_color_1 = saved
  end)

  t.it("supports 256-color and truecolor foregrounds", function()
    local _, cube = ansi.parse("\27[38;5;196mx\27[0m")
    t.eq("#ff0000", fg(cube[1].hl))
    local _, truec = ansi.parse("\27[38;2;18;52;86mx\27[0m")
    t.eq("#123456", fg(truec[1].hl))
  end)

  t.it("captures bold, italic and underline attributes", function()
    local _, spans = ansi.parse("\27[1;3;4mx\27[0m")
    local hl = vim.api.nvim_get_hl(0, { name = spans[1].hl })
    t.ok(hl.bold, "bold expected")
    t.ok(hl.italic, "italic expected")
    t.ok(hl.underline, "underline expected")
  end)

  t.it("applies partial resets (39 clears fg, 22 clears bold)", function()
    -- bold+red, then drop the color but keep bold for the second run.
    local text, spans = ansi.parse("\27[1;31ma\27[39mb\27[0m")
    t.eq("ab", text)
    t.eq(2, #spans)
    t.ok(fg(spans[1].hl) ~= nil, "first run keeps a color")
    t.eq(nil, fg(spans[2].hl))
    local second = vim.api.nvim_get_hl(0, { name = spans[2].hl })
    t.ok(second.bold, "bold survives the color reset")
  end)

  t.it("maps reverse video to the reverse attribute", function()
    local _, spans = ansi.parse("\27[7mx\27[0m")
    local hl = vim.api.nvim_get_hl(0, { name = spans[1].hl })
    t.ok(hl.reverse, "reverse expected")
  end)

  t.it("strips unsupported CSI and OSC sequences", function()
    local text, spans = ansi.parse("a\27[2Kb\27]0;title\7c")
    t.eq("abc", text)
    t.eq({}, spans)
  end)

  t.it("closes an unterminated colored run at end of line", function()
    local text, spans = ansi.parse("\27[32mgreen")
    t.eq("green", text)
    t.eq(1, #spans)
    t.eq(0, spans[1].from)
    t.eq(5, spans[1].to)
  end)
end)

local t = require("helpers")
local picky = require("picky")

local function floating_wins()
  local out = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      out[#out + 1] = win
    end
  end
  return out
end

---Find the picker's result buffer: the floating, non-focusable window.
local function results_win()
  for _, win in ipairs(floating_wins()) do
    if not vim.api.nvim_win_get_config(win).focusable then
      return win
    end
  end
  error("no result window found")
end

local function result_lines()
  local buf = vim.api.nvim_win_get_buf(results_win())
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function result_height()
  return vim.api.nvim_win_get_height(results_win())
end

local function set_prompt(text)
  vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, -1, false, { text })
end

local function prompt_counter()
  local buf = vim.api.nvim_get_current_buf()
  local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
  for _, mark in ipairs(marks) do
    local virt_text = mark[4].virt_text
    if virt_text and virt_text[1] and virt_text[1][2] == "PickyCounter" then
      return virt_text[1][1]
    end
  end
  error("no prompt counter found")
end

local function open_static(items, opts)
  return picky.open(vim.tbl_extend("force", {
    source = picky.sources.items(items),
  }, opts or {}))
end

t.describe("ui", function()
  t.it("opens a prompt window and a result window", function()
    local before = #floating_wins()
    local session = open_static({ { id = 1, text = "one" } })
    t.eq(before + 2, #floating_wins())
    t.eq(true, vim.api.nvim_win_get_config(vim.api.nvim_get_current_win()).relative ~= "")
    t.eq({ "one" }, result_lines())
    session:close()
    t.eq(before, #floating_wins())
  end)

  t.it("formats prompt counter numbers with commas", function()
    local items = {}
    for i = 1, 1234 do
      items[i] = { id = i, text = "item " .. i }
    end
    local session = open_static(items)
    t.eq("1/1,234", prompt_counter())
    session:toggle_all()
    t.eq("(1,234) 1/1,234", prompt_counter())
    session:close()
  end)

  t.it("puts the loading ellipsis after the result count", function()
    local source = t.fake_source()
    local session = picky.open({ source = source })
    source.contexts[1].emit({ { id = 1, text = "one" }, { id = 2, text = "two" } })
    t.eq("1/2…", prompt_counter())
    source.contexts[1].finish()
    t.eq("1/2", prompt_counter())
    session:close()
  end)

  t.it("filters as the prompt changes", function()
    local session = open_static({
      { id = 1, text = "alpha" },
      { id = 2, text = "beta" },
    })
    set_prompt("bet")
    t.wait(function()
      return session.query == "bet"
    end)
    t.eq({ "beta" }, result_lines())
    set_prompt("")
    t.wait(function()
      return session.query == ""
    end)
    t.eq({ "alpha", "beta" }, result_lines())
    session:close()
  end)

  t.it("renders display chunks with field and chunk highlights", function()
    local session = open_static({
      {
        id = 1,
        name = "main.lua",
        path = "lua/main.lua",
        fields = { "name", "path" },
        display = {
          { field = "name" },
          { text = "  " },
          { field = "path", hl = "Comment" },
        },
      },
    })
    t.eq({ "main.lua  lua/main.lua" }, result_lines())

    set_prompt("'main.lua")
    t.wait(function()
      return session.query == "'main.lua"
    end)
    local buf = vim.api.nvim_win_get_buf(results_win())
    local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
    local prio = {}
    for _, mark in ipairs(marks) do
      prio[mark[4].hl_group or ""] = mark[4].priority
    end
    t.ok(prio.Comment, "chunk highlight expected")
    t.ok(prio.PickyMatch, "match highlight expected")
    -- Match highlights must draw on top of a chunk's base highlight.
    t.ok(prio.PickyMatch > prio.Comment, "match must outrank chunk highlight")
    session:close()
  end)

  t.it("renders a highlight on a literal chunk", function()
    local session = open_static({
      {
        id = 1,
        text = "main.lua",
        display = {
          { text = "λ", hl = "DevIconLua" },
          { text = " " },
          { field = "text" },
        },
      },
    })
    t.eq({ "λ main.lua" }, result_lines())
    local buf = vim.api.nvim_win_get_buf(results_win())
    local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
    local found = false
    for _, mark in ipairs(marks) do
      if mark[4].hl_group == "DevIconLua" then
        found = true
      end
    end
    t.ok(found, "literal chunk highlight expected")
    session:close()
  end)

  t.it("paints item highlights below match highlights", function()
    local session = open_static({
      { id = 1, text = "abc", highlights = { { from = 0, to = 3, hl = "String" } } },
    })
    set_prompt("a")
    t.wait(function()
      return session.query == "a"
    end)
    local buf = vim.api.nvim_win_get_buf(results_win())
    local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
    local prio = {}
    for _, mark in ipairs(marks) do
      prio[mark[4].hl_group or ""] = mark[4].priority
    end
    t.ok(prio.String, "item highlight expected")
    t.ok(prio.PickyMatch, "match highlight expected")
    t.ok(prio.PickyMatch > prio.String, "match must outrank item highlight")
    session:close()
  end)

  t.it("shows an empty state", function()
    local session = open_static({ { id = 1, text = "one" } })
    set_prompt("nomatch")
    t.wait(function()
      return session.query == "nomatch"
    end)
    t.eq({ "" }, result_lines())
    session:close()
  end)

  t.it("shrinks the result window to fit matches when window.shrink is set", function()
    local session = open_static({
      { id = 1, text = "alpha" },
      { id = 2, text = "beta" },
      { id = 3, text = "gamma" },
      { id = 4, text = "delta" },
      { id = 5, text = "epsilon" },
    }, { window = { shrink = true, height = 8 } })
    -- height 8, rounded border (2 rows of padding): max result rows = 8 - 1 - 4 = 3.
    t.eq(3, result_height())
    -- The result window keeps its border across resizes.
    t.ok(type(vim.api.nvim_win_get_config(results_win()).border) == "table", "border kept")

    set_prompt("alpha")
    t.wait(function()
      return session.query == "alpha"
    end)
    t.eq(1, result_height())

    set_prompt("zzz")
    t.wait(function()
      return session.query == "zzz"
    end)
    t.eq(1, result_height())

    set_prompt("")
    t.wait(function()
      return session.query == ""
    end)
    t.eq(3, result_height())
    session:close()
  end)

  t.it("keeps the prompt anchored when shrinking with bottom input", function()
    local session = open_static({
      { id = 1, text = "alpha" },
      { id = 2, text = "beta" },
      { id = 3, text = "gamma" },
    }, { window = { shrink = true, height = 8, input_position = "bottom" } })
    local prompt_win = vim.api.nvim_get_current_win()
    local prompt_row = vim.api.nvim_win_get_config(prompt_win).row
    local results_row = vim.api.nvim_win_get_config(results_win()).row

    set_prompt("alpha")
    t.wait(function()
      return session.query == "alpha"
    end)
    t.eq(1, result_height())
    -- The prompt stays put; the result window's top edge drops toward it.
    t.eq(prompt_row, vim.api.nvim_win_get_config(prompt_win).row)
    t.ok(vim.api.nvim_win_get_config(results_win()).row > results_row, "results moved down")
    session:close()
  end)

  t.it("keeps the full height when window.shrink is unset", function()
    local session = open_static({ { id = 1, text = "one" } }, { window = { height = 8 } })
    t.eq(3, result_height())
    session:close()
  end)

  t.it("runs keymap actions against the session", function()
    local hit = {}
    local session = open_static({ { id = 1, text = "one" }, { id = 2, text = "two" } }, {
      keymaps = {
        ["<C-x>"] = function(ctx)
          hit.targets = ctx.targets
          ctx.close()
        end,
      },
    })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-x>", true, false, true), "x", false)
    t.eq(1, hit.targets[1].id)
    t.eq(true, session.closed)
  end)

  t.it("closes when the source window closes", function()
    local session = open_static({ { id = 1, text = "one" } })
    vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
    t.wait(function()
      return session.closed
    end)
    t.eq(0, #floating_wins())
  end)

  t.it("cleans up buffers on close", function()
    local buffers_before = #vim.api.nvim_list_bufs()
    local session = open_static({ { id = 1, text = "one" } })
    session:close()
    t.eq(buffers_before, #vim.api.nvim_list_bufs())
  end)
end)

local t = require("helpers")
local picky = require("picky")

-- Headless nvim is 80x24 and the default picker width leaves the preview pane
-- under its minimum width, so every preview test opts into an explicit layout.
local defaults = {
  window = { width = 78 },
  preview = { width = 30, min_width = 10, debounce = 5 },
}

local function floating_wins()
  local out = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      out[#out + 1] = win
    end
  end
  return out
end

local function preview_win()
  for _, win in ipairs(floating_wins()) do
    if vim.w[win].picky_preview then
      return win
    end
  end
  return nil
end

---The result window: floating, non-focusable, and not the preview.
local function results_win()
  for _, win in ipairs(floating_wins()) do
    if not vim.api.nvim_win_get_config(win).focusable and not vim.w[win].picky_preview then
      return win
    end
  end
  error("no result window found")
end

local function preview_lines()
  local win = preview_win()
  if not win then
    return nil
  end
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

---Wait until the preview shows exactly `lines`.
local function wait_preview(lines)
  t.wait(function()
    return vim.deep_equal(preview_lines(), lines)
  end)
end

---Find a virt_text overlay in the preview buffer (stub messages).
local function preview_stub_text()
  local win = preview_win()
  if not win then
    return nil
  end
  local buf = vim.api.nvim_win_get_buf(win)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    local virt_text = mark[4].virt_text
    if virt_text and virt_text[1] then
      return virt_text[1][1]
    end
  end
  return nil
end

local function open_source(source, opts)
  return picky.open(vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {}, { source = source }))
end

local function open_items(items, opts)
  return open_source(picky.sources.items(items), opts)
end

local function temp_file(lines)
  local path = vim.fn.tempname()
  vim.fn.writefile(lines, path)
  return path
end

local function press(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "x", false)
end

t.describe("preview", function()
  t.it("opens a preview pane next to the prompt and results", function()
    local before = #floating_wins()
    local session = open_items({ { id = 1, text = "one" } })
    t.eq(before + 3, #floating_wins())
    -- The prompt/results column gives up the pane's width plus the border gap.
    t.eq(78 - 30 - 2, vim.api.nvim_win_get_width(results_win()))
    t.eq(78 - 30 - 2, vim.api.nvim_win_get_width(vim.api.nvim_get_current_win()))
    t.eq(30, vim.api.nvim_win_get_width(assert(preview_win())))
    session:close()
    t.eq(before, #floating_wins())
  end)

  t.it("previews a path item's file contents", function()
    local path = temp_file({ "alpha line", "beta line" })
    local session = open_items({ { id = 1, text = "one", path = path } })
    wait_preview({ "alpha line", "beta line" })
    session:close()
    vim.fn.delete(path)
  end)

  t.it("centers on lnum and highlights the target line", function()
    local lines = {}
    for i = 1, 50 do
      lines[i] = "line " .. i
    end
    local path = temp_file(lines)
    local session = open_items({ { id = 1, text = "one", path = path, lnum = 25, col = 3 } })
    wait_preview(lines)
    local win = assert(preview_win())
    t.eq({ 25, 2 }, vim.api.nvim_win_get_cursor(win))
    local buf = vim.api.nvim_win_get_buf(win)
    local found = false
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
      if mark[4].line_hl_group == "PickyPreviewLine" then
        found = true
        t.eq(24, mark[2], "line highlight on the target row")
      end
    end
    t.ok(found, "PickyPreviewLine extmark expected")
    session:close()
    vim.fn.delete(path)
  end)

  t.it("previews a bufnr item by copying the buffer", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "from a buffer" })
    local session = open_items({ { id = 1, text = "one", bufnr = buf } })
    wait_preview({ "from a buffer" })
    t.ok(vim.api.nvim_win_get_buf(assert(preview_win())) ~= buf, "must not mount the real buffer")
    session:close()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  t.it("previews a commit item via git show and keeps the shared buffer", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local function git(args)
      return vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true }):wait()
    end
    git({ "init" })
    git({ "-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "hello preview" })
    local hash = vim.trim(git({ "rev-parse", "HEAD" }).stdout)

    local source = picky.sources.items({ { id = hash, text = "subject", commit = hash } })
    source.cwd = dir
    local session = open_source(source)
    t.wait(function()
      local lines = preview_lines()
      return lines ~= nil and table.concat(lines, "\n"):find("hello preview", 1, true) ~= nil
    end)
    session:close()

    local name = "picky://git/" .. hash
    local shared = vim.fn.bufnr(name)
    t.ok(shared ~= -1, "commit buffer must survive the picker")
    vim.api.nvim_buf_delete(shared, { force = true })
    vim.fn.delete(dir, "rf")
  end)

  t.it("previews a help tag at its doc line", function()
    local session = open_items({ { id = 1, text = "help", tag = "help" } })
    t.wait(function()
      local lines = preview_lines()
      return lines ~= nil and #lines > 1
    end)
    local win = assert(preview_win())
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local line = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), row - 1, row, false)[1]
    t.ok(line:find("*help*", 1, true), "cursor on the tag's line")
    session:close()
  end)

  t.it("shows a stub for items with nothing to preview", function()
    local session = open_items({ { id = 1, text = "plain" } })
    t.wait(function()
      return preview_stub_text() == "no preview"
    end)
    session:close()
  end)

  t.it("opens no pane when the source opts out", function()
    local before = #floating_wins()
    local source = picky.sources.items({ { id = 1, text = "one" } })
    source.preview = false
    local session = open_source(source)
    t.eq(before + 2, #floating_wins())
    t.eq(78, vim.api.nvim_win_get_width(results_win()))
    session:close()
  end)

  t.it("lets a source previewer handle items or fall through", function()
    local path = temp_file({ "fallthrough contents" })
    local source = picky.sources.items({
      { id = 1, text = "custom" },
      { id = 2, text = "through", path = path },
    })
    source.preview = function(_, item, ctx)
      if item.id == 1 then
        vim.api.nvim_buf_set_lines(ctx.buf, 0, -1, false, { "custom preview" })
        return true
      end
    end
    local session = open_source(source)
    wait_preview({ "custom preview" })
    session:move(1)
    wait_preview({ "fallthrough contents" })
    session:close()
    vim.fn.delete(path)
  end)

  t.it("toggles the pane and reflows the results width", function()
    local path = temp_file({ "toggled" })
    local session = open_items({ { id = 1, text = "one", path = path } })
    wait_preview({ "toggled" })

    press("<M-p>")
    t.eq(nil, preview_win())
    t.eq(78, vim.api.nvim_win_get_width(results_win()))

    press("<M-p>")
    t.ok(preview_win() ~= nil, "pane restored")
    t.eq(78 - 30 - 2, vim.api.nvim_win_get_width(results_win()))
    t.eq({ "toggled" }, preview_lines())
    session:close()
    vim.fn.delete(path)
  end)

  t.it("reuses the cached buffer when returning to an item", function()
    local first = temp_file({ "first file" })
    local second = temp_file({ "second file" })
    local session = open_items({
      { id = 1, text = "one", path = first },
      { id = 2, text = "two", path = second },
    })
    wait_preview({ "first file" })
    local buf = vim.api.nvim_win_get_buf(assert(preview_win()))
    session:move(1)
    wait_preview({ "second file" })
    session:move(-1)
    wait_preview({ "first file" })
    t.eq(buf, vim.api.nvim_win_get_buf(assert(preview_win())))
    session:close()
    vim.fn.delete(first)
    vim.fn.delete(second)
  end)

  t.it("stubs files over the byte cap", function()
    local path = temp_file({ ("x"):rep(100) })
    local session = open_items(
      { { id = 1, text = "one", path = path } },
      { preview = { max_file_bytes = 10 } }
    )
    t.wait(function()
      return preview_stub_text() == "file too large"
    end)
    session:close()
    vim.fn.delete(path)
  end)

  t.it("hides the pane when the picker is too narrow", function()
    local before = #floating_wins()
    local session = open_items({ { id = 1, text = "one" } }, { window = { width = 40 } })
    t.eq(before + 2, #floating_wins())
    t.eq(40, vim.api.nvim_win_get_width(results_win()))
    session:close()
  end)

  t.it("hides and restores the pane as the editor is resized", function()
    local old_columns = vim.o.columns
    vim.o.columns = 100
    local session = open_items({ { id = 1, text = "one" } }, { window = { width = 0.8 } })
    local initially_open = preview_win() ~= nil

    vim.o.columns = 50
    vim.api.nvim_exec_autocmds("VimResized", {})
    local hidden = preview_win() == nil
    local narrow_width = vim.api.nvim_win_get_width(results_win())

    vim.o.columns = 100
    vim.api.nvim_exec_autocmds("VimResized", {})
    local restored = preview_win() ~= nil
    local wide_width = vim.api.nvim_win_get_width(results_win())

    session:close()
    vim.o.columns = old_columns
    vim.api.nvim_exec_autocmds("VimResized", {})

    t.ok(initially_open, "preview starts open")
    t.ok(hidden, "preview hides below its width guard")
    t.eq(40, narrow_width)
    t.ok(restored, "preview returns when enough width is available")
    t.eq(48, wide_width)
  end)

  t.it("cleans up preview buffers on close", function()
    local path = temp_file({ "cleanup" })
    local buffers_before = #vim.api.nvim_list_bufs()
    local session = open_items({
      { id = 1, text = "one", path = path },
      { id = 2, text = "two" },
    })
    wait_preview({ "cleanup" })
    session:move(1) -- also materialize the stub buffer
    t.wait(function()
      return preview_stub_text() == "no preview"
    end)
    session:close()
    t.eq(buffers_before, #vim.api.nvim_list_bufs())
    vim.fn.delete(path)
  end)

  t.it("follows the active item as it changes", function()
    local first = temp_file({ "follow one" })
    local second = temp_file({ "follow two" })
    local session = open_items({
      { id = 1, text = "one", path = first },
      { id = 2, text = "two", path = second },
    })
    wait_preview({ "follow one" })
    session:move(1)
    wait_preview({ "follow two" })
    session:close()
    vim.fn.delete(first)
    vim.fn.delete(second)
  end)
end)

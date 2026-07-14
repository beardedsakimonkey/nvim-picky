---Two-window picker UI: a prompt window and a non-focusable result window.
---Rendering is virtualized: only the visible slice of matches is written to
---the result buffer on each update.

local query_parser = require("picky.query")

local M = {}

local ns = vim.api.nvim_create_namespace("picky")
-- Separate namespace for prompt operator highlights, so clearing them per
-- keystroke can't wipe the prompt symbol or counter extmarks in `ns`.
local ops_ns = vim.api.nvim_create_namespace("picky.operators")

local links = {
  PickyMuted = "Comment", -- dimmed secondary context (authors, refs, containers)
  PickyMatch = "Special", -- matched characters
  PickyPrompt = "PickyMuted", -- the "> " prompt symbol
  PickyOperator = "Operator", -- query operators (', !, ^, trailing $) in the prompt
  PickyCounter = "PickyMuted", -- the n/total counter
  PickySelected = "Visual", -- multi-selected rows
  PickyError = "ErrorMsg", -- source error text
  PickyEmpty = "PickyMuted", -- the "no results" placeholder
  PickyNormal = "NormalFloat", -- result/prompt window text and background
  PickyBorder = "FloatBorder", -- result/prompt window border
  PickyDir = "PickyMuted", -- dimmed directory / path context
  PickyPreviewLine = "Visual", -- the target line of a location item in the preview
  PickyKind = "Type", -- symbol kind glyphs
  PickyGitHash = "Identifier", -- commit hashes
  PickyBufVisible = "Statement", -- name of a buffer on screen in a window
}

---Register the default highlight links.
for group, link in pairs(links) do
  vim.api.nvim_set_hl(0, group, { link = link, default = true })
end

-- Resolve a window dimension against the editor size: values <= 1 are treated
-- as a fraction of `total`, values > 1 as an absolute number of cells.
local function resolve_dimension(value, total)
  if value <= 1 then
    return math.floor(total * value)
  end
  return math.floor(value)
end

---@param value number
---@return string
local function format_count(value)
  return (tostring(value):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

-- Map the floating windows' base groups onto picky's own, so users can restyle
-- the picker via PickyNormal/PickyBorder without touching global float groups.
local winhighlight = "NormalFloat:PickyNormal,FloatBorder:PickyBorder"

---@class PickyUI
---@field session PickySession
---@field config PickyConfig
local UI = {}
UI.__index = UI

---Render one item line. Returns the text and per-chunk metadata mapping
---field byte ranges to rendered columns, so match positions translate
---directly into highlight ranges.
---@param item PickyItem
---@return string, { field: string?, hl: string?, start: number, len: number }[]
local function render_line(item)
  local display = item.display
  if display == nil then
    display = { { field = "text" } }
  end
  if type(display) == "string" then
    return display, {}
  end
  local parts, meta = {}, {}
  local offset = 0
  for _, chunk in ipairs(display) do
    local text
    if chunk.field then
      local value = item[chunk.field]
      text = type(value) == "string" and value or (value ~= nil and tostring(value) or "")
    else
      text = chunk.text or ""
    end
    parts[#parts + 1] = text
    meta[#meta + 1] = { field = chunk.field, hl = chunk.hl, start = offset, len = #text }
    offset = offset + #text
  end
  return table.concat(parts), meta
end

---A short window title for the previewed item, truncated from the left so
---the most specific part (a path's tail) survives.
---@param item PickyItem?
---@param max number
---@return string
local function preview_title(item, max)
  if item == nil then
    return ""
  end
  local title = item.tag
    or (item.commit and tostring(item.commit):sub(1, 12))
    or item.rel
    or item.path
    or item.text
    or ""
  title = tostring(title)
  local chars = vim.fn.strchars(title)
  if chars > max then
    title = "…" .. vim.fn.strcharpart(title, chars - max + 1)
  end
  return title
end

---Byte length of the UTF-8 character starting at byte `b`.
local function char_len(b)
  if b == nil or b < 0x80 then
    return 1
  elseif b < 0xE0 then
    return 2
  elseif b < 0xF0 then
    return 3
  end
  return 4
end

---@param session PickySession
---@param config PickyConfig
---@return PickyUI
function M.new(session, config)
  local self = setmetatable({
    session = session,
    config = config,
    closed = false,
    top = 1,
    counter_extmark = nil,
  }, UI)
  return self
end

-- Static window anchors derived from the configured (maximum) size. The overall
-- box is centered using `max_results`; with `shrink` the result window occupies
-- fewer rows within that envelope (see `_geometry`/`_fit`).
function UI:layout()
  local win = self.config.window
  local border = win.border or "single"
  local pad = (border == "none" or border == "") and 0 or 2

  local total_width = math.max(resolve_dimension(win.width, vim.o.columns), 20)
  local total_height = math.max(resolve_dimension(win.height, vim.o.lines), 5)
  local max_results = math.max(total_height - 1 - 2 * pad, 1)
  local col = math.max(math.floor((vim.o.columns - total_width - pad) / 2), 0)
  local row = math.max(math.floor((vim.o.lines - total_height) / 2), 0)

  -- Split the total width between the prompt/results column and the preview
  -- pane. The pane is dropped entirely when either side would end up too
  -- narrow to be useful, so the picker degrades to the plain two-window form.
  local left_width, preview_width = total_width, 0
  if self.preview_wanted then
    preview_width = resolve_dimension(self.config.preview.width, total_width)
    left_width = total_width - preview_width - pad
    if preview_width < self.config.preview.min_width or left_width < 30 then
      left_width, preview_width = total_width, 0
    end
  end

  return {
    border = border,
    pad = pad,
    width = total_width,
    left_width = left_width,
    preview_width = preview_width,
    preview_visible = preview_width > 0,
    col = col,
    base_row = row,
    max_results = max_results,
  }
end

-- Window rows for a given result-window height. The prompt stays anchored
-- (at the top, or at the bottom of the full-height envelope) so it does not
-- move as the result window grows or shrinks toward it.
function UI:_geometry(layout, results_height)
  local prompt_row, results_row
  if self.config.window.input_position == "bottom" then
    prompt_row = layout.base_row + layout.max_results + layout.pad
    results_row = prompt_row - layout.pad - results_height
  else
    prompt_row = layout.base_row
    results_row = layout.base_row + 1 + layout.pad
  end
  return {
    prompt = { row = prompt_row, col = layout.col },
    results = { row = results_row, col = layout.col },
    -- The pane spans the full envelope height regardless of input_position
    -- and of the result window shrinking; a tall preview stays useful.
    preview = {
      row = layout.base_row,
      col = layout.col + layout.left_width + layout.pad,
      height = layout.max_results + 1 + layout.pad,
    },
  }
end

-- Resize the result window to fit `count` matches, capped at the configured
-- height and floored at one line. Only reconfigures when the height actually
-- changes, to avoid per-keystroke flicker.
function UI:_fit(count)
  local layout = self.layout
  local desired = math.max(math.min(count, layout.max_results), 1)
  if desired == self.results_height then
    return
  end
  self.results_height = desired
  local geo = self:_geometry(layout, desired)
  vim.api.nvim_win_set_config(self.results_win, {
    relative = "editor",
    row = geo.results.row,
    col = geo.results.col,
    width = layout.left_width,
    height = desired,
    border = layout.border,
    title = self.session.source.name,
  })
end

---Open the preview float to the right of the prompt/results column. Starts on
---a throwaway buffer; the first refresh swaps in real content.
function UI:_open_preview()
  local layout = self.layout
  local geo = self:_geometry(layout, self.results_height)
  self.preview = self.preview or require("picky.preview").new(self.config)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  self.preview_win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = geo.preview.row,
    col = geo.preview.col,
    width = layout.preview_width,
    height = geo.preview.height,
    border = layout.border,
    style = "minimal",
    focusable = false,
  })
  vim.w[self.preview_win].picky_preview = true
  vim.wo[self.preview_win].wrap = false
  vim.wo[self.preview_win].winhighlight = winhighlight
  self.last_previewed_id = nil
end

---Apply a freshly computed layout to every picker window. A preview hidden by
---the minimum-width guard is closed without changing `preview_wanted`, so it
---can return if the editor becomes wide enough again.
---@param layout table
function UI:_apply_layout(layout)
  self.layout = layout
  if self.config.window.shrink then
    self.results_height = math.max(math.min(#self.session.matches, layout.max_results), 1)
  else
    self.results_height = layout.max_results
  end

  local geo = self:_geometry(layout, self.results_height)
  vim.api.nvim_win_set_config(self.prompt_win, {
    relative = "editor",
    row = geo.prompt.row,
    col = geo.prompt.col,
    width = layout.left_width,
    height = 1,
    border = layout.border,
  })
  vim.api.nvim_win_set_config(self.results_win, {
    relative = "editor",
    row = geo.results.row,
    col = geo.results.col,
    width = layout.left_width,
    height = self.results_height,
    border = layout.border,
    title = self.session.source.name,
  })

  local preview_open = self.preview_win and vim.api.nvim_win_is_valid(self.preview_win)
  if not layout.preview_visible then
    if preview_open then
      vim.api.nvim_win_close(self.preview_win, true)
    end
    self.preview_win = nil
  elseif not preview_open then
    self:_open_preview()
    self:_refresh_preview()
  else
    local config = {
      relative = "editor",
      row = geo.preview.row,
      col = geo.preview.col,
      width = layout.preview_width,
      height = geo.preview.height,
      border = layout.border,
    }
    if layout.pad > 0 then
      config.title = preview_title(self.session:current_item(), layout.preview_width - 2)
    end
    vim.api.nvim_win_set_config(self.preview_win, config)
  end
end

---Recompute and render the picker after the editor grid changes.
function UI:_resize()
  if
    self.closed
    or self.session.closed
    or not vim.api.nvim_win_is_valid(self.prompt_win)
    or not vim.api.nvim_win_is_valid(self.results_win)
  then
    return
  end
  self:_apply_layout(UI.layout(self))
  self:render()
end

function UI:open()
  self.preview_wanted = self.config.preview.enabled and self.session.source.preview ~= false
  local layout = self:layout()
  self.layout = layout
  -- Open at full height; render shrinks the result window to fit once matches
  -- are known, avoiding a grow-from-tiny flash while a source is still loading.
  self.results_height = layout.max_results
  local geo = self:_geometry(layout, self.results_height)
  self.prev_win = vim.api.nvim_get_current_win()

  self.results_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.results_buf].bufhidden = "wipe"
  self.results_win = vim.api.nvim_open_win(self.results_buf, false, {
    relative = "editor",
    row = geo.results.row,
    col = geo.results.col,
    width = layout.left_width,
    height = self.results_height,
    border = layout.border,
    style = "minimal",
    focusable = false,
    title = self.session.source.name,
  })
  vim.wo[self.results_win].cursorline = false
  vim.wo[self.results_win].scrolloff = 0
  vim.wo[self.results_win].winhighlight = winhighlight

  self.prompt_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.prompt_buf].bufhidden = "wipe"
  self.prompt_win = vim.api.nvim_open_win(self.prompt_buf, true, {
    relative = "editor",
    row = geo.prompt.row,
    col = geo.prompt.col,
    width = layout.left_width,
    height = 1,
    border = layout.border,
    style = "minimal",
  })
  vim.wo[self.prompt_win].winhighlight = winhighlight

  if layout.preview_visible then
    self:_open_preview()
  end

  vim.api.nvim_buf_set_extmark(self.prompt_buf, ns, 0, 0, {
    virt_text = { { "> ", "PickyPrompt" } },
    virt_text_pos = "inline",
    right_gravity = false,
  })

  self:_setup_keymaps()
  self:_setup_autocmds()

  -- buf_attach fires for API edits too, unlike TextChanged autocmds, which
  -- keeps the query path identical for typed and scripted input.
  vim.api.nvim_buf_attach(self.prompt_buf, false, {
    on_lines = function()
      vim.schedule(function()
        if self.closed or not vim.api.nvim_buf_is_valid(self.prompt_buf) then
          return
        end
        local line = vim.api.nvim_buf_get_lines(self.prompt_buf, 0, 1, false)[1] or ""
        self:_decorate_prompt(line)
        self.session:set_query(line)
      end)
      return self.closed
    end,
  })

  self.session.on_update = function()
    self:render()
  end

  vim.cmd.startinsert()
end

function UI:_setup_keymaps()
  for lhs, rhs in pairs(self.config.keymaps or {}) do
    if rhs ~= false then
      vim.keymap.set({ "i", "n" }, lhs, function()
        if rhs == "page_down" then
          self.session:move(vim.api.nvim_win_get_height(self.results_win))
        elseif rhs == "page_up" then
          self.session:move(-vim.api.nvim_win_get_height(self.results_win))
        elseif rhs == "history_prev" or rhs == "history_next" then
          self:_recall(rhs)
        elseif rhs == "toggle_preview" then
          self:_toggle_preview()
        elseif rhs == "preview_scroll_down" or rhs == "preview_scroll_up" then
          self:_scroll_preview(rhs == "preview_scroll_down" and 1 or -1)
        else
          self.session:run_action(rhs)
        end
      end, { buffer = self.prompt_buf, nowait = true })
    end
  end
end

---Show or hide the preview pane, reflowing the prompt/results column into the
---freed or reclaimed width. A no-op when the source opted out or the picker is
---too narrow for a pane.
function UI:_toggle_preview()
  if self.session.source.preview == false then
    return
  end
  self.preview_wanted = not self.preview_wanted
  -- `self.layout` holds the cached table and shadows the method.
  local layout = UI.layout(self)
  if self.preview_wanted and not layout.preview_visible then
    self.preview_wanted = false
    return
  end
  self:_apply_layout(layout)
end

---Scroll the preview window by half a page.
---@param direction 1|-1
function UI:_scroll_preview(direction)
  local win = self.preview_win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  vim.api.nvim_win_call(win, function()
    -- \4 / \21 are <C-d> / <C-u>.
    pcall(function()
      vim.cmd("normal! " .. (direction > 0 and "\4" or "\21"))
    end)
  end)
end

---Show a query recalled from the source's history in the prompt. The buffer
---write reaches the session through the same on_lines path as typing.
---@param action "history_prev"|"history_next"
function UI:_recall(action)
  local query
  if action == "history_prev" then
    query = self.session:history_prev()
  else
    query = self.session:history_next()
  end
  if query == nil then
    return
  end
  vim.api.nvim_buf_set_lines(self.prompt_buf, 0, -1, false, { query })
  pcall(vim.api.nvim_win_set_cursor, self.prompt_win, { 1, #query })
end

---Highlight the query operators (', !, ^, and an anchoring trailing $) in
---the prompt line.
---@param line string
function UI:_decorate_prompt(line)
  vim.api.nvim_buf_clear_namespace(self.prompt_buf, ops_ns, 0, -1)
  for _, span in ipairs(query_parser.operators(line)) do
    vim.api.nvim_buf_set_extmark(self.prompt_buf, ops_ns, 0, span.from, {
      end_col = span.to,
      hl_group = "PickyOperator",
      strict = false,
    })
  end
end

function UI:_setup_autocmds()
  self.augroup = vim.api.nvim_create_augroup("picky.ui." .. self.prompt_buf, { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = self.augroup,
    callback = function()
      self:_resize()
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = self.augroup,
    pattern = { tostring(self.prompt_win), tostring(self.results_win) },
    callback = function()
      self.session:close()
    end,
  })
  vim.api.nvim_create_autocmd("BufLeave", {
    group = self.augroup,
    buffer = self.prompt_buf,
    callback = function()
      self.session:close()
    end,
  })
end

function UI:render()
  if self.session.closed then
    self:close()
    return
  end
  if self.closed or not vim.api.nvim_win_is_valid(self.results_win) then
    return
  end

  local session = self.session
  local matches = session.matches
  if self.config.window.shrink then
    self:_fit(#matches)
  end
  local height = vim.api.nvim_win_get_height(self.results_win)
  local active = session:active_index()

  -- Keep the active row inside the visible slice.
  if active > 0 then
    if active < self.top then
      self.top = active
    elseif active > self.top + height - 1 then
      self.top = active - height + 1
    end
  else
    self.top = 1
  end
  self.top = math.min(self.top, math.max(#matches - height + 1, 1))

  local lines = {}
  local metas = {}
  local count = math.min(height, #matches - self.top + 1)
  for row = 1, count do
    local m = matches[self.top + row - 1]
    local text, meta = render_line(session.items[m.index])
    lines[row] = text
    metas[row] = { meta = meta, match = m, item = session.items[m.index] }
  end
  if #lines == 0 then
    lines[1] = ""
  end

  vim.api.nvim_buf_set_lines(self.results_buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(self.results_buf, ns, 0, -1)

  for row, entry in ipairs(metas) do
    self:_decorate_row(row - 1, lines[row], entry)
  end

  if active > 0 then
    pcall(vim.api.nvim_win_set_cursor, self.results_win, { active - self.top + 1, 0 })
  end
  vim.wo[self.results_win].cursorline = active > 0

  if #matches == 0 then
    local text, group
    if session.error then
      text, group = session.error:gsub("%s+", " "), "PickyError"
    elseif session.loading then
      text, group = "loading…", "PickyCounter"
    else
      text, group = "no results", "PickyEmpty"
    end
    vim.api.nvim_buf_set_extmark(self.results_buf, ns, 0, 0, {
      virt_text = { { text, group } },
      virt_text_pos = "overlay",
    })
  end

  self:_render_counter(active, #matches)
  self:_schedule_preview()
end

---Debounced preview refresh, keyed by the active item id: streaming match
---batches that keep the same top item cost nothing, and held-down navigation
---coalesces into one refresh.
function UI:_schedule_preview()
  if not (self.preview_win and vim.api.nvim_win_is_valid(self.preview_win)) then
    return
  end
  local item = self.session:current_item()
  if (item and item.id) == self.last_previewed_id then
    return
  end
  if not self.preview_timer then
    self.preview_timer = assert(vim.uv.new_timer())
  end
  self.preview_timer:stop()
  self.preview_timer:start(self.config.preview.debounce or 40, 0, function()
    vim.schedule(function()
      self:_refresh_preview()
    end)
  end)
end

---Load the active item into the preview window and retitle it. Re-reads the
---current item at call time, never trusting what was active at schedule time.
function UI:_refresh_preview()
  if self.closed or self.session.closed then
    return
  end
  if not (self.preview_win and vim.api.nvim_win_is_valid(self.preview_win)) then
    return
  end
  local item = self.session:current_item()
  self.last_previewed_id = item and item.id or nil
  self.preview:show(self.preview_win, item, self.session.source, self.session.cwd)
  if self.layout.pad > 0 then
    local geo = self:_geometry(self.layout, self.results_height)
    vim.api.nvim_win_set_config(self.preview_win, {
      relative = "editor",
      row = geo.preview.row,
      col = geo.preview.col,
      width = self.layout.preview_width,
      height = geo.preview.height,
      border = self.layout.border,
      title = preview_title(item, self.layout.preview_width - 2),
    })
  end
end

---@param lnum number 0-based row in the result buffer
---@param line string rendered text of the row
function UI:_decorate_row(lnum, line, entry)
  for _, chunk in ipairs(entry.meta) do
    if chunk.hl and chunk.len > 0 then
      -- Below PickyMatch (200) so match highlights stay visible on top of a
      -- chunk's base highlight (e.g. a matched filename in `Normal`).
      vim.api.nvim_buf_set_extmark(self.results_buf, ns, lnum, chunk.start, {
        end_col = chunk.start + chunk.len,
        hl_group = chunk.hl,
        priority = 100,
        strict = false,
      })
    end
  end
  -- Colors parsed from ANSI output sit above a chunk's base highlight but
  -- below PickyMatch, so fuzzy-match highlighting stays visible on top.
  for _, span in ipairs(entry.item.highlights or {}) do
    if span.to > span.from then
      vim.api.nvim_buf_set_extmark(self.results_buf, ns, lnum, span.from, {
        end_col = span.to,
        hl_group = span.hl,
        priority = 150,
        strict = false,
      })
    end
  end
  for _, chunk in ipairs(entry.meta) do
    local positions = chunk.field and entry.match.positions[chunk.field]
    if positions then
      for _, pos in ipairs(positions) do
        if pos <= chunk.len then
          local col = chunk.start + pos - 1
          vim.api.nvim_buf_set_extmark(self.results_buf, ns, lnum, col, {
            end_col = col + char_len(line:byte(col + 1)),
            hl_group = "PickyMatch",
            priority = 200,
            strict = false,
          })
        end
      end
    end
  end
  if self.session.selected[entry.item.id] then
    vim.api.nvim_buf_set_extmark(self.results_buf, ns, lnum, 0, {
      line_hl_group = "PickySelected",
      strict = false,
    })
  end
end

function UI:_render_counter(active, total)
  if not vim.api.nvim_buf_is_valid(self.prompt_buf) then
    return
  end
  local session = self.session
  local parts = {}
  if session.error then
    parts[#parts + 1] = "error"
  end
  local selected = session:selected_count()
  if selected > 0 then
    parts[#parts + 1] = ("(%s)"):format(format_count(selected))
  end
  local count = ("%s/%s"):format(format_count(active), format_count(total))
  if session.loading then
    count = count .. "…"
  end
  parts[#parts + 1] = count
  self.counter_extmark = vim.api.nvim_buf_set_extmark(self.prompt_buf, ns, 0, 0, {
    id = self.counter_extmark,
    virt_text = { { table.concat(parts, " "), "PickyCounter" } },
    virt_text_pos = "right_align",
  })
end

---Idempotent teardown: clears autocmds, closes windows, deletes buffers,
---and restores the previous window.
function UI:close()
  if self.closed then
    return
  end
  self.closed = true
  pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  vim.cmd.stopinsert()
  if self.preview_timer then
    self.preview_timer:stop()
    self.preview_timer:close()
    self.preview_timer = nil
  end
  for _, win in ipairs({ self.prompt_win, self.results_win, self.preview_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs({ self.prompt_buf, self.results_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  if self.preview then
    self.preview:close()
  end
  if self.prev_win and vim.api.nvim_win_is_valid(self.prev_win) then
    pcall(vim.api.nvim_set_current_win, self.prev_win)
  end
end

return M

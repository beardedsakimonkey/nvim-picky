---Two-window picker UI: a prompt window and a non-focusable result window.
---Rendering is virtualized: only the visible slice of matches is written to
---the result buffer on each update.

local M = {}

local ns = vim.api.nvim_create_namespace("picky")

require("picky.highlights")

-- Resolve a window dimension against the editor size: values <= 1 are treated
-- as a fraction of `total`, values > 1 as an absolute number of cells.
local function resolve_dimension(value, total)
  if value <= 1 then
    return math.floor(total * value)
  end
  return math.floor(value)
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

  return {
    border = border,
    pad = pad,
    width = total_width,
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
    width = layout.width,
    height = desired,
    border = layout.border,
    title = self.session.source.name,
  })
end

function UI:open()
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
    width = layout.width,
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
    width = layout.width,
    height = 1,
    border = layout.border,
    style = "minimal",
  })
  vim.wo[self.prompt_win].winhighlight = winhighlight

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
        else
          self.session:run_action(rhs)
        end
      end, { buffer = self.prompt_buf, nowait = true })
    end
  end
end

function UI:_setup_autocmds()
  self.augroup = vim.api.nvim_create_augroup("picky.ui." .. self.prompt_buf, { clear = true })
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
  if session.loading then
    parts[#parts + 1] = "…"
  end
  if session.error then
    parts[#parts + 1] = "error"
  end
  local selected = session:selected_count()
  if selected > 0 then
    parts[#parts + 1] = ("(%d)"):format(selected)
  end
  parts[#parts + 1] = ("%d/%d"):format(active, total)
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
  for _, win in ipairs({ self.prompt_win, self.results_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs({ self.prompt_buf, self.results_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  if self.prev_win and vim.api.nvim_win_is_valid(self.prev_win) then
    pcall(vim.api.nvim_set_current_win, self.prev_win)
  end
end

return M

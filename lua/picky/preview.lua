---Preview pane content. Resolves the active item into a scratch buffer via
---the same common fields the openers in actions.lua understand (`bufnr`,
---`commit`, `path` with `lnum`/`col`, `tag`) and shows it in the preview
---window. Buffers are cached per item id for the lifetime of one picker and
---deleted on close; real user buffers are copied, never mounted, so picker
---window state cannot leak into them. Preview buffers never get a real
---filetype: highlighting goes through vim.treesitter.start / 'syntax'
---directly, so FileType autocmds (LSP, plugins) stay away from them.

local actions = require("picky.actions")

local M = {}

local ns = vim.api.nvim_create_namespace("picky.preview")

-- Cached preview buffers kept per picker before the oldest is evicted.
local CACHE_CAP = 20

-- Extra lines loaded past a target line, so a capped read still shows the
-- match with context below it.
local TARGET_MARGIN = 100

---@class PickyPreviewEntry
---@field bufnr number
---@field lnum number?
---@field col number?
---@field shared boolean? not owned by this picker (commit buffers); never deleted

---@class PickyPreview
---@field config PickyConfig
---@field cache table<string|number, PickyPreviewEntry> per item id
---@field order (string|number)[] cache ids, least recently shown first
---@field stub_buf number? reused buffer for placeholder messages
---@field custom_buf number? reused buffer handed to custom source previewers
---@field help_index table<string, string>? help tag -> doc file, built lazily
local Preview = {}
Preview.__index = Preview

---@param config PickyConfig
---@return PickyPreview
function M.new(config)
  return setmetatable({ config = config, cache = {}, order = {} }, Preview)
end

---Window-local options do not reliably survive a buffer swap, so the pane's
---look is re-applied every time a buffer is set into the window.
---@param win number
local function style_win(win)
  local wo = vim.wo[win]
  wo.wrap = false
  wo.number = false
  wo.relativenumber = false
  wo.cursorline = false
  wo.signcolumn = "no"
  wo.foldenable = false
end

---Read up to `max_bytes` of a file, split into at most `max_lines` lines.
---@param path string
---@param max_bytes number
---@param max_lines number
---@return string[]? lines, string? reason stub message when unreadable
local function read_file(path, max_bytes, max_lines)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil, "file not found"
  end
  if stat.type == "directory" then
    return nil, "directory"
  end
  if stat.size > max_bytes then
    return nil, "file too large"
  end
  local f = io.open(path, "r")
  if not f then
    return nil, "cannot read file"
  end
  local data = f:read(max_bytes) or ""
  f:close()
  if data:sub(1, 1024):find("\0", 1, true) then
    return nil, "binary file"
  end
  local lines = vim.split(data, "\n", { plain = true })
  if #lines > 1 and lines[#lines] == "" then
    lines[#lines] = nil
  end
  if #lines > max_lines then
    lines = vim.list_slice(lines, 1, max_lines)
  end
  return lines
end

---Fill a fresh scratch buffer and attach highlighting for `ft` without ever
---setting a real filetype on it.
---@param lines string[]
---@param ft string?
---@return number bufnr
function Preview:_make_buf(lines, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  if ft and ft ~= "" then
    local started = false
    if self.config.preview.treesitter then
      local lang = vim.treesitter.language.get_lang(ft)
      started = lang ~= nil and pcall(vim.treesitter.start, buf, lang)
    end
    if not started then
      pcall(function()
        vim.bo[buf].syntax = ft
      end)
    end
  end
  return buf
end

---Line cap for a read that must include a target line: lines are always
---loaded from the top so buffer line numbers stay meaningful.
---@param max_lines number
---@param lnum number?
---@return number
local function line_cap(max_lines, lnum)
  if lnum and lnum + TARGET_MARGIN > max_lines then
    return lnum + TARGET_MARGIN
  end
  return max_lines
end

---@param path string
---@param lnum number?
---@param col number?
---@param ft string? forced filetype (help files); detected otherwise
---@param max_lines number? overrides the configured line cap
---@return PickyPreviewEntry? entry, string? reason
function Preview:_from_path(path, lnum, col, ft, max_lines)
  local pv = self.config.preview
  local cap = line_cap(max_lines or pv.max_lines, lnum)
  local lines, reason = read_file(path, pv.max_file_bytes, cap)
  if not lines then
    return nil, reason
  end
  ft = ft or vim.filetype.match({ filename = path, contents = lines })
  return { bufnr = self:_make_buf(lines, ft), lnum = lnum, col = col }
end

---Resolve a help tag to its doc file, building the index on first use from
---the same doc/tags files the help source reads.
---@param tag string
---@return string? path
function Preview:_help_path(tag)
  if not self.help_index then
    local index = {}
    for _, tagfile in ipairs(vim.api.nvim_get_runtime_file("doc/tags", true)) do
      local dir = vim.fs.dirname(tagfile)
      local f = io.open(tagfile)
      if f then
        for line in f:lines() do
          local name, file = line:match("^([^\t]+)\t([^\t]+)\t")
          if name and index[name] == nil then
            index[name] = vim.fs.joinpath(dir, file)
          end
        end
        f:close()
      end
    end
    self.help_index = index
  end
  return self.help_index[tag]
end

---@param tag string
---@return PickyPreviewEntry? entry, string? reason
function Preview:_from_tag(tag)
  local path = self:_help_path(tag)
  if not path then
    return nil, "no preview"
  end
  -- Help files regularly exceed the configured line cap and the tag's line is
  -- unknown before reading, so load the whole file (the byte cap still holds).
  local entry, reason = self:_from_path(path, nil, nil, "help", math.huge)
  if not entry then
    return nil, reason
  end
  local needle = "*" .. tag .. "*"
  for i, line in ipairs(vim.api.nvim_buf_get_lines(entry.bufnr, 0, -1, false)) do
    if line:find(needle, 1, true) then
      entry.lnum = i
      break
    end
  end
  return entry
end

---Build a preview entry for the item's common fields, mirroring the dispatch
---in actions.open_item — except `path` outranks `tag`, so helpgrep items land
---on their exact matched line instead of the tag.
---@param item PickyItem
---@param cwd string?
---@return PickyPreviewEntry? entry, string? reason
function Preview:_resolve(item, cwd)
  local pv = self.config.preview
  if item.bufnr and vim.api.nvim_buf_is_valid(item.bufnr) then
    if vim.api.nvim_buf_is_loaded(item.bufnr) then
      local cap = line_cap(pv.max_lines, item.lnum)
      local lines = vim.api.nvim_buf_get_lines(item.bufnr, 0, cap, false)
      local buf = self:_make_buf(lines, vim.bo[item.bufnr].filetype)
      return { bufnr = buf, lnum = item.lnum, col = item.col }
    end
    local name = vim.api.nvim_buf_get_name(item.bufnr)
    if name ~= "" then
      return self:_from_path(name, item.lnum, item.col)
    end
    return nil, "no preview"
  end
  if item.commit then
    local buf = actions.commit_buffer(item.commit, cwd)
    if not buf then
      return nil, "no preview"
    end
    return { bufnr = buf, shared = true }
  end
  if item.path then
    return self:_from_path(actions.resolve_path(item.path, cwd), item.lnum, item.col)
  end
  if item.tag then
    return self:_from_tag(item.tag)
  end
  return nil, "no preview"
end

---Record `entry` for `id`: reusing an id bumps it to most recent; growing
---past the cap deletes the oldest picker-owned buffer. Eviction can never hit
---the buffer on screen — the displayed item is always among the newest two.
---@param id string|number?
---@param entry PickyPreviewEntry
function Preview:_remember(id, entry)
  if id == nil then
    return
  end
  for i, existing in ipairs(self.order) do
    if existing == id then
      table.remove(self.order, i)
      break
    end
  end
  self.order[#self.order + 1] = id
  self.cache[id] = entry
  if #self.order <= CACHE_CAP then
    return
  end
  for i, old in ipairs(self.order) do
    local victim = self.cache[old]
    if not victim.shared then
      table.remove(self.order, i)
      self.cache[old] = nil
      if vim.api.nvim_buf_is_valid(victim.bufnr) then
        pcall(vim.api.nvim_buf_delete, victim.bufnr, { force = true })
      end
      break
    end
  end
end

---Show a one-line placeholder message in the pane.
---@param win number
---@param text string
function Preview:_stub(win, text)
  local buf = self.stub_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].modifiable = false
    self.stub_buf = buf
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
    virt_text = { { text, "PickyEmpty" } },
    virt_text_pos = "overlay",
  })
  vim.api.nvim_win_set_buf(win, buf)
  style_win(win)
end

---Run the source's custom previewer against the reusable scratch buffer.
---@param win number
---@param item PickyItem
---@param source PickySource
---@param cwd string?
---@return boolean handled
function Preview:_custom(win, item, source, cwd)
  local buf = self.custom_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    self.custom_buf = buf
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  vim.api.nvim_win_set_buf(win, buf)
  style_win(win)
  local handled = source:preview(item, { buf = buf, win = win, cwd = cwd })
  if vim.api.nvim_buf_is_valid(buf) then
    vim.bo[buf].modifiable = false
  end
  return handled and true or false
end

---Move the pane's cursor to the target location, center it, and highlight the
---line. Without a target line the view resets to the top.
---@param win number
---@param lnum number?
---@param col number?
function Preview:_position(win, lnum, col)
  local buf = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if not lnum then
    pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
    return
  end
  lnum = math.min(math.max(lnum, 1), vim.api.nvim_buf_line_count(buf))
  if not pcall(vim.api.nvim_win_set_cursor, win, { lnum, math.max((col or 1) - 1, 0) }) then
    pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 })
  end
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zz")
  end)
  vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, {
    line_hl_group = "PickyPreviewLine",
    strict = false,
  })
end

---Show `item` in the preview window: custom source previewers first, then the
---built-in field dispatch, then a stub.
---@param win number
---@param item PickyItem?
---@param source PickySource
---@param cwd string?
function Preview:show(win, item, source, cwd)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  if item == nil then
    self:_stub(win, "no preview")
    return
  end
  if type(source.preview) == "function" and self:_custom(win, item, source, cwd) then
    return
  end
  if item.preview == false then
    self:_stub(win, "no preview")
    return
  end
  local entry = item.id ~= nil and self.cache[item.id] or nil
  if entry and not vim.api.nvim_buf_is_valid(entry.bufnr) then
    self.cache[item.id] = nil
    entry = nil
  end
  if not entry then
    local resolved, reason = self:_resolve(item, cwd)
    if not resolved then
      self:_stub(win, reason or "no preview")
      return
    end
    entry = resolved
  end
  self:_remember(item.id, entry)
  vim.api.nvim_win_set_buf(win, entry.bufnr)
  style_win(win)
  self:_position(win, entry.lnum, entry.col)
end

---Delete every picker-owned preview buffer. Shared buffers (commit scratch
---buffers name-cached by actions.lua) are left for reuse, matching their
---lifetime when opened without a preview.
function Preview:close()
  for _, id in ipairs(self.order) do
    local entry = self.cache[id]
    if entry and not entry.shared and vim.api.nvim_buf_is_valid(entry.bufnr) then
      pcall(vim.api.nvim_buf_delete, entry.bufnr, { force = true })
    end
  end
  self.cache, self.order = {}, {}
  for _, buf in ipairs({ self.stub_buf, self.custom_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  self.stub_buf, self.custom_buf = nil, nil
end

return M

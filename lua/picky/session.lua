---Mutable picker state and operations. UI-free and fully testable headless.
---
---The session owns the source lifecycle. Each (re)start bumps a generation
---counter; emit/finish calls from contexts of older generations are ignored,
---so stale processes cannot corrupt current results.
---
---For refresh = "query" sources the query itself drives the command, so the
---session does not re-filter emitted items locally; for refresh = "once"
---sources a query change re-matches the existing items.

local matcher = require("picky.matcher")
local query_parser = require("picky.query")

---@class PickySession
---@field source PickySource
---@field config table
---@field items PickyItem[]
---@field matches PickyMatch[]
---@field query string
---@field terms PickyTerm[]
---@field active_id string|number?
---@field selected table<string|number, boolean>
---@field loading boolean
---@field error string?
---@field closed boolean
---@field live boolean
---@field cwd string
---@field generation number
---@field auto_id number
---@field timer any? debounce timer (vim.uv timer handle)
---@field on_update fun()
local Session = {}
Session.__index = Session

local M = {}

---@param opts { source: PickySource, config: table?, on_update: fun()? }
---@return PickySession
function M.new(opts)
  local source = assert(opts.source, "picky session: source is required")
  local config = opts.config or require("picky.config").options
  local self = setmetatable({
    source = source,
    config = config,
    on_update = opts.on_update or function() end,
    items = {},
    matches = {},
    query = "",
    terms = {},
    active_id = nil,
    selected = {},
    loading = false,
    error = nil,
    closed = false,
    live = (source.refresh or "once") == "query",
    cwd = source.cwd or assert(vim.uv.cwd()),
    generation = 0,
    auto_id = 0,
    timer = nil,
  }, Session)
  return self
end

function Session:_notify()
  self.on_update()
end

function Session:start()
  self:_restart()
end

---Stop the current source generation and start a new one with the current
---query. Selections and the active id are kept; items re-appearing with the
---same id stay selected.
function Session:_restart()
  if self.closed then
    return
  end
  self.generation = self.generation + 1
  local generation = self.generation
  if self.generation > 1 and self.source.stop then
    self.source:stop()
  end
  self.items = {}
  self.matches = {}
  self.loading = true
  self.error = nil
  local ctx = {
    query = self.query,
    cwd = self.cwd,
    emit = function(items)
      if generation == self.generation and not self.closed then
        self:_on_emit(items)
      end
    end,
    finish = function(err)
      if generation == self.generation and not self.closed then
        self:_on_finish(err)
      end
    end,
  }
  self.source:start(ctx)
  self:_notify()
end

---@param items PickyItem[]
function Session:_on_emit(items)
  local first_new = #self.items + 1
  for _, item in ipairs(items) do
    if item.id == nil then
      -- Persistent identity is irrelevant for items the source did not name.
      self.auto_id = self.auto_id + 1
      item.id = "picky#auto#" .. self.auto_id
    end
    self.items[#self.items + 1] = item
  end
  local new_matches
  if self.live then
    new_matches = {}
    for i = first_new, #self.items do
      new_matches[#new_matches + 1] = { index = i, score = 0, positions = {} }
    end
  else
    new_matches = matcher.match(self.items, self.terms, first_new)
    self:_apply_bonus(new_matches)
    vim.list_extend(self.matches, new_matches)
    matcher.sort(self.matches)
    self:_fix_active()
    self:_notify()
    return
  end
  vim.list_extend(self.matches, new_matches)
  self:_fix_active()
  self:_notify()
end

---@param err string?
function Session:_on_finish(err)
  self.loading = false
  self.error = err
  self:_notify()
end

---Re-match all current items against the current terms (non-live sources).
function Session:_rematch()
  if self.live then
    self.matches = {}
    for i = 1, #self.items do
      self.matches[#self.matches + 1] = { index = i, score = 0, positions = {} }
    end
  else
    self.matches = matcher.match(self.items, self.terms)
    self:_apply_bonus(self.matches)
    matcher.sort(self.matches)
  end
  self:_fix_active()
end

---Add the source's per-item ranking bonus (e.g. frecency) to each match score
---before sorting. No-op for sources without a bonus or in live mode, where the
---source itself owns ordering.
---@param matches PickyMatch[]
function Session:_apply_bonus(matches)
  local bonus = self.source.bonus
  if not bonus then
    return
  end
  for _, m in ipairs(matches) do
    m.score = m.score + (bonus(self.items[m.index]) or 0)
  end
end

---Keep the active id if still visible, otherwise fall back to the first
---match.
function Session:_fix_active()
  if self.active_id ~= nil and self:active_index() > 0 then
    return
  end
  local first = self.matches[1]
  self.active_id = first and self.items[first.index].id or nil
end

---@param query string
function Session:set_query(query)
  if self.closed or query == self.query then
    return
  end
  self.query = query
  self.terms = query_parser.parse(query)
  -- A new query is a new result list: the cursor belongs on the best match,
  -- not wherever the previous query left it. Dropping the active id here
  -- moves the cursor to the top exactly once — _fix_active re-anchors it on
  -- the first results of the new query and keeps it stable across later
  -- chunks.
  self.active_id = nil
  if self.live then
    self:_debounced_restart()
  else
    self:_rematch()
    self:_notify()
  end
end

function Session:_debounced_restart()
  local delay = self.source.debounce or self.config.debounce or 40
  if not self.timer then
    self.timer = assert(vim.uv.new_timer())
  end
  self.timer:stop()
  self.timer:start(delay, 0, function()
    vim.schedule(function()
      self:_restart()
    end)
  end)
end

---1-based position of the active item in `matches`, or 0.
---@return number
function Session:active_index()
  if self.active_id == nil then
    return 0
  end
  for i, m in ipairs(self.matches) do
    if self.items[m.index].id == self.active_id then
      return i
    end
  end
  return 0
end

---@return PickyItem?
function Session:current_item()
  local index = self:active_index()
  local m = self.matches[index]
  return m and self.items[m.index] or nil
end

---Selected items in current visible order, or { current }.
---@return PickyItem[]
function Session:targets()
  local out = {}
  for _, m in ipairs(self.matches) do
    local item = self.items[m.index]
    if self.selected[item.id] then
      out[#out + 1] = item
    end
  end
  if #out == 0 then
    local current = self:current_item()
    if current then
      out[1] = current
    end
  end
  return out
end

---@return number
function Session:selected_count()
  local n = 0
  for _ in pairs(self.selected) do
    n = n + 1
  end
  return n
end

---@param offset number
function Session:move(offset)
  if #self.matches == 0 then
    return
  end
  local index = self:active_index()
  if index == 0 then
    index = 1
  end
  index = math.min(math.max(index + offset, 1), #self.matches)
  self.active_id = self.items[self.matches[index].index].id
  self:_notify()
end

---@param direction 1|-1
function Session:page(direction)
  local size = self.config.page_size or 10
  self:move(size * direction)
end

---@param direction 1|-1
function Session:scroll(direction)
  local n = tonumber((vim.o.mousescroll or ""):match("ver:(%d+)"))
  self:move((n or 3) * direction)
end

function Session:to_first()
  self:move(-#self.matches)
end

function Session:to_last()
  self:move(#self.matches)
end

---Toggle the active item's selection and advance.
function Session:toggle()
  local current = self:current_item()
  local id = current and current.id
  if id == nil then
    return
  end
  if self.selected[id] then
    self.selected[id] = nil
  else
    self.selected[id] = true
  end
  self:move(1)
end

---Invert the selection of every visible item.
function Session:toggle_all()
  for _, m in ipairs(self.matches) do
    local id = self.items[m.index].id
    if id ~= nil then
      if self.selected[id] then
        self.selected[id] = nil
      else
        self.selected[id] = true
      end
    end
  end
  self:_notify()
end

---Restart the source with the current query, keeping selections.
function Session:refresh()
  self:_restart()
end

---@return PickyActionContext
function Session:action_context()
  return {
    current = self:current_item(),
    targets = self:targets(),
    query = self.query,
    cwd = self.cwd,
    close = function() self:close() end,
    refresh = function() self:refresh() end,
  }
end

local navigation = {
  next = function(self) self:move(1) end,
  previous = function(self) self:move(-1) end,
  page_down = function(self) self:page(1) end,
  page_up = function(self) self:page(-1) end,
  scroll_down = function(self) self:scroll(1) end,
  scroll_up = function(self) self:scroll(-1) end,
  first = function(self) self:to_first() end,
  last = function(self) self:to_last() end,
  toggle = Session.toggle,
  toggle_all = Session.toggle_all,
}

---@param action string|fun(ctx: PickyActionContext)
function Session:run_action(action)
  if self.closed then
    return
  end
  if type(action) == "string" then
    local nav = navigation[action]
    if nav then
      nav(self)
      return
    end
    local builtin = require("picky.actions")[action]
    if not builtin then
      vim.notify("picky: unknown action " .. action, vim.log.levels.ERROR)
      return
    end
    action = builtin
  end
  action(self:action_context())
end

---Idempotent: stops the source, cancels timers, and notifies once.
function Session:close()
  if self.closed then
    return
  end
  self.closed = true
  local started = self.generation > 0
  self.generation = self.generation + 1
  if started and self.source.stop then
    pcall(self.source.stop, self.source)
  end
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
  self:_notify()
end

return M

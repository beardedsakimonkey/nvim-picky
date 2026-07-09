---Mutable picker state and operations. UI-free and fully testable headless.
---
---The session owns the source lifecycle. Each (re)start bumps a generation
---counter; emit/finish calls from contexts of older generations are ignored,
---so stale processes cannot corrupt current results.
---
---For refresh = "query" sources the query itself drives the command, so the
---session does not re-filter emitted items locally; for refresh = "once"
---sources a query change re-matches the existing items.
---
---Matching for refresh = "once" sources is incremental and interruptible: each
---pass evaluates items against the current terms in time-sliced batches across
---the event loop (see `_match_step`), so a large list neither blocks the UI nor
---stalls typing. A `match_gen` counter, bumped whenever a new pass starts,
---makes any slice still queued from an older query a no-op, so a query change
---abandons the in-flight match instead of waiting for it.

local history = require("picky.history")
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
---@field active_pinned boolean true after explicit navigation should preserve the active id
---@field selected table<string|number, boolean>
---@field loading boolean
---@field error string?
---@field closed boolean
---@field live boolean
---@field cwd string
---@field generation number source lifecycle generation
---@field match_gen number matching-pass generation; bumped to interrupt a pass
---@field recheck number[] item indices a narrowing pass still has to re-evaluate
---@field recheck_pos number cursor into `recheck`
---@field scan_next number next contiguous item index a pass has yet to evaluate
---@field match_scheduled boolean whether a continuation slice is queued
---@field auto_id number
---@field timer any? debounce timer (vim.uv timer handle)
---@field history_pos number? index into the source's history while a recall walk is active
---@field history_stash string? in-progress query stashed when the walk started
---@field history_recall string? query just recalled, so set_query can tell a recall from typing
---@field on_update fun()
local Session = {}
Session.__index = Session

local M = {}

-- Items evaluated per scheduled matching slice. The first slice of every pass
-- runs inline, so small sources still resolve in one tick; only the overflow of
-- a large list streams across later ticks. Smaller keeps each slice snappier at
-- the cost of more sort/notify passes; `config.match_batch` overrides it.
local MATCH_BATCH = 4000

---True when going from `old_query` to `new_query` can only shrink the result
---set, so we may re-filter the current matches instead of re-scanning every
---item. The caller must also confirm the previous pass evaluated every current
---item (`caught_up`); narrowing from a half-built match set would drop items the
---previous pass had not reached yet. Valid only for a pure append (the new query
---is the old one plus typed characters) where the appended characters keep
---matching monotonic:
---
---  * appending to a fresh term (the old query ended in whitespace) always
---    narrows -- an extra term only adds a constraint;
---  * otherwise the final term grows in place, which stays a subset only when it
---    is a positive, non-suffix-anchored term (fuzzy/exact/prefix). Growing an
---    inverse term widens (`!foo` excludes more than `!foox`), and a typed `$`
---    re-anchors a term to a suffix, neither of which is a subset.
---
---Anything else (backspace, mid-string edits, pastes) falls back to a full
---rematch.
---@param old_query string
---@param old_terms PickyTerm[]
---@param new_query string
---@return boolean
local function can_narrow(old_query, old_terms, new_query)
  if old_query == "" or #new_query <= #old_query or new_query:sub(1, #old_query) ~= old_query then
    return false
  end
  local appended = new_query:sub(#old_query + 1)
  if appended:find("%s") then
    return false
  end
  if old_query:find("%s$") then
    return true
  end
  if appended:find("%$") then
    return false
  end
  local last = old_terms[#old_terms]
  return last ~= nil and (last.kind == "fuzzy" or last.kind == "exact" or last.kind == "prefix")
end

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
    active_pinned = false,
    selected = {},
    loading = false,
    error = nil,
    closed = false,
    live = (source.refresh or "once") == "query",
    cwd = source.cwd or assert(vim.uv.cwd()),
    generation = 0,
    match_gen = 0,
    recheck = {},
    recheck_pos = 1,
    scan_next = 1,
    match_scheduled = false,
    auto_id = 0,
    timer = nil,
    history_pos = nil,
    history_stash = nil,
    history_recall = nil,
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
  self:_reset_match()
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
  if self.live then
    -- Live sources delegate filtering to the command; every item is a match.
    for i = first_new, #self.items do
      self.matches[#self.matches + 1] = { index = i, score = 0, positions = {} }
    end
    self:_fix_active()
    self:_notify()
  elseif not self.match_scheduled then
    -- New items extend the contiguous scan. Run a slice now so the first chunk
    -- renders this tick; a slice already in flight will reach them on its own.
    self:_match_step(self.match_gen)
  end
end

---@param err string?
function Session:_on_finish(err)
  self.loading = false
  self.error = err
  self:_notify()
end

---Reset matching state and start a new pass generation, so any slice still
---queued from the previous pass becomes a no-op (see `_match_step`).
function Session:_reset_match()
  self.match_gen = self.match_gen + 1
  self.matches = {}
  self.recheck = {}
  self.recheck_pos = 1
  self.scan_next = 1
  self.match_scheduled = false
end

---Begin a fresh matching pass against the current terms. `recheck` lists item
---indices to re-evaluate — the previous matches for a narrowing pass, none for
---a full rescan — and `scan_from` is the first contiguous item index to scan: 1
---for a full rescan, or `#items + 1` for a narrow, where only later-arriving
---items still need a first look. The first slice runs inline.
---@param recheck number[]
---@param scan_from number
function Session:_begin_match(recheck, scan_from)
  self:_reset_match()
  self.recheck = recheck
  self.scan_next = scan_from
  self:_match_step(self.match_gen)
end

---Run one matching slice for pass `gen`: evaluate up to `match_batch` items —
---the `recheck` list first, then the contiguous tail from `scan_next` — against
---the current terms, then sort and notify. While work remains it reschedules
---itself onto the event loop. A `gen` other than the live `match_gen` means a
---newer pass has superseded this one, so the slice does nothing; returning
---before touching `match_scheduled` leaves the current pass's own scheduling
---intact.
---@param gen number
function Session:_match_step(gen)
  if self.closed or gen ~= self.match_gen then
    return
  end
  self.match_scheduled = false
  local items, terms = self.items, self.terms
  for _ = 1, (self.config.match_batch or MATCH_BATCH) do
    local i
    if self.recheck_pos <= #self.recheck then
      i = self.recheck[self.recheck_pos]
      self.recheck_pos = self.recheck_pos + 1
    elseif self.scan_next <= #items then
      i = self.scan_next
      self.scan_next = self.scan_next + 1
    else
      break
    end
    local m = matcher.match_item(items[i], terms, i)
    if m then
      self.matches[#self.matches + 1] = m
    end
  end

  matcher.sort(self.matches)
  self:_fix_active()
  self:_notify()

  if self.recheck_pos <= #self.recheck or self.scan_next <= #items then
    self.match_scheduled = true
    vim.schedule(function()
      self:_match_step(gen)
    end)
  end
end

---Keep manually navigated active ids stable; otherwise keep the cursor on the
---first current match as async batches change the sorted order.
function Session:_fix_active()
  if self.active_pinned and self.active_id ~= nil and self:active_index() > 0 then
    return
  end
  local first = self.matches[1]
  self.active_id = first and self.items[first.index].id or nil
end

---History bucket for a session: per source name, so recalled queries carry
---across pickers of the same source.
---@param session PickySession
---@return string
local function history_key(session)
  return session.source.name or ""
end

---Step to the next-older history entry and return it, or nil when there is
---none. The first step stashes the in-progress query so `history_next` can
---walk back to it. The caller displays the returned query; the session's own
---query then follows through the normal `set_query` path.
---@return string?
function Session:history_prev()
  local list = history.get(history_key(self))
  local pos = self.history_pos == nil and #list or self.history_pos - 1
  if pos < 1 then
    return nil
  end
  if self.history_pos == nil then
    self.history_stash = self.query
  end
  self.history_pos = pos
  self.history_recall = list[pos]
  return list[pos]
end

---Step to the next-newer history entry and return it. Stepping past the
---newest entry ends the walk and returns the stashed in-progress query;
---returns nil when no walk is active.
---@return string?
function Session:history_next()
  if self.history_pos == nil then
    return nil
  end
  local list = history.get(history_key(self))
  local query
  if self.history_pos < #list then
    self.history_pos = self.history_pos + 1
    query = list[self.history_pos]
  else
    query = self.history_stash or ""
    self.history_pos = nil
    self.history_stash = nil
  end
  self.history_recall = query
  return query
end

---@param query string
function Session:set_query(query)
  if self.closed or query == self.query then
    return
  end
  -- A recalled query arrives here through the same path as typing (the UI
  -- writes the prompt buffer); `history_recall` tells the two apart. Any
  -- other change means the user edited the query, which ends the history
  -- walk — the next history_prev starts again from the newest entry.
  if query ~= self.history_recall then
    self.history_pos = nil
    self.history_stash = nil
  end
  self.history_recall = nil
  local previous_query, previous_terms = self.query, self.terms
  self.query = query
  self.terms = query_parser.parse(query)
  -- A new query is a new result list: the cursor belongs on the best match,
  -- not wherever the previous query left it. Dropping the active id here
  -- lets _fix_active keep the cursor on the first result until navigation pins
  -- a specific item.
  self.active_id = nil
  self.active_pinned = false
  if self.live then
    self:_debounced_restart()
    return
  end
  -- Narrowing reuses the current match set, so it is sound only when the
  -- previous pass evaluated every current item (`caught_up`); otherwise that
  -- set is still partial and would drop items the pass had not reached. When it
  -- holds and typing only adds constraints, re-check just the survivors instead
  -- of every item — the dominant case, and the one that keeps a full-tree file
  -- list responsive per keystroke.
  local caught_up = self.recheck_pos > #self.recheck and self.scan_next > #self.items
  if caught_up and can_narrow(previous_query, previous_terms, query) then
    local indices = {}
    for i = 1, #self.matches do
      indices[i] = self.matches[i].index
    end
    self:_begin_match(indices, #self.items + 1)
  else
    self:_begin_match({}, 1)
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
  self.active_pinned = true
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

---Idempotent: records the query into history, stops the source, cancels
---timers, and notifies once.
function Session:close()
  if self.closed then
    return
  end
  self.closed = true
  -- Every way out of the picker — picking an item, <Esc>, leaving the prompt —
  -- funnels through here, so this is where a query becomes history.
  history.add(history_key(self), self.query)
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

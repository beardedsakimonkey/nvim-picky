---Matching terms against item fields.
---
---Every term must match at least one searchable field; different terms may
---match different fields. Positions are 1-based byte offsets at the start of
---matched UTF-8 characters. Case folding is ASCII-oriented; non-ASCII bytes
---are compared literally.

---@class PickyMatch
---@field index number index into the session's item array
---@field score number
---@field positions table<string, number[]> matched byte offsets keyed by field

local M = {}

-- Fuzzy scoring weights. A matched character is worth BASE; a run of adjacent
-- matches earns CONSECUTIVE; a match at the start of a word earns BOUNDARY.
-- Each character of gap between two matches costs GAP, so a tight match near
-- the start of the word beats the same characters scattered across the string
-- (e.g. `pl` should rank "plugins.lua" above "picky.lua", where the `l` only
-- matches deep in the ".lua" extension). BOUNDARY stays larger than the gap a
-- short word introduces, so acronym matches like `fb` -> "foo_bar" still win.
local BASE = 1
local CONSECUTIVE = 8
local BOUNDARY = 10
local GAP = 1

local function fold(s)
  return s:lower()
end

---True when the byte before a match position is a word boundary.
---@param byte number?
local function at_boundary(byte)
  if byte == nil then
    return true
  end
  return string.char(byte):match("%w") == nil
end

---True when the byte at this offset starts a UTF-8 character.
local function is_char_start(byte)
  return byte < 0x80 or byte >= 0xC0
end

---Collect character-start byte offsets inside [start, stop] of `value`.
local function char_positions(value, start, stop)
  local out = {}
  for i = start, stop do
    if is_char_start(value:byte(i)) then
      out[#out + 1] = i
    end
  end
  return out
end

---Match one positive term against one field value.
---@param value string raw field value
---@param term PickyTerm
---@return number? score
---@return number[]? positions
local function match_term(value, term)
  local hay = term.case_sensitive and value or fold(value)
  local needle = term.case_sensitive and term.text or fold(term.text)
  local slack = (#hay - #needle) * 0.01

  if term.kind == "exact" then
    local s = hay:find(needle, 1, true)
    if not s then
      return nil
    end
    local score = 20 + (at_boundary(hay:byte(s - 1)) and 10 or 0) - slack
    return score, char_positions(value, s, s + #needle - 1)
  elseif term.kind == "prefix" then
    if hay:sub(1, #needle) ~= needle then
      return nil
    end
    return 30 - slack, char_positions(value, 1, #needle)
  elseif term.kind == "suffix" then
    if #hay < #needle or hay:sub(-#needle) ~= needle then
      return nil
    end
    local s = #hay - #needle + 1
    return 25 - slack, char_positions(value, s, #hay)
  elseif term.kind == "full" then
    if hay ~= needle then
      return nil
    end
    return 40, char_positions(value, 1, #hay)
  end

  -- Fuzzy: greedy leftmost ordered subsequence. Greedy never misses an
  -- existing subsequence; it only affects the score.
  local positions = {}
  local score = 0
  local last = 0
  local from = 1
  for ci = 1, #needle do
    local found = hay:find(needle:sub(ci, ci), from, true)
    if not found then
      return nil
    end
    if is_char_start(value:byte(found)) then
      positions[#positions + 1] = found
    end
    score = score + BASE
    if last > 0 then
      local gap = found - last - 1
      if gap == 0 then
        score = score + CONSECUTIVE
      else
        score = score - gap * GAP
      end
    end
    if at_boundary(hay:byte(found - 1)) then
      score = score + BOUNDARY
    end
    last = found
    from = found + 1
  end
  return score - slack, positions
end

---@param item PickyItem
---@return string[]
local function searchable_fields(item)
  if item.fields then
    return item.fields
  end
  if type(item.text) == "string" then
    return { "text" }
  end
  return {}
end

---Match a single item against parsed terms.
---@param item PickyItem
---@param terms PickyTerm[]
---@param index number
---@return PickyMatch?
function M.match_item(item, terms, index)
  local fields = searchable_fields(item)
  local total = 0
  local positions = {}

  for _, term in ipairs(terms) do
    if term.kind == "inverse" then
      local needle = term.case_sensitive and term.text or fold(term.text)
      for _, field in ipairs(fields) do
        local value = item[field]
        if type(value) == "string" then
          local hay = term.case_sensitive and value or fold(value)
          if hay:find(needle, 1, true) then
            return nil
          end
        end
      end
    else
      local best_score, best_field, best_positions
      for _, field in ipairs(fields) do
        local value = item[field]
        if type(value) == "string" then
          local score, pos = match_term(value, term)
          -- Strict > keeps the first field named in `fields` on ties.
          if score and (best_score == nil or score > best_score) then
            best_score, best_field, best_positions = score, field, pos
          end
        end
      end
      if best_score == nil then
        return nil
      end
      total = total + best_score
      local list = positions[best_field] or {}
      vim.list_extend(list, best_positions or {})
      positions[best_field] = list
    end
  end

  for field, list in pairs(positions) do
    table.sort(list)
    local deduped = {}
    for _, p in ipairs(list) do
      if deduped[#deduped] ~= p then
        deduped[#deduped + 1] = p
      end
    end
    positions[field] = deduped
  end

  return { index = index, score = total, positions = positions }
end

---Match items[first..] against terms. Returns unsorted matches; callers
---merge and call `sort()`.
---@param items PickyItem[]
---@param terms PickyTerm[]
---@param first number?
---@return PickyMatch[]
function M.match(items, terms, first)
  local out = {}
  for i = first or 1, #items do
    local m = M.match_item(items[i], terms, i)
    if m then
      out[#out + 1] = m
    end
  end
  return out
end

---Sort by score descending; equal scores keep source (index) order.
---@param matches PickyMatch[]
function M.sort(matches)
  table.sort(matches, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.index < b.index
  end)
end

return M

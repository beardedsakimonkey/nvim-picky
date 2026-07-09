---Matching terms against item fields.
---
---Every term must match at least one searchable field; different terms may
---match different fields. `fields` order is a ranking signal: a match on an
---earlier field outscores an equal-quality match on a later one (FIELD_RANK).
---Positions are 1-based byte offsets at the start of
---matched UTF-8 characters. Case folding is ASCII-oriented; non-ASCII bytes
---are compared literally.
---
---Fuzzy, exact, and inverse terms scan only the leading `MAX_MATCH_BYTES` of a
---field, so a pathologically long line (a minified bundle's megabyte row) costs
---no more than a normal one; anchored terms (prefix/suffix/full) read a fixed
---slice and stay exact regardless of field size.

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

-- A match gains FIELD_RANK for every field listed after the one it landed in,
-- so `fields` order ranks across items, not just within one: `pick` on the
-- name "picky.lua" outranks the same characters in the dir "lua/picky", which
-- would otherwise tie (same length, boundary, and runs). Kept well below
-- BOUNDARY/CONSECUTIVE so a genuinely better match in a later field still
-- wins; anything above the slack fields typically differ by (< 1) suffices.
local FIELD_RANK = 2

-- Largest field prefix an unanchored term (fuzzy/exact/inverse) will scan. A
-- minified bundle can put a megabyte-long line on screen, and folding plus
-- scanning it on every keystroke stalls the matcher; bounding the window keeps
-- per-item cost flat in the field length. A match past the window is not found
-- -- the price of keeping pathological lines in the list at all. Anchored kinds
-- (prefix/suffix/full) inspect only a short slice or a length, so they stay
-- exact regardless of field size and ignore this cap.
local MAX_MATCH_BYTES = 4096

local function fold(s)
  return s:lower()
end

---The slice of a field an unanchored term scans: the whole value, or its
---leading `MAX_MATCH_BYTES` bytes when it is larger.
local function window(value)
  if #value <= MAX_MATCH_BYTES then
    return value
  end
  return value:sub(1, MAX_MATCH_BYTES)
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
  local cs = term.case_sensitive
  local needle = cs and term.text or fold(term.text)
  -- Slack uses the true field length so a longer field still ranks lower, even
  -- though the search itself only ever folds a bounded slice of it.
  local slack = (#value - #needle) * 0.01

  -- Anchored kinds read a fixed slice or just a length, never the whole field,
  -- so they stay exact and cheap no matter how long the value is.
  if term.kind == "prefix" then
    local head = value:sub(1, #needle)
    if (cs and head or fold(head)) ~= needle then
      return nil
    end
    return 30 - slack, char_positions(value, 1, #needle)
  elseif term.kind == "suffix" then
    local tail = value:sub(-#needle)
    if #value < #needle or (cs and tail or fold(tail)) ~= needle then
      return nil
    end
    local s = #value - #needle + 1
    return 25 - slack, char_positions(value, s, #value)
  elseif term.kind == "full" then
    if #value ~= #needle or (cs and value or fold(value)) ~= needle then
      return nil
    end
    return 40, char_positions(value, 1, #value)
  end

  -- Fuzzy and exact scan the value, so they only ever look at the bounded
  -- window; positions still index the original value, which the window prefixes.
  local win = window(value)
  local hay = cs and win or fold(win)

  if term.kind == "exact" then
    local s = hay:find(needle, 1, true)
    if not s then
      return nil
    end
    local score = 20 + (at_boundary(hay:byte(s - 1)) and 10 or 0) - slack
    return score, char_positions(value, s, s + #needle - 1)
  end

  -- Fuzzy, in two passes. A greedy leftmost scan never misses an existing
  -- subsequence, but scoring it directly punishes early stray characters:
  -- `pick` on "pack/picky.lua" would anchor at the `p` of "pack" and scatter
  -- the rest, burying the item below files that merely lack the stray `p`.
  -- So the forward pass only proves a match and finds the leftmost position
  -- one can end; the backward pass from there takes the tightest match ending
  -- at that point, and that compact match is what gets scored/highlighted.
  local from = 1
  local stop = 0
  for ci = 1, #needle do
    local found = hay:find(needle:sub(ci, ci), from, true)
    if not found then
      return nil
    end
    stop = found
    from = found + 1
  end

  -- Walk back from `stop` re-matching the needle in reverse; every character
  -- is guaranteed to be found at or after its forward-pass position.
  local at = {}
  local pos = stop
  for ci = #needle, 1, -1 do
    local byte = needle:byte(ci)
    while hay:byte(pos) ~= byte do
      pos = pos - 1
    end
    at[ci] = pos
    pos = pos - 1
  end

  local positions = {}
  local score = 0
  local last = 0
  for ci = 1, #needle do
    local found = at[ci]
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
          local hay = window(value)
          hay = term.case_sensitive and hay or fold(hay)
          if hay:find(needle, 1, true) then
            return nil
          end
        end
      end
    else
      local best_score, best_field, best_positions
      for rank, field in ipairs(fields) do
        local value = item[field]
        if type(value) == "string" then
          local score, pos = match_term(value, term)
          if score then
            score = score + (#fields - rank) * FIELD_RANK
            -- Strict > keeps the first field named in `fields` on ties.
            if best_score == nil or score > best_score then
              best_score, best_field, best_positions = score, field, pos
            end
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

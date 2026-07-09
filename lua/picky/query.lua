---Query parsing: a prompt string becomes a list of terms.
---
---Operators (fzf-style):
---  foo    fuzzy match
---  'foo   exact substring
---  ^foo   field prefix
---  foo$   field suffix
---  ^foo$  whole-field match
---  !foo   inverse substring
---
---Smart case: a term is case-sensitive iff it contains an ASCII uppercase
---character.

---@class PickyTerm
---@field kind "fuzzy"|"exact"|"prefix"|"suffix"|"full"|"inverse"
---@field text string
---@field case_sensitive boolean

local M = {}

---Classify one whitespace-delimited word. `anchored` reports whether a
---trailing $ acted as an anchor (rather than staying a literal character).
---@param word string
---@return string kind, string text, boolean anchored
local function classify(word)
  local kind, text = "fuzzy", word
  local head = text:sub(1, 1)
  if head == "'" then
    kind, text = "exact", text:sub(2)
  elseif head == "!" then
    kind, text = "inverse", text:sub(2)
  elseif head == "^" then
    kind, text = "prefix", text:sub(2)
  end
  -- A trailing $ anchors fuzzy terms as suffixes and prefix terms as
  -- whole-field matches. A lone "$" stays a literal character.
  local anchored = false
  if (kind == "fuzzy" or kind == "prefix") and #text > 1 and text:sub(-1) == "$" then
    text = text:sub(1, -2)
    kind = kind == "prefix" and "full" or "suffix"
    anchored = true
  end
  return kind, text, anchored
end

---@param query string?
---@return PickyTerm[]
function M.parse(query)
  local terms = {}
  for word in (query or ""):gmatch("%S+") do
    local kind, text = classify(word)
    if text ~= "" then
      terms[#terms + 1] = {
        kind = kind,
        text = text,
        case_sensitive = text:find("%u") ~= nil,
      }
    end
  end
  return terms
end

---Byte spans of the operator characters in `query`, for highlighting them
---in a prompt line. Only characters `parse` consumes as operators qualify;
---literals (a lone "$", "$" after an exact/inverse term, mid-word "^") don't.
---@param query string?
---@return { from: number, to: number }[] 0-based, end-exclusive spans
function M.operators(query)
  local spans = {}
  local q = query or ""
  local init = 1
  while true do
    local from, to = q:find("%S+", init)
    if from == nil then
      return spans
    end
    init = to + 1
    local kind, _, anchored = classify(q:sub(from, to))
    if kind ~= "fuzzy" and kind ~= "suffix" then
      spans[#spans + 1] = { from = from - 1, to = from }
    end
    if anchored then
      spans[#spans + 1] = { from = to - 1, to = to }
    end
  end
end

return M

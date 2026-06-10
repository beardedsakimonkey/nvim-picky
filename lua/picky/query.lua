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

---@param query string?
---@return PickyTerm[]
function M.parse(query)
  local terms = {}
  for word in (query or ""):gmatch("%S+") do
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
    if (kind == "fuzzy" or kind == "prefix") and #text > 1 and text:sub(-1) == "$" then
      text = text:sub(1, -2)
      kind = kind == "prefix" and "full" or "suffix"
    end
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

return M

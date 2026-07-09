---Per-source query history, kept in memory for the lifetime of the Neovim
---session. Entries are keyed by source name; unnamed sources share one bucket.

local M = {}

---@type table<string, string[]> queries per key, oldest first
local lists = {}

-- Entries kept per key; recording beyond this drops the oldest.
local LIMIT = 100

---Record `query` as the newest entry for `key`. Blank queries are dropped,
---and a query already in the list moves to the newest slot instead of
---appearing twice.
---@param key string
---@param query string
function M.add(key, query)
  if query:find("^%s*$") then
    return
  end
  local list = lists[key]
  if not list then
    list = {}
    lists[key] = list
  end
  for i = #list, 1, -1 do
    if list[i] == query then
      table.remove(list, i)
    end
  end
  list[#list + 1] = query
  if #list > LIMIT then
    table.remove(list, 1)
  end
end

---@param key string
---@return string[] # queries, oldest first; the returned table is live, not a copy
function M.get(key)
  return lists[key] or {}
end

return M

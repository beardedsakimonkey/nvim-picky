---Line parsers for common command output.

local M = {}

---One path per line, e.g. fd output.
---@param line string
---@return PickyItem?
function M.path(line)
  if line == "" then
    return nil
  end
  return { id = line, text = line, path = line }
end

---`path:lnum:col:text` locations, e.g. `rg --vimgrep` output.
---@param line string
---@return PickyItem?
function M.vimgrep(line)
  local path, lnum, col, text = line:match("^(..-):(%d+):(%d+):(.*)$")
  if not path then
    return nil
  end
  return {
    id = ("%s:%s:%s"):format(path, lnum, col),
    path = path,
    lnum = tonumber(lnum),
    col = tonumber(col),
    text = text,
    fields = { "path", "text" },
    display = {
      { field = "path", hl = "Comment" },
      { text = "  " },
      { field = "text" },
    },
  }
end

return M

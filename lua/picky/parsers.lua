---Line parsers and item constructors for common command output and paths.

---@class PickyParsers
local M = {}

---Build an item for a filesystem path that renders as `filename dir`. The
---filename is left unhighlighted (it inherits the result window's PickyNormal)
---and the directory is dimmed with `PickyDir`. The directory is shown relative
---to the cwd, with `~` for the home directory; a file in the cwd root renders
---the filename alone. `name`, `dir`, and the full relative `text` are all
---searchable, so matches highlight on whichever component they land in while
---full-path queries still match.
---@param path string absolute filesystem path
---@param kind string? libuv filesystem type, used to select directory icons
---@return PickyItem
function M.file_item(path, kind)
  local rel = vim.fn.fnamemodify(path, ":~:.")
  local name = vim.fn.fnamemodify(rel, ":t")
  local dir = vim.fn.fnamemodify(rel, ":h")
  local item
  if dir == "." then
    item = {
      text = rel,
      name = name,
      path = path,
      fields = { "name", "text" },
      display = { { field = "name" } },
    }
  else
    item = {
      text = rel,
      name = name,
      dir = dir,
      path = path,
      fields = { "name", "dir", "text" },
      display = {
        { field = "name" },
        { text = " " },
        { field = "dir", hl = "PickyDir" },
      },
    }
  end
  return require("picky.icons").annotate(item, path, kind)
end

---A colorized line, e.g. a command run with `--color=always`. ANSI escape
---codes are stripped from the searchable/displayed `text` and re-expressed as
---`highlights` spans, so the original coloring renders while matching and
---display operate on the clean text.
---@param line string
---@return PickyItem?
function M.ansi(line)
  if line == "" then
    return nil
  end
  local text, highlights = require("picky.ansi").parse(line)
  if text == "" then
    return nil
  end
  return { id = text, text = text, highlights = highlights }
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
      { field = "path", hl = "PickyDir" },
      { text = "  " },
      { field = "text" },
    },
  }
end

return M

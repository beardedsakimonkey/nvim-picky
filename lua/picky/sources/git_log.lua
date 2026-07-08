---Git log source. Emits one structured item per commit, searchable by
---subject, author, short hash, and ref decorations. Items carry `commit`,
---so the built-in openers show the commit in a scratch buffer.

local command = require("picky.sources.command")

---@class PickyGitLogOpts
---@field cwd string?
---@field executable string? defaults to "git"
---@field path string? limit the log to one file or directory
---@field follow boolean? follow renames across history; requires `path`
---@field limit number? maximum number of commits
---@field args string[]? extra git log arguments

---Fields are separated by 0x1f (unit separator); the subject comes last so it
---may contain anything but a newline.
local FORMAT = "%H%x1f%h%x1f%an%x1f%ar%x1f%D%x1f%s"

---@param line string
---@return PickyItem?
local function parse(line)
  local commit, hash, author, date, refs, subject =
    line:match("^(%x+)\31(%x+)\31([^\31]*)\31([^\31]*)\31([^\31]*)\31(.*)$")
  if not commit then
    return nil
  end

  local fields = { "text", "author", "hash" }
  local display = {
    { field = "hash", hl = "PickyGitHash" },
    { text = " " },
  }
  if refs ~= "" then
    fields[#fields + 1] = "refs"
    -- Decorations sit between the hash and the subject, as in --oneline.
    display[#display + 1] = { text = "(", hl = "PickyMuted" }
    display[#display + 1] = { field = "refs", hl = "PickyMuted" }
    display[#display + 1] = { text = ") ", hl = "PickyMuted" }
  end
  display[#display + 1] = { field = "text" }
  display[#display + 1] = { text = "  " }
  display[#display + 1] = { field = "author", hl = "PickyMuted" }
  display[#display + 1] = { text = ", ", hl = "PickyMuted" }
  display[#display + 1] = { field = "date", hl = "PickyMuted" }

  return {
    id = commit,
    commit = commit,
    hash = hash,
    author = author,
    date = date,
    refs = refs ~= "" and refs or nil,
    text = subject,
    fields = fields,
    display = display,
  }
end

---@param opts PickyGitLogOpts?
---@return PickyCommandSource
return function(opts)
  opts = opts or {}
  return command({
    name = "Git log",
    cwd = opts.cwd,
    command = function()
      local cmd = {
        opts.executable or "git",
        "log",
        "--no-show-signature",
        "--pretty=format:" .. FORMAT,
      }
      if opts.limit then
        cmd[#cmd + 1] = "-n"
        cmd[#cmd + 1] = tostring(opts.limit)
      end
      if opts.follow and opts.path then
        cmd[#cmd + 1] = "--follow"
      end
      vim.list_extend(cmd, opts.args or {})
      if opts.path then
        cmd[#cmd + 1] = "--"
        cmd[#cmd + 1] = opts.path
      end
      return cmd
    end,
    parse = parse,
  })
end

---Git status source. Emits one item per file row from regular `git status`,
---preserving Git's colorized long-form display while opening the affected path.

local command = require("picky.sources.command")
local ansi = require("picky.ansi")

---@class PickyGitStatusOpts
---@field cwd string?
---@field executable string? defaults to "git"
---@field untracked "all"|"normal"|"no"? passed to --untracked-files (default "all")
---@field ignored boolean? include ignored files with --ignored
---@field args string[]? extra git status arguments

---@param text string
---@param section string?
---@return string?
local function status_text(text, section)
  if section == "untracked" or section == "ignored" then
    return section
  end
  return text:match("^([^:]+):%s+") or section
end

---@param display_path string
---@param section string?
---@return string
local function target_path(display_path, section)
  if section == "untracked" or section == "ignored" then
    return display_path
  end
  local label, rest = display_path:match("^([^:]+):%s+(.+)$")
  if not label then
    return display_path
  end
  if label == "renamed" or label == "copied" then
    return rest:match("^.* %-> (.+)$") or rest
  end
  return rest
end

---@param spans PickyHighlight[]
---@param shift number
---@return PickyHighlight[]
local function shift_highlights(spans, shift)
  local shifted = {}
  for _, span in ipairs(spans) do
    local from = math.max(span.from - shift, 0)
    local to = span.to - shift
    if to > from then
      shifted[#shifted + 1] = { from = from, to = to, hl = span.hl }
    end
  end
  return shifted
end

---@return fun(line: string): PickyItem?
local function parser()
  local section

  ---@param line string
  ---@return PickyItem?
  return function(line)
    local clean, spans = ansi.parse(line)
    local heading = clean:match("^([^%s].-):$")
    if heading then
      section = heading:lower():gsub(" files$", "")
      return nil
    end
    if clean:sub(1, 1) ~= "\t" then
      return nil
    end

    local text = clean:sub(2)
    if text == "" then
      return nil
    end

    local status = status_text(text, section)
    local path = target_path(text, section)
    return {
      id = ("%s:%s"):format(section or status or "status", text),
      text = text,
      section = section,
      status_text = status,
      path = path,
      rel = path,
      path_display = text,
      fields = { "text", "path", "status_text" },
      highlights = shift_highlights(spans, 1),
    }
  end
end

---@param opts PickyGitStatusOpts?
---@return PickyCommandSource
return function(opts)
  opts = opts or {}
  return command({
    name = "Git status",
    cwd = opts.cwd,
    command = function()
      local cmd = {
        opts.executable or "git",
        "-c",
        "status.relativePaths=true",
        "-c",
        "color.status=always",
        "-c",
        "core.quotePath=false",
        "status",
        "--untracked-files=" .. (opts.untracked or "all"),
      }
      if opts.ignored then
        cmd[#cmd + 1] = "--ignored"
      end
      vim.list_extend(cmd, opts.args or {})
      return cmd
    end,
    parse = parser(),
  })
end

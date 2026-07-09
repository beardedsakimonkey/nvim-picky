---Built-in sources. Specialized helpers are thin compositions of the
---generic command source, parsers, and item constructors.

---@class PickySources
---@field items fun(items?: PickyItem[]): PickySource
---@field command fun(opts: PickyCommandOpts): PickyCommandSource
---@field files fun(opts?: PickyFilesOpts): PickySource
---@field buffers fun(): PickySource
---@field git_status fun(opts?: PickyGitStatusOpts): PickyCommandSource
---@field git_log fun(opts?: PickyGitLogOpts): PickyCommandSource
---@field oldfiles fun(opts?: { limit: number? }): PickySource
---@field grep fun(opts?: PickyGrepOpts): PickyCommandSource
---@field symbols fun(opts?: PickySymbolsOpts): PickySource
---@field help fun(): PickySource
---@field helpgrep fun(opts?: PickyHelpgrepOpts): PickyCommandSource

---@type PickySources
return {
  items = require("picky.sources.items"),
  command = require("picky.sources.command"),
  files = require("picky.sources.files"),
  buffers = require("picky.sources.buffers"),
  git_status = require("picky.sources.git_status"),
  git_log = require("picky.sources.git_log"),
  oldfiles = require("picky.sources.oldfiles"),
  grep = require("picky.sources.grep"),
  symbols = require("picky.sources.symbols"),
  help = require("picky.sources.help"),
  helpgrep = require("picky.sources.helpgrep"),
}

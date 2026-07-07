---Built-in sources. Specialized helpers are thin compositions of the
---generic command source, parsers, and item constructors.

return {
  items = require("picky.sources.items"),
  command = require("picky.sources.command"),
  files = require("picky.sources.files"),
  buffers = require("picky.sources.buffers"),
  git_status = require("picky.sources.git_status"),
  oldfiles = require("picky.sources.oldfiles"),
  grep = require("picky.sources.grep"),
  symbols = require("picky.sources.symbols"),
  help = require("picky.sources.help"),
}

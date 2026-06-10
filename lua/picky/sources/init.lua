---Built-in sources. Specialized helpers are thin compositions of the
---generic command source, parsers, and item constructors.

return {
  items = require("picky.sources.items"),
  command = require("picky.sources.command"),
  files = require("picky.sources.files"),
  buffers = require("picky.sources.buffers"),
  oldfiles = require("picky.sources.oldfiles"),
  grep = require("picky.sources.grep"),
  help = require("picky.sources.help"),
}

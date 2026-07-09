---Shared type definitions. This module has no runtime content.

---An item emitted by a source. Picky reserves only `id`, `text`, `fields`,
---and `display`; all other keys belong to the source and are preserved
---unchanged.
---@class PickyItem
---@field id string|number?
---@field text string?
---@field fields string[]? searchable top-level string fields, most important first (earlier fields rank higher), default { "text" }
---@field display string|PickyDisplayChunk[]?
---@field highlights PickyHighlight[]? line-relative color spans (e.g. parsed from ANSI), painted below PickyMatch
---@field [string] any source-owned data (path, bufnr, tag, lnum, col, ...)

---A color span over the rendered line. Offsets are 0-based byte columns into
---the concatenated display line, end-exclusive.
---@class PickyHighlight
---@field from number
---@field to number
---@field hl string highlight group name

---A display chunk has either `field` or `text`, not both. A field chunk
---renders the exact top-level item value, which lets the renderer translate
---match positions into highlights. `hl` applies a highlight group to the
---rendered chunk.
---@class PickyDisplayChunk
---@field text string?
---@field field string?
---@field hl string?

---@class PickySourceContext
---@field query string
---@field cwd string
---@field emit fun(items: PickyItem[])
---@field finish fun(error: string?)

---@class PickySource
---@field name string?
---@field cwd string?
---@field refresh "once"|"query"?
---@field debounce number?
---@field start fun(self: PickySource, ctx: PickySourceContext)
---@field stop fun(self: PickySource)?

---@class PickyActionContext
---@field current PickyItem?
---@field targets PickyItem[]
---@field query string
---@field cwd string
---@field close fun()
---@field refresh fun()

return {}

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
---@field preview boolean|fun(self: PickySource, item: PickyItem, ctx: PickyPreviewContext): boolean?? `false` disables the preview pane for this source; a function renders custom previews (return truthy when handled, falsy to fall through to the built-in field dispatch)
---@field start fun(self: PickySource, ctx: PickySourceContext)
---@field stop fun(self: PickySource)?

---Passed to a source's custom `preview` function. `buf` is a reusable scratch
---buffer already displayed in `win` and made modifiable for the call.
---@class PickyPreviewContext
---@field buf number
---@field win number
---@field cwd string?

---@class PickyActionContext
---@field current PickyItem?
---@field targets PickyItem[]
---@field query string
---@field cwd string
---@field close fun()
---@field refresh fun()

return {}

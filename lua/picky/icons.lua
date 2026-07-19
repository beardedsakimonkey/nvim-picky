---Optional file-type icons via nvim-web-devicons. When the plugin is absent or
---icons are disabled, every entry point is a no-op and items render exactly as
---before.

local config = require("picky.config")

local M = {}

local DIRECTORY_ICON = ""

---`nil` until first probed, then the devicons module or `false` if unavailable.
local provider

local function devicons()
  if provider == nil then
    local ok, mod = pcall(require, "nvim-web-devicons")
    provider = ok and mod or false
  end
  return provider or nil
end

---Test-only: inject a devicons-like provider, `false` to force absence, or
---`nil` to re-probe the real module.
---@param p table|false|nil
function M._set_provider(p)
  provider = p
end

---Glyph and highlight group for a filename or path. nvim-web-devicons does not
---provide directory icons, so directories use a matching built-in glyph.
---@param name string
---@param kind string? libuv filesystem type
---@return string?, string?
function M.get(name, kind)
  local mod = devicons()
  if not mod then
    return nil
  end
  if kind == "directory" then
    return DIRECTORY_ICON, "Directory"
  end
  local base = name:match("[^/]*$") or name
  local ext = base:match("%.([^.]+)$") or ""
  return mod.get_icon(base, ext, { default = true })
end

---Prepend a highlighted file-type icon to an item's display, materialize an
---implicit `text` display into chunks, and shift any line-relative
---`highlights` (e.g. ANSI spans) past the icon prefix. A no-op when icons are
---inactive, no glyph is found, or the display is an opaque string.
---@param item PickyItem
---@param name string? lookup name; defaults to item.path/name/text
---@param kind string? libuv filesystem type
---@return PickyItem
function M.annotate(item, name, kind)
  if not config.options.icons then
    return item
  end
  local display = item.display
  if type(display) == "string" then
    return item
  end
  name = name or item.path or item.name or item.text
  if type(name) ~= "string" or name == "" then
    return item
  end
  local icon, hl = M.get(name, kind)
  if not icon then
    return item
  end

  item.display = vim.list_extend({
    { text = icon, hl = hl },
    { text = " " },
  }, display or { { field = "text" } })

  local shift = #icon + 1
  for _, span in ipairs(item.highlights or {}) do
    span.from = span.from + shift
    span.to = span.to + shift
  end
  return item
end

return M

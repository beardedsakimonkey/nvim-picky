---LSP symbols. By default lists document symbols for the buffer that was
---current when the source was created (creation time matters: the picker's
---prompt buffer is current by the time the source starts) and picky filters
---locally. With `workspace` the source is live: each query change re-issues
---a workspace/symbol request and the server does the filtering.

local config = require("picky.config")

---@class PickySymbolsOpts
---@field workspace boolean? live workspace-wide search instead of document symbols
---@field bufnr number? document mode: buffer to query (default: current at creation)
---@field kinds string[]? SymbolKind names to keep, e.g. { "Function", "Method" }
---@field debounce number? workspace mode: delay before re-querying

---@param kind number?
---@return string
local function kind_name(kind)
  return vim.lsp.protocol.SymbolKind[kind] or "Unknown"
end

local kind_icons = {
  Text = "󰉿",
  Method = "󰆧",
  Function = "󰊕",
  Constructor = "",
  Field = "󰜢",
  Variable = "󰀫",
  Class = "󰠱",
  Interface = "",
  Module = "",
  Property = "󰜢",
  Unit = "󰑭",
  Value = "󰎠",
  Enum = "",
  Keyword = "󰌋",
  Snippet = "",
  Color = "󰏘",
  File = "󰈙",
  Reference = "󰈇",
  Folder = "󰉋",
  EnumMember = "",
  Constant = "󰏿",
  Struct = "󰙅",
  Event = "",
  Operator = "󰆕",
  TypeParameter = "󰊄",
  Unknown = "󰈚",
}

---@return string field, string separator
local function kind_display()
  if config.options.icons then
    return "kind_icon", " "
  end
  return "kind", "  "
end

---1-based byte column for an LSP position in a loaded buffer.
---@param bufnr number
---@param position { line: number, character: number }
---@param encoding string?
---@return number
local function byte_col(bufnr, position, encoding)
  local line = vim.api.nvim_buf_get_lines(bufnr, position.line, position.line + 1, false)[1]
  if not line then
    return position.character + 1
  end
  local ok, col = pcall(vim.str_byteindex, line, encoding or "utf-16", position.character, false)
  return (ok and col or position.character) + 1
end

---@param client_id number
---@param name string
---@param kind string
---@param container string?
---@param target table location fields (`bufnr` or `path`/`rel`, `lnum`, `col`)
---@param dim "container"|"rel" context field rendered dimmed after the name
---@return PickyItem
local function symbol_item(client_id, name, kind, container, target, dim)
  local kind_field, kind_separator = kind_display()
  local item = {
    id = ("%s:%s:%s:%s:%s"):format(client_id, target.path or target.bufnr, target.lnum or 0, target.col or 0, name),
    text = name,
    kind = kind,
    kind_icon = kind_icons[kind] or kind_icons.Unknown,
    container = container,
    fields = { "text", "kind", "container" },
    display = {
      { field = kind_field, hl = "PickyKind" },
      { text = kind_separator },
      { field = "text" },
    },
  }
  for key, value in pairs(target) do
    item[key] = value
  end
  if item[dim] then
    item.display[#item.display + 1] = { text = "  " }
    item.display[#item.display + 1] = { field = dim, hl = "PickyDir" }
  end
  return item
end

---Convert a documentSymbol response. Handles both result shapes: hierarchical
---DocumentSymbol[] (positions in the request buffer, flattened depth-first
---with the parent name as container) and flat SymbolInformation[] (each with
---a full location whose uri may point outside the buffer). A symbol filtered
---out by `keep` still contributes its children.
---@return PickyItem[]
local function doc_items(result, bufnr, encoding, client_id, keep, container, items)
  items = items or {}
  for _, symbol in ipairs(result) do
    local kind = kind_name(symbol.kind)
    local kept = not keep or keep[kind]
    if symbol.selectionRange then
      if kept then
        local pos = symbol.selectionRange.start
        items[#items + 1] = symbol_item(client_id, symbol.name, kind, container, {
          bufnr = bufnr,
          lnum = pos.line + 1,
          col = byte_col(bufnr, pos, encoding),
        }, "container")
      end
      if symbol.children then
        doc_items(symbol.children, bufnr, encoding, client_id, keep, symbol.name, items)
      end
    elseif symbol.location and kept then
      local pos = symbol.location.range and symbol.location.range.start
      items[#items + 1] = symbol_item(client_id, symbol.name, kind, symbol.containerName, {
        path = vim.uri_to_fname(symbol.location.uri),
        lnum = pos and pos.line + 1 or nil,
        col = pos and pos.character + 1 or nil,
      }, "container")
    end
  end
  return items
end

---Convert a workspace/symbol response (SymbolInformation[]; a location
---without a range is tolerated, the item then opens the file without a
---jump). Columns are the character+1 approximation since target files are
---usually not loaded.
---@return PickyItem[]
local function ws_items(result, cwd, client_id, keep)
  local items = {}
  for _, symbol in ipairs(result) do
    local kind = kind_name(symbol.kind)
    if not keep or keep[kind] then
      local path = vim.uri_to_fname(symbol.location.uri)
      local range = symbol.location.range
      items[#items + 1] = symbol_item(client_id, symbol.name, kind, symbol.containerName, {
        path = path,
        rel = vim.fs.relpath(cwd, path) or vim.fn.fnamemodify(path, ":~"),
        lnum = range and range.start.line + 1 or nil,
        col = range and range.start.character + 1 or nil,
      }, "rel")
    end
  end
  return items
end

---@param opts PickySymbolsOpts?
---@return PickySource
return function(opts)
  opts = opts or {}
  local workspace = opts.workspace == true
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local method = workspace and "workspace/symbol" or "textDocument/documentSymbol"
  local keep
  if opts.kinds then
    keep = {}
    for _, kind in ipairs(opts.kinds) do
      keep[kind] = true
    end
  end

  local cancels = {}
  local source = {
    name = workspace and "Workspace symbols" or "Symbols",
    refresh = workspace and "query" or "once",
    debounce = opts.debounce,
  }

  function source:start(ctx)
    cancels = {}
    local clients = vim.lsp.get_clients({ bufnr = bufnr, method = method })
    if workspace and #clients == 0 then
      -- Any attached client can answer a workspace-wide query.
      clients = vim.lsp.get_clients({ method = method })
    end
    if #clients == 0 then
      ctx.finish("no LSP client supports " .. method)
      return
    end
    -- Results stream in per client; the source errors only when every
    -- client failed. Stale responses after a restart are dropped by the
    -- session's generation guard.
    local remaining, errors, succeeded = #clients, {}, false
    local function step(err)
      remaining = remaining - 1
      if err then
        errors[#errors + 1] = err
      else
        succeeded = true
      end
      if remaining == 0 then
        cancels = {}
        ctx.finish(not succeeded and table.concat(errors, "; ") or nil)
      end
    end
    for _, client in ipairs(clients) do
      local params = workspace and { query = ctx.query }
        or { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
      local ok, request_id = client:request(method, params, function(err, result)
        if not err and result and #result > 0 then
          ctx.emit(
            workspace and ws_items(result, ctx.cwd, client.id, keep)
              or doc_items(result, bufnr, client.offset_encoding, client.id, keep)
          )
        end
        step(err and ("%s: %s"):format(client.name, err.message or tostring(err)) or nil)
      end, workspace and nil or bufnr)
      if ok and request_id then
        cancels[#cancels + 1] = function()
          client:cancel_request(request_id)
        end
      elseif not ok then
        step(client.name .. ": request failed")
      end
    end
  end

  function source:stop()
    for _, cancel in ipairs(cancels) do
      pcall(cancel)
    end
    cancels = {}
  end

  return source
end

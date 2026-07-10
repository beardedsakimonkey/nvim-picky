# picky

A small, dependency-free picker for Neovim built around structured items.

## Requirements

- Neovim 0.12 or newer
- `grep` for `picky.sources.grep()` and `picky.helpgrep()` (normally provided by
  the operating system); [`ripgrep`](https://github.com/BurntSushi/ripgrep) is
  used when available
- `git` for `picky.sources.git_status()` and `picky.sources.git_log()`
- [`nvim-web-devicons`](https://github.com/nvim-tree/nvim-web-devicons)
  (optional) for file-type icons

## Setup

Add the repository to Neovim's runtime path, then optionally configure global
defaults:

```lua
local picky = require("picky")

picky.setup({
  window = {
    border = "single",
    width = 0.7,
    height = 0.8,
    input_position = "top",
  },
  keymaps = {
    ["<CR>"] = "edit",
    ["<C-l>"] = "vsplit",
    ["<Esc>"] = "close",
  },
})
```

`setup()` is optional. Options passed to `open()` override global defaults:

```lua
picky.open({
  source = picky.sources.files(),
  window = {
    width = 0.9,
  },
})
```

`window.width` and `window.height` are read as a fraction of the editor size
when `<= 1`, or as an absolute number of columns/rows when `> 1` (e.g.
`width = 120`, `height = 30`).

`open()` is the only picker entry point. A source decides whether it loads once
or restarts when the query changes.

## Built-In Sources

```lua
local picky = require("picky")

-- All listed buffers.
picky.buffers()

-- Existing files from vim.v.oldfiles.
picky.oldfiles({ limit = 100 })

-- Changed files from `git status`.
picky.git_status()

-- Commits from `git log`; subject, author, short hash, and ref
-- decorations are all searchable. Enter shows the commit.
picky.git_log()
picky.git_log({ limit = 500 })

-- History of one file, following renames.
picky.git_log({ path = vim.api.nvim_buf_get_name(0), follow = true })

-- Files below cwd.
picky.files({
  cwd = vim.fn.getcwd(),
  hidden = false,
  follow = false,
  ignore = { ".git", "node_modules" },
})

-- Structured text-search locations (ripgrep when available, otherwise grep).
picky.grep({
  pattern = "update_input",
  cwd = vim.fn.getcwd(),
  fixed_strings = true,
  smart_case = true,
  paths = { "." },
})

-- Help tags, or live text search through runtime documentation.
picky.help()
picky.helpgrep()

-- LSP symbols: document symbols for the current buffer, or a live
-- workspace-wide search that re-queries the server on each keystroke.
picky.symbols()
picky.symbols({ workspace = true })
```

`grep()` prefers `rg` when available and falls back to `grep`. Set
`executable = "rg"` or `executable = "grep"` to choose explicitly. `args`
contains additional arguments for the selected executable. The fallback uses
extended grep regular expressions (`grep -E`) and the selected grep
implementation's normal recursive-search behavior.
`helpgrep()` accepts the same `executable` choices plus a `debounce` override.
`git_status()` and `git_log()` also accept `args` and `executable`.

`symbols()` also accepts `kinds` (SymbolKind names to keep, e.g.
`{ "Function", "Method" }`), `bufnr` to pick a buffer other than the current
one, and `debounce` for the workspace mode's re-query delay.

## Icons

When [`nvim-web-devicons`](https://github.com/nvim-tree/nvim-web-devicons) is
installed, file-based sources (`files()`, `buffers()`, `oldfiles()`) render a
file-type icon before each entry, colored with the plugin's own highlight
group. The symbols source renders built-in Nerd Font glyphs for LSP symbol
kinds. Disable icons and use plain symbol kind labels with:

```lua
picky.setup({ icons = false })
```

## Preview

A preview pane opens to the right of the prompt and result list and follows the
active item. It understands the same common item fields as the built-in opening
actions: `path` (with `lnum`/`col` centered and highlighted), `bufnr`, `commit`
(via `git show`), and `tag` (the help page at the tag's line). Items without
any of these show a `no preview` placeholder.

```lua
picky.setup({
  preview = {
    enabled = true, -- show the preview pane
    width = 0.5, -- fraction of the picker width, or absolute columns when > 1
    min_width = 40, -- hide the pane when it would be narrower than this
    max_file_bytes = 512 * 1024, -- larger files show a stub
    max_lines = 1000, -- line cap loaded into a preview buffer
    treesitter = true, -- try treesitter highlighting, fall back to :syntax
    debounce = 40, -- ms after the active item changes before refreshing
  },
})
```

The same table can be passed per picker: `picky.grep({ preview = { width = 0.6 } })`.

`<M-p>` toggles the pane while the picker is open; the result list reclaims the
full width. `<C-d>` and `<C-u>` scroll the preview by half a page. Note that
`<C-u>` shadows insert-mode clear-line in the prompt; remove the mapping with
`["<C-u>"] = false` to get it back.

Files are read into unlisted scratch buffers — never loaded as real buffers —
and open buffers are previewed as copies, so no autocmds (LSP, plugins) run
against previews.

A source can opt out of the pane entirely with `preview = false`, or render
custom previews with a function; return a truthy value when handled, or falsy
to fall through to the built-in field dispatch:

```lua
local source = picky.sources.items(items)
source.preview = function(_, item, ctx)
  -- ctx.buf is a reusable scratch buffer already shown in ctx.win.
  vim.api.nvim_buf_set_lines(ctx.buf, 0, -1, false, { "anything: " .. item.text })
  return true
end
```

Individual items can also set `preview = false` to show the placeholder.

## Items

Every source emits item tables. Picky reserves four optional fields:

```lua
{
  id = "lua/picky/session.lua:289:5",
  text = "local function update_input()",
  fields = { "path", "text" },
  display = {
    { field = "path", hl = "Comment" },
    { text = "  " },
    { field = "text" },
  },

  -- Source-owned data is preserved and passed to actions.
  path = "lua/picky/session.lua",
  lnum = 289,
  col = 5,
}
```

- `id` preserves active and selected items across filtering and refreshes.
- `fields` lists searchable string fields. It defaults to `{ "text" }`.
- `display` is a string or a list of `{ field, hl }` and `{ text, hl }` chunks.
- `text` is the default searchable and displayed value.

`display` is deliberately data rather than a callback. Field chunks let Picky
map match positions directly to rendered columns, while derived presentation
values can be materialized as ordinary item fields. All other keys remain
source-owned and are available unchanged in action handlers.

Open static items with `picky.sources.items()`:

```lua
picky.open({
  source = picky.sources.items({
    {
      id = "README.md",
      name = "README.md",
      path = "README.md",
      fields = { "name", "path" },
      display = {
        { field = "name" },
        { text = "  " },
        { field = "path", hl = "Comment" },
      },
    },
  }),
})
```

Built-in opening actions understand these common source fields:

- `path`
- `bufnr`
- `tag`
- `commit` — a git commit hash, shown via `git show` in a scratch buffer
- `lnum` and `col`
- `end_lnum` and `end_col` for quickfix entries

## Queries

All terms must match, but each term may match any field named in `fields`.
Different terms may match different fields.

For an item with `fields = { "path", "text" }`, this query can match `.lua$`
against `path` and `update_input` against `text`:

```text
.lua$ update_input
```

Supported operators:

- `foo`: fuzzy match
- `'foo`: exact substring
- `^foo`: field prefix
- `foo$`: field suffix
- `!foo`: inverse substring

Matching uses smart case. Lowercase terms are case-insensitive; terms containing
uppercase characters are case-sensitive.

## Actions And Keymaps

Keymap values are built-in action names, action functions, or `false` to remove
a default mapping.

Built-in actions are `edit`, `split`, `vsplit`, `tabedit`, `quickfix`, and
`close`. Navigation actions are `next`, `previous`, `page_down`, `page_up`,
`scroll_down`, `scroll_up`, `first`, `last`, `toggle`, and `toggle_all`.
Preview actions are `toggle_preview` (`<M-p>`), `preview_scroll_down` (`<C-d>`),
and `preview_scroll_up` (`<C-u>`).

History actions are `history_prev` and `history_next`, on `<C-p>` and `<C-n>`
by default. A picker records its query when it closes — picking an item with
`<CR>` and quitting with `<Esc>` both count — and `history_prev` recalls those
queries in later pickers. History is kept per source name and lasts for the
Neovim session. Stepping past the newest entry with `history_next` restores
whatever was typed before the recall started.

Action functions receive the original emitted items:

```lua
picky.open({
  source = picky.sources.buffers(),
  keymaps = {
    ["<C-d>"] = function(ctx)
      for _, item in ipairs(ctx.targets) do
        vim.api.nvim_buf_delete(item.bufnr, {})
      end
      ctx.refresh()
    end,
  },
})
```

The action context contains:

```lua
{
  current = current_item,
  targets = selected_items_or_current,
  query = "current prompt",
  cwd = "source working directory",
  close = function() end,
  refresh = function() end,
}
```

Actions keep the picker open unless they call `ctx.close()`. Selected targets
are returned in visible order.

## Highlights

Picky defines its own highlight groups so you can restyle the picker without
touching global groups like `NormalFloat`. Every group is a `default` link, so
your own definition wins:

```lua
-- Give the picker its own background and a dimmer directory color.
vim.api.nvim_set_hl(0, "PickyNormal", { bg = "#11131a" })
vim.api.nvim_set_hl(0, "PickyDir", { link = "NonText" })
```

| Group           | Links to      | Used for                              |
| --------------- | ------------- | ------------------------------------- |
| `PickyNormal`   | `NormalFloat` | result/prompt window text, background |
| `PickyBorder`   | `FloatBorder` | result/prompt window border           |
| `PickyMatch`    | `Special`     | matched characters                    |
| `PickyDir`      | `Comment`     | directory and path context            |
| `PickyMuted`    | `Comment`     | dimmed secondary context              |
| `PickyKind`     | `Type`        | symbol kind glyphs                    |
| `PickyGitHash`  | `Identifier`  | commit hashes                         |
| `PickyBufVisible` | `Statement` | name of a buffer on screen in a window |
| `PickySelected` | `Visual`      | multi-selected rows                   |
| `PickyPreviewLine` | `Visual`   | the target line in the preview pane   |
| `PickyPrompt`   | `Comment`     | the `>` prompt symbol                 |
| `PickyOperator` | `Operator`    | query operators typed in the prompt   |
| `PickyCounter`  | `Comment`     | the `n/total` counter                 |
| `PickyError`    | `ErrorMsg`    | source error text                     |
| `PickyEmpty`    | `Comment`     | the `no results` placeholder          |

## Custom Command Sources

Commands are argument arrays, not shell strings. A command source may load once
or restart for every query:

```lua
picky.open({
  source = picky.sources.command({
    name = "Files",
    cwd = vim.fn.getcwd(),
    refresh = "query",
    debounce = 40,
    command = function(ctx)
      return {
        "fd",
        "--color=never",
        "--type=file",
        "--fixed-strings",
        "--",
        ctx.query,
        ".",
      }
    end,
    parse = picky.parsers.path,
  }),
})
```

The parser receives each complete output line and the source context. It may
return one item, a list of items, or `nil`. Command options also include `env`,
`success_codes`, and `skip_empty_query`.

Picky exposes `picky.parsers.path` and `picky.parsers.vimgrep` for common command
output.

For a fully custom source, implement:

```lua
local source = {
  name = "Example",
  cwd = vim.fn.getcwd(),
  refresh = "once", -- or "query"
  debounce = 40,
}

function source:start(ctx)
  ctx.emit({ { id = "one", text = "one", custom = true } })
  ctx.finish()
end

function source:stop()
  -- Cancel pending work.
end
```

Stale callbacks from stopped source generations are ignored.

## Testing

```sh
make test
```

CI tests the current stable release and nightly (Neovim 0.12+).

## License

MIT

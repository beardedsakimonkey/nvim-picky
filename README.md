# picky

A small, dependency-free picker for Neovim built around structured items.

## Requirements

- Neovim 0.12 or newer
- [`fd`](https://github.com/sharkdp/fd) for `picky.sources.files()`
- [`ripgrep`](https://github.com/BurntSushi/ripgrep) for
  `picky.sources.grep()` and live help search

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
  source = picky.sources.files({
    live = true,
    limit = 100,
  }),
  window = {
    width = 0.9,
  },
})
```

`open()` is the only picker entry point. A source decides whether it loads once
or restarts when the query changes.

## Built-In Sources

```lua
local picky = require("picky")

-- Listed buffers, excluding the current buffer.
picky.open({ source = picky.sources.buffers() })

-- Existing files from vim.v.oldfiles.
picky.open({ source = picky.sources.oldfiles({ limit = 100 }) })

-- Files below cwd. Set live=true to restart fd for each query.
picky.open({
  source = picky.sources.files({
    cwd = vim.fn.getcwd(),
    live = true,
    hidden = false,
    follow = false,
    limit = 100,
  }),
})

-- Structured ripgrep locations.
picky.open({
  source = picky.sources.grep({
    pattern = "update_input",
    cwd = vim.fn.getcwd(),
    fixed_strings = true,
    smart_case = true,
    paths = { "." },
  }),
})

-- Help tags, or live text search through runtime documentation.
picky.open({ source = picky.sources.help() })
picky.open({ source = picky.sources.help({ live = true }) })
```

`files()` accepts additional `fd` arguments through `args`. `grep()` accepts
additional `rg` arguments through `args`. Both accept `executable` to override
the command name.

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
| `PickySelected` | `Visual`      | multi-selected rows                   |
| `PickyPrompt`   | `Comment`     | the `>` prompt symbol                 |
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

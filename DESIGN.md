# picky Design

## Goals

- Keep the plugin small, understandable, and dependency-free.
- Provide one picker API for static and query-driven sources.
- Represent results as structured items rather than encoded strings.
- Make queries work naturally across multiple item fields.
- Separate source execution, matching, session state, rendering, and actions.
- Preserve stable ordering as results are filtered or refreshed; the cursor
  follows its item, except on a query change, where it returns to the top
  match once the new results arrive.
- Make the core behavior testable without opening a UI.

## Public API

The plugin exposes two public functions:

```lua
local picky = require("picky")

picky.setup({
  window = {
    border = "single",
    width = 0.7,
    height = 0.8,
  },
  keymaps = {
    ["<CR>"] = "edit",
    ["<C-l>"] = "vsplit",
    ["<Esc>"] = "close",
  },
})

picky.open({
  source = picky.sources.files(),
})
```

`setup()` is optional and establishes global defaults when called. `open()` works
with built-in defaults without requiring setup. Options passed to `open()`
override global defaults using normal override semantics.

`open()` is the only picker entry point. Static and live behavior are properties
of the source, not separate picker APIs.

## Structured Items

Every source emits item tables. The item is the canonical source object: matching,
rendering, previews, and actions all operate on the same table. Picky reserves
only `id`, `text`, `fields`, and `display`; all other keys belong to the source.

```lua
---@class PickyItem
---@field id string|number?
---@field text string?
---@field fields string[]?
---@field display string|PickyDisplayChunk[]?
```

Unknown fields must be preserved unchanged. Common items can therefore carry
action metadata directly:

```lua
{
  id = "lua/picky/session.lua:289:5",
  path = "lua/picky/session.lua",
  lnum = 289,
  col = 5,
  text = "local function update_input()",
  fields = { "path", "text" },
}
```

This follows the useful part of `mini.pick`'s item model: source-specific values
remain on the actual item instead of being copied into a separate action payload.

### Identity

`id` identifies an item across filtering, sorting, and source refreshes. It is
used to preserve selections and, where appropriate, the active item. Selections
survive everything; the active item survives refreshes and incremental result
chunks, but a query change resets the cursor to the top match.

Examples:

```lua
id = path
id = bufnr
id = path .. ":" .. lnum .. ":" .. col
```

The source should assign a meaningful ID when items can be refreshed. The plugin
may assign an ID for simple static items where persistent identity is irrelevant.

### Search Fields

`fields` lists top-level item keys whose string values are searchable. The values
must not contain ANSI sequences or formatting separators.

A file item can expose:

```lua
{
  id = "lua/picky/session.lua",
  name = "main.lua",
  path = "lua/picky/session.lua",
  fields = { "name", "path" },
}
```

A grep item can expose:

```lua
{
  id = "lua/picky/session.lua:289:5",
  path = "lua/picky/session.lua",
  text = "local function update_input()",
  lnum = 289,
  col = 5,
  fields = { "path", "text" },
}
```

If `fields` is omitted and `text` is present, it defaults to `{ "text" }`.
Fields are independent of display order. A source may display a basename before
its directory while still exposing the complete path for searching and actions.

### Display

`display` controls what is rendered. If it is omitted, `text` is used. A simple
item can therefore be:

```lua
{ id = "main.lua", text = "main.lua", path = "main.lua" }
```

Rich display is represented as chunks:

```lua
---@class PickyDisplayChunk
---@field text string?
---@field field string?
---@field hl string?

display = {
  { field = "name" },
  { text = "  " },
  { field = "path", hl = "Comment" },
}
```

A chunk has either `field` or `text`, not both. A field chunk renders the exact
top-level item value, which lets the renderer translate match positions into
highlights without an extra mapping callback. Sources that need derived display
text should materialize it as another item field.

`hl` applies a highlight group to the rendered chunk.

### Icons

File-type icons are an optional enhancement layered on the same data model. When
`nvim-web-devicons` is installed, file-based sources call `picky.icons.annotate`,
which prepends a `{ text = icon, hl = hl }` chunk. The annotation is a
no-op when the plugin is absent or `picky.setup({ icons = false })` disabled it,
so the core stays dependency-free. When an item already carries line-relative
`highlights` (such as ANSI spans), they are shifted past the icon prefix so
coloring stays aligned.

This representation should be kept deliberately small. More complex rendering
can be introduced only when a real source requires it.

### Common Item Fields

Actions inspect source fields directly. Picky should recognize a small set of
common keys so built-in actions and future previews work across sources:

Examples:

```lua
-- File
{
  path = "lua/picky/session.lua",
}

-- Grep location
{
  path = "lua/picky/session.lua",
  lnum = 289,
  col = 5,
}

-- Buffer
{
  bufnr = 17,
}

-- Help tag
{
  tag = "nvim_buf_set_lines",
}
```

Location items may additionally use `end_lnum` and `end_col`, following Neovim's
quickfix and diagnostic conventions. These fields are ordinary item data: they
are searched only when named in `fields` and rendered only when referenced by
`display`.

## Query Semantics

The picker has one prompt. It does not expose separate scope prompts.

For each item:

- all query terms must match;
- each term may match any searchable field;
- different terms may match different fields;
- anchors apply to each field independently.

This is AND between terms and OR between fields for each term.

Given:

```lua
{
  path = "lua/picky/session.lua",
  text = "local function update_input()",
  fields = { "path", "text" },
}
```

the query:

```text
.lua$ update_input
```

matches because `.lua$` matches the end of `path` and `update_input` matches
`text`.

This preserves the important grep workflow of entering `.lua$` to show results
from Lua files without introducing scopes or switching prompts.

The initial query language should retain useful fzf-style operators:

- `foo`: fuzzy or source-configured matching;
- `'foo`: exact substring;
- `^foo`: field prefix;
- `foo$`: field suffix;
- `!foo`: inverse substring.

### Matching Result

The matcher should return enough information to rank and highlight an item:

```lua
---@class PickyMatch
---@field index number
---@field score number
---@field positions table<string, number[]>
```

`index` points into the session's item array. `positions` is keyed by field.
The item index provides deterministic tie-breaking, so equal scores retain source
order. Positions are 1-based byte offsets at the start of matched UTF-8
characters, matching Neovim's byte-column APIs. Smart-case detection and folding
are ASCII-oriented; non-ASCII characters are compared byte-for-byte. If a term
matches multiple fields with the same score, the first field named in `fields`
wins.

## Sources

A source owns item production and refresh behavior. The picker should not know
whether items came from a table, Neovim state, or a child process.

The source contract is:

```lua
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
---@field start fun(self, ctx: PickySourceContext)
---@field stop fun(self)?
```

- `start()` begins producing items and may call `ctx.emit()` repeatedly.
- `ctx.finish(error)` marks the current load complete.
- `refresh = "once"` is the default.
- `refresh = "query"` stops and restarts the source when the query changes.
- `debounce` overrides the global query-restart delay for that source.
- `stop()` cancels processes and releases resources before a restart or close.

Using one restartable lifecycle avoids separate `start()` and `update()` paths.
The session must ignore calls from stale source contexts after a restart.
Cancellation, errors, streaming, and refresh remain explicit.

`cwd` is captured when the source is created or the picker starts. Relative
paths are resolved against it, so actions do not depend on Neovim's current
directory remaining unchanged while the picker is open.

### Static Sources

Static sources emit once and finish:

```lua
picky.open({
  source = picky.sources.items({
    {
      id = "README.md",
      text = "README.md",
      path = "README.md",
    },
  }),
})
```

### Live Sources

Live sources restart their work when the query changes:

```lua
picky.open({
  source = picky.sources.command({
    command = function(ctx)
      return {
        "fd",
        "--color=never",
        "--fixed-strings",
        "--max-results=100",
        "--type=file",
        "--",
        ctx.query,
      }
    end,
    refresh = "query",
    debounce = 40,
    parse = picky.parsers.path,
  }),
})
```

Commands should always be represented as argument arrays. The plugin should not
implement shell-like command parsing. Command sources may also configure `cwd`,
`env`, and a line parser returning an item, item list, or `nil`.

### Built-In Sources

```lua
picky.sources.items(items)
picky.sources.command(options)
picky.sources.files(options)
picky.sources.buffers(options)
picky.sources.oldfiles(options)
picky.sources.grep(options)
picky.sources.help(options)
```

Specialized source helpers should remain thin compositions of the generic source,
parser, and item constructors.

`help()` lists help tags by default. `help({ live = true })` runs a debounced
text search over runtime documentation and still emits items with `tag`, allowing
normal actions to open the corresponding help document.

`files()` is a static source: `fd` lists the tree once and the matcher filters
and ranks locally. This keeps ranking in one place — the matcher — so frecency
can contribute to the order alongside fuzzy scoring (a live source, which
delegates filtering to the command and emits unscored items, cannot).

### Frecency

A source may expose `bonus(item) -> number`, a per-item ranking bonus the session
adds to each match's score before sorting (static sources only; live sources own
their own order). `picky.frecency` implements this for file sources.

Each tracked path carries two exponentially-decaying scores: an *access* score
bumped on `BufReadPost`/`BufWinEnter` and a *write* score bumped on
`BufWritePost`. The decay (`score * 0.5 ^ (Δt / half_life)`) folds frequency and
recency into one number per channel, so storage stays O(1) per file with no
timestamp history. A per-channel cooldown coalesces rapid repeats (see the
`COOLDOWN` comment in `frecency.lua`). The combined, weighted score maps through
a saturating curve to a bounded bonus, sized so it cannot overturn a clearly
better text match but, on an empty query where fuzzy scores are equal, orders the
list outright.

State is a single mpack table under `stdpath("state")`, loaded lazily, flushed
debounced and on `VimLeavePre`. Each flush re-reads and merges the on-disk copy
(later timestamp wins per channel) so concurrent Neovim instances do not clobber
each other, and prunes negligible entries to keep the file small. Tracking is
installed by `setup()` and gated by `config.frecency.enabled`.

## Actions and Keymaps

Mapping values are either built-in action names or action functions:

```lua
picky.setup({
  keymaps = {
    ["<CR>"] = "edit",
    ["<C-l>"] = "vsplit",
    ["<C-d>"] = function(ctx)
      for _, item in ipairs(ctx.targets) do
        vim.api.nvim_buf_delete(item.bufnr, {})
      end
      ctx.refresh()
    end,
  },
})
```

Actions receive a context object:

```lua
---@class PickyActionContext
---@field current PickyItem
---@field targets PickyItem[]
---@field query string
---@field cwd string
---@field close fun()
---@field refresh fun()
```

`current` is the active item. `targets` is either the selected items, in visible
order, or a list containing `current`. They are the original full item tables
emitted by the source, not extracted payloads or normalized copies.

`cwd` is the source's captured working directory and is used to resolve relative
item paths.

Actions remain open unless they call `ctx.close()`. Opening a file normally
closes; deleting a buffer can refresh the source and keep it open. This avoids
assigning implicit close behavior to callback return values.

Built-in actions should initially include:

```lua
picky.actions.edit
picky.actions.split
picky.actions.vsplit
picky.actions.tabedit
picky.actions.quickfix
picky.actions.close
```

File-opening actions should understand file and location item data without
requiring every source to implement another completion callback.

## Configuration

The configuration shape is:

```lua
picky.setup({
  window = {
    border = "single",
    width = 0.7,
    height = 0.8,
    input_position = "top",
  },
  keymaps = {
    ["<Esc>"] = "close",
    ["<CR>"] = "edit",
    ["<C-s>"] = "split",
    ["<C-l>"] = "vsplit",
    ["<C-t>"] = "tabedit",
    ["<C-j>"] = "next",
    ["<C-k>"] = "previous",
    ["<Tab>"] = "toggle",
    ["<C-a>"] = "toggle_all",
  },
  debounce = 40,
  match_batch = 4000,
  icons = true,
  frecency = {
    enabled = true,
    path = nil, -- stdpath("state")/picky/frecency.mpack
  },
})
```

`debounce` delays restarting a live source after a keystroke. `match_batch`
caps how many items a local (non-live) source matches per event-loop slice; see
[Incremental Matching](#incremental-matching).

Per-picker options override global options:

```lua
picky.open({
  source = source,
  window = {
    width = 0.9,
  },
  keymaps = {
    ["<C-d>"] = delete_buffer,
  },
})
```

## Session Model

The session owns mutable picker state:

```lua
---@class PickySession
---@field source PickySource
---@field items PickyItem[]
---@field matches PickyMatch[]
---@field query string
---@field active_id string|number?
---@field selected table<string|number, boolean>
---@field loading boolean
---@field error string?
```

The session should expose explicit operations such as:

```lua
session:set_query(query)
session:move(offset)
session:toggle()
session:toggle_all()
session:run_action(action)
session:refresh()
session:close()
```

The UI should call these operations rather than manipulate indexes and tables
directly.

Selections are stored by item ID and returned in current visible order.

The active item is tracked by ID. It stays put as result chunks stream in and
across `refresh()`, but `set_query()` drops it so the cursor lands on the top
match of the new query — exactly once, not on every chunk.

### Incremental Matching

Local (non-live) sources can hold a very large item list — `files()` loads the
whole tree. Matching that list against the query must not block the UI or stall
typing, so each matching pass is incremental and interruptible:

- A pass evaluates items against the current terms in time-sliced batches of
  `config.match_batch` items. The first batch runs inline, so small sources
  still resolve in a single tick; only the overflow streams across later
  event-loop ticks, sorting and rendering progressively as it goes.
- Each pass carries a generation. Starting a new pass bumps it, so any batch
  still queued from an older query becomes a no-op when it runs. A query change
  therefore *abandons* the in-flight match rather than waiting for it — the
  point of the design when the user is typing quickly over a large list.
- A query that only adds constraints re-checks just the previous survivors
  rather than every item (`can_narrow`), but only once the previous pass has
  evaluated every current item; narrowing from a half-built match set could
  drop items it had not reached yet, so that case falls back to a full rescan.

Live sources are unaffected: they delegate filtering to the command and emit
already-ranked items, so the session only collects them.

## UI

The initial UI should remain close to the current two-window design:

- one prompt window;
- one non-focusable result window;
- virtualized rendering of visible results;
- cursor line for the active result;
- match and multiselect highlights.

The UI should explicitly render:

- loading state;
- result count;
- selected count;
- empty state;
- source or process errors.

Rendering should use extmarks for highlights and metadata where practical. Window
autocommands must be scoped to the picker's own windows and cleaned up through a
single idempotent close path.

## Process Execution

- no stdout or stderr handle leaks;
- emit a final unterminated line;
- close resources after spawn failure;
- cancellation that distinguishes stale jobs from current jobs;
- explicit exit status and stderr handling;
- configurable working directory and environment;
- no shell command parsing.

When the minimum supported Neovim version permits it, prefer `vim.system()` over
a custom `vim.uv.spawn()` wrapper.

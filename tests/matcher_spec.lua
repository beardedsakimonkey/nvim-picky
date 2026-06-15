local t = require("helpers")
local matcher = require("picky.matcher")
local query = require("picky.query")

local function match(items, prompt)
  local matches = matcher.match(items, query.parse(prompt))
  matcher.sort(matches)
  return matches
end

local function matched_texts(items, prompt)
  local out = {}
  for _, m in ipairs(match(items, prompt)) do
    out[#out + 1] = items[m.index].text
  end
  return out
end

t.describe("matcher", function()
  t.it("returns all items in source order for an empty query", function()
    local items = { { text = "b" }, { text = "a" } }
    local matches = match(items, "")
    t.eq({ 1, 2 }, { matches[1].index, matches[2].index })
    t.eq({}, matches[1].positions)
  end)

  t.it("fuzzy matches subsequences", function()
    local items = { { text = "session" }, { text = "sources" }, { text = "xyz" } }
    t.eq({ "session", "sources" }, matched_texts(items, "ses"))
  end)

  t.it("ranks a tight match above one scattered across a gap", function()
    -- `pl` should favour "plugins.lua" (p,l adjacent at the start) over
    -- names where the `l` only matches deep in the ".lua" extension, even
    -- though that `l` sits on a word boundary.
    local items = { { text = "picky.lua" }, { text = "plugins.lua" } }
    t.eq("plugins.lua", matched_texts(items, "pl")[1])
  end)

  t.it("ranks a boundary acronym above a non-boundary match", function()
    -- The gap penalty must not bury acronym matches: `fb` should favour
    -- "foo_bar" (both chars start a word) over "fabric" (b mid-word).
    local items = { { text = "fabric" }, { text = "foo_bar" } }
    t.eq("foo_bar", matched_texts(items, "fb")[1])
  end)

  t.it("requires every term to match", function()
    local items = { { text = "foo bar" }, { text = "foo" } }
    t.eq({ "foo bar" }, matched_texts(items, "foo bar"))
  end)

  t.it("matches exact substrings", function()
    local items = { { text = "abc" }, { text = "axbxc" } }
    t.eq({ "abc" }, matched_texts(items, "'abc"))
  end)

  t.it("anchors prefixes", function()
    local items = { { text = "foobar" }, { text = "barfoo" } }
    t.eq({ "foobar" }, matched_texts(items, "^foo"))
  end)

  t.it("anchors suffixes", function()
    local items = { { text = "main.lua" }, { text = "lua.txt" } }
    t.eq({ "main.lua" }, matched_texts(items, ".lua$"))
  end)

  t.it("matches whole fields with ^...$", function()
    local items = { { text = "foo" }, { text = "foobar" } }
    t.eq({ "foo" }, matched_texts(items, "^foo$"))
  end)

  t.it("excludes items on inverse terms", function()
    local items = { { text = "keep this" }, { text = "drop this" } }
    t.eq({ "keep this" }, matched_texts(items, "this !drop"))
  end)

  t.it("uses smart case", function()
    local items = { { text = "README" }, { text = "readme" } }
    t.eq({ "README", "readme" }, matched_texts(items, "'readme"))
    t.eq({ "README" }, matched_texts(items, "'README"))
  end)

  t.it("lets different terms match different fields", function()
    -- The DESIGN example: `.lua$ update_input` against a grep item.
    local items = {
      {
        path = "lua/picky/session.lua",
        text = "local function update_input()",
        fields = { "path", "text" },
      },
      {
        path = "lua/picky/session.rs",
        text = "local function update_input()",
        fields = { "path", "text" },
      },
    }
    local matches = match(items, ".lua$ update_input")
    t.eq(1, #matches)
    t.eq(1, matches[1].index)
    t.ok(matches[1].positions.path, "expected positions on path")
    t.ok(matches[1].positions.text, "expected positions on text")
  end)

  t.it("prefers the first named field on score ties", function()
    local items = { { a = "same", b = "same", fields = { "a", "b" } } }
    local matches = match(items, "'same")
    t.eq({ 1, 2, 3, 4 }, matches[1].positions.a)
    t.eq(nil, matches[1].positions.b)
  end)

  t.it("reports 1-based byte positions", function()
    local items = { { text = "abc" } }
    t.eq({ 1, 2, 3 }, match(items, "'abc")[1].positions.text)
    t.eq({ 2 }, match(items, "'b")[1].positions.text)
  end)

  t.it("reports character-start positions for multibyte text", function()
    -- "ä" is 2 bytes; the position list contains only the lead byte.
    local items = { { text = "xäy" } }
    t.eq({ 1, 2, 4 }, match(items, "'xäy")[1].positions.text)
  end)

  t.it("keeps source order on equal scores", function()
    local items = { { text = "aaa" }, { text = "aaa" }, { text = "aaa" } }
    local matches = match(items, "aaa")
    t.eq({ 1, 2, 3 }, { matches[1].index, matches[2].index, matches[3].index })
  end)

  t.it("defaults fields to text", function()
    local items = { { text = "hello", other = "zzz" } }
    t.eq({}, match(items, "zzz"))
    t.eq(1, #match(items, "hello"))
  end)

  t.it("skips items with no searchable fields for positive terms", function()
    local items = { { path = "no-text-or-fields" } }
    t.eq({}, match(items, "foo"))
    -- but an inverse-only query keeps them
    t.eq(1, #match(items, "!foo"))
  end)
end)

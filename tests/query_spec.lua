local t = require("helpers")
local query = require("picky.query")

t.describe("query.parse", function()
  t.it("parses fuzzy terms", function()
    t.eq({ { kind = "fuzzy", text = "foo", case_sensitive = false } }, query.parse("foo"))
  end)

  t.it("parses multiple terms", function()
    local terms = query.parse("foo bar")
    t.eq(2, #terms)
    t.eq("foo", terms[1].text)
    t.eq("bar", terms[2].text)
  end)

  t.it("parses exact terms", function()
    t.eq({ { kind = "exact", text = "foo", case_sensitive = false } }, query.parse("'foo"))
  end)

  t.it("parses prefix terms", function()
    t.eq({ { kind = "prefix", text = "foo", case_sensitive = false } }, query.parse("^foo"))
  end)

  t.it("parses suffix terms", function()
    t.eq({ { kind = "suffix", text = ".lua", case_sensitive = false } }, query.parse(".lua$"))
  end)

  t.it("parses whole-field terms", function()
    t.eq({ { kind = "full", text = "foo", case_sensitive = false } }, query.parse("^foo$"))
  end)

  t.it("parses inverse terms", function()
    t.eq({ { kind = "inverse", text = "foo", case_sensitive = false } }, query.parse("!foo"))
  end)

  t.it("keeps a lone dollar literal", function()
    t.eq({ { kind = "fuzzy", text = "$", case_sensitive = false } }, query.parse("$"))
  end)

  t.it("drops empty terms", function()
    t.eq({}, query.parse("' ! ^"))
    t.eq({}, query.parse("   "))
    t.eq({}, query.parse(""))
    t.eq({}, query.parse(nil))
  end)

  t.it("detects smart case", function()
    t.eq(false, query.parse("foo")[1].case_sensitive)
    t.eq(true, query.parse("Foo")[1].case_sensitive)
    t.eq(true, query.parse("'Foo")[1].case_sensitive)
  end)
end)

t.describe("query.operators", function()
  t.it("finds no operators in fuzzy terms", function()
    t.eq({}, query.operators("foo bar"))
    t.eq({}, query.operators(""))
    t.eq({}, query.operators(nil))
  end)

  t.it("finds leading operators", function()
    t.eq({ { from = 0, to = 1 } }, query.operators("'foo"))
    t.eq({ { from = 0, to = 1 } }, query.operators("!foo"))
    t.eq({ { from = 0, to = 1 } }, query.operators("^foo"))
  end)

  t.it("finds anchoring trailing dollars", function()
    t.eq({ { from = 4, to = 5 } }, query.operators(".lua$"))
  end)

  t.it("finds both operators of a whole-field term", function()
    t.eq({ { from = 0, to = 1 }, { from = 4, to = 5 } }, query.operators("^foo$"))
  end)

  t.it("keeps literal dollars unhighlighted", function()
    t.eq({}, query.operators("$"))
    t.eq({ { from = 0, to = 1 } }, query.operators("'foo$"))
    t.eq({ { from = 0, to = 1 } }, query.operators("!foo$"))
  end)

  t.it("uses query-relative spans across multiple terms", function()
    t.eq(
      { { from = 0, to = 1 }, { from = 5, to = 6 }, { from = 13, to = 14 } },
      query.operators("'foo ^bar baz$")
    )
  end)
end)

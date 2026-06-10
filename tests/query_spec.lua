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

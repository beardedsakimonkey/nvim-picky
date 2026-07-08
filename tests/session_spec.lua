local t = require("helpers")
local Session = require("picky.session")

local function new_session(source_opts, session_opts)
  local source = t.fake_source(source_opts)
  local session = Session.new(vim.tbl_extend("force", {
    source = source,
    config = { debounce = 5 },
  }, session_opts or {}))
  session:start()
  return session, source
end

local function visible_texts(session)
  local out = {}
  for _, m in ipairs(session.matches) do
    out[#out + 1] = session.items[m.index].text
  end
  return out
end

t.describe("session", function()
  t.it("collects emitted items and tracks loading", function()
    local session, source = new_session()
    t.eq(true, session.loading)
    source.contexts[1].emit({ { id = 1, text = "one" }, { id = 2, text = "two" } })
    source.contexts[1].finish()
    t.eq(false, session.loading)
    t.eq(nil, session.error)
    t.eq({ "one", "two" }, visible_texts(session))
    t.eq(1, session.active_id)
  end)

  t.it("records source errors", function()
    local session, source = new_session()
    source.contexts[1].finish("boom")
    t.eq("boom", session.error)
    t.eq(false, session.loading)
  end)

  t.it("ignores emits from stale generations", function()
    local session, source = new_session()
    local stale = source.contexts[1]
    session:refresh()
    t.eq(2, source.started)
    t.eq(1, source.stopped)
    stale.emit({ { id = 1, text = "stale" } })
    stale.finish("stale error")
    t.eq({}, session.items)
    t.eq(true, session.loading)
    t.eq(nil, session.error)
    source.contexts[2].emit({ { id = 1, text = "fresh" } })
    t.eq({ "fresh" }, visible_texts(session))
  end)

  t.it("re-filters locally on query change for once sources", function()
    local session, source = new_session()
    source.contexts[1].emit({ { id = 1, text = "apple" }, { id = 2, text = "banana" } })
    source.contexts[1].finish()
    session:set_query("app")
    t.eq(1, source.started, "once sources must not restart on query change")
    t.eq({ "apple" }, visible_texts(session))
    session:set_query("")
    t.eq({ "apple", "banana" }, visible_texts(session))
  end)

  t.it("narrows the match set as the query grows", function()
    local session, source = new_session()
    source.contexts[1].emit({
      { id = 1, text = "apple" },
      { id = 2, text = "apply" },
      { id = 3, text = "orange" },
    })
    source.contexts[1].finish()
    session:set_query("a") -- all three contain 'a'
    t.eq({ "apple", "apply", "orange" }, visible_texts(session))
    session:set_query("ap") -- narrows: orange drops
    t.eq({ "apple", "apply" }, visible_texts(session))
    session:set_query("apple") -- narrows further
    t.eq({ "apple" }, visible_texts(session))
    session:set_query("appl") -- backspace: full rematch re-expands
    t.eq({ "apple", "apply" }, visible_texts(session))
  end)

  t.it("re-expands via full rematch when an inverse term widens", function()
    local session, source = new_session()
    source.contexts[1].emit({
      { id = 1, text = "foo" },
      { id = 2, text = "foobar" },
      { id = 3, text = "bar" },
    })
    source.contexts[1].finish()
    session:set_query("!foo") -- exclude anything containing "foo"
    t.eq({ "bar" }, visible_texts(session))
    session:set_query("!foob") -- now only "foobar" is excluded; must re-expand
    t.eq({ "foo", "bar" }, visible_texts(session))
  end)

  t.it("matches a large list incrementally across event-loop slices", function()
    local session, source = new_session(nil, { config = { debounce = 5, match_batch = 10 } })
    local items = {}
    for i = 1, 100 do
      items[i] = { id = i, text = (i % 2 == 0 and "even" or "odd") .. i }
    end
    source.contexts[1].emit(items)
    source.contexts[1].finish()
    -- The first slice runs inline; the rest stream across scheduled slices.
    session:set_query("even")
    t.ok(#session.matches < 50, "the inline slice must not finish the whole list")
    t.wait(function()
      return not session.match_scheduled and #session.matches == 50
    end)
    for _, m in ipairs(session.matches) do
      t.ok(session.items[m.index].text:find("even", 1, true), "only even items match")
    end
  end)

  t.it("abandons an in-flight match when the query changes", function()
    local session, source = new_session(nil, { config = { debounce = 5, match_batch = 1 } })
    source.contexts[1].emit({
      { id = 1, text = "alpha" },
      { id = 2, text = "alpine" },
      { id = 3, text = "beta" },
      { id = 4, text = "gamma" },
    })
    source.contexts[1].finish()
    -- A batch size of 1 forces the pass to span several scheduled slices.
    session:set_query("al") -- starts a pass; only the first item is matched inline
    session:set_query("be") -- supersedes it before the queued slices run
    t.wait(function()
      return not session.match_scheduled
    end)
    -- Slices left over from "al" must not contaminate the "be" results.
    t.eq({ "beta" }, visible_texts(session))
  end)

  t.it("falls back to a full rematch when narrowing from a partial pass", function()
    local session, source = new_session(nil, { config = { debounce = 5, match_batch = 1 } })
    source.contexts[1].emit({
      { id = 1, text = "apple" },
      { id = 2, text = "apply" },
      { id = 3, text = "apex" },
      { id = 4, text = "apt" },
    })
    source.contexts[1].finish()
    session:set_query("a") -- batch 1: only item 1 evaluated inline, rest queued
    session:set_query("ap") -- previous pass is still partial, so narrowing is unsound
    t.wait(function()
      return not session.match_scheduled
    end)
    -- All four still match "ap"; narrowing from the partial set would drop the
    -- three items the "a" pass had not reached yet.
    t.eq(4, #session.matches)
    for _, m in ipairs(session.matches) do
      t.eq("ap", session.items[m.index].text:sub(1, 2))
    end
  end)

  t.it("restarts query sources with debounce", function()
    local session, source = new_session({ refresh = "query", debounce = 5 })
    t.eq(1, source.started)
    session:set_query("a")
    session:set_query("ab")
    t.eq(1, source.started, "restart must be debounced")
    t.wait(function()
      return source.started == 2
    end)
    t.eq("ab", source.contexts[2].query)
  end)

  t.it("does not re-filter live source output", function()
    local session, source = new_session({ refresh = "query" })
    session:set_query("zzz")
    t.wait(function()
      return source.started == 2
    end)
    source.contexts[2].emit({ { id = 1, text = "does not contain query" } })
    t.eq({ "does not contain query" }, visible_texts(session))
  end)

  t.it("preserves selection and active item across refresh by id", function()
    local session, source = new_session()
    source.contexts[1].emit({
      { id = "a", text = "alpha" },
      { id = "b", text = "beta" },
      { id = "c", text = "gamma" },
    })
    source.contexts[1].finish()
    session:move(1) -- active: b
    session:toggle() -- select b, active: c
    t.eq("c", session.active_id)
    t.eq({ b = true }, session.selected)
    session:refresh()
    source.contexts[2].emit({
      { id = "b", text = "beta" },
      { id = "c", text = "gamma" },
    })
    source.contexts[2].finish()
    t.eq("c", session.active_id)
    t.eq({ "beta" }, vim.tbl_map(function(item)
      return item.text
    end, session:targets()))
  end)

  t.it("falls back to the first match when the active id disappears", function()
    local session, source = new_session()
    source.contexts[1].emit({ { id = "a", text = "apple" }, { id = "b", text = "banana" } })
    source.contexts[1].finish()
    session:move(1)
    t.eq("b", session.active_id)
    session:set_query("app")
    t.eq("a", session.active_id)
  end)

  t.it("moves the cursor to the top on query change even if the active item survives", function()
    local session, source = new_session()
    source.contexts[1].emit({ { id = "a", text = "apple" }, { id = "b", text = "apricot" } })
    source.contexts[1].finish()
    session:move(1)
    t.eq("b", session.active_id)
    session:set_query("ap") -- both items still match
    t.eq("a", session.active_id)
  end)

  t.it("keeps the cursor on the first result across async chunks until navigation", function()
    local session, source = new_session()
    session:set_query("ap")
    source.contexts[1].emit({ { id = "a", text = "xapx" } })
    t.eq("a", session.active_id)
    -- "ap" ranks above "xapx" and sorts to the top; until the user navigates,
    -- async batches should keep the cursor on row 1.
    source.contexts[1].emit({ { id = "b", text = "ap" } })
    t.eq({ "ap", "xapx" }, visible_texts(session))
    t.eq("b", session.active_id)
    t.eq(1, session:active_index())
  end)

  t.it("keeps a navigated cursor stable when later chunks reorder", function()
    local session, source = new_session()
    session:set_query("b")
    -- Neither "xb" nor "yb" matches "b" at a word boundary, so both score the
    -- same and tie-break to emit order.
    source.contexts[1].emit({ { id = "a", text = "xb" }, { id = "b", text = "yb" } })
    session:move(1)
    t.eq("b", session.active_id)
    -- "b" matches at a boundary, outscoring both and jumping to the top.
    source.contexts[1].emit({ { id = "c", text = "b" } })
    t.eq({ "b", "xb", "yb" }, visible_texts(session))
    t.eq("b", session.active_id)
    t.eq(3, session:active_index())
  end)

  t.it("re-anchors the cursor once per query for live sources", function()
    local session, source = new_session({ refresh = "query" })
    source.contexts[1].emit({ { id = "a", text = "one" }, { id = "b", text = "two" } })
    session:move(1)
    t.eq("b", session.active_id)
    session:set_query("x")
    t.wait(function()
      return source.started == 2
    end)
    source.contexts[2].emit({ { id = "c", text = "third" } })
    t.eq("c", session.active_id)
    source.contexts[2].emit({ { id = "d", text = "fourth" } })
    t.eq("c", session.active_id, "later chunks must not move the cursor")
  end)

  t.it("clamps move to the match list", function()
    local session, source = new_session()
    source.contexts[1].emit({ { id = 1, text = "one" }, { id = 2, text = "two" } })
    session:move(-5)
    t.eq(1, session.active_id)
    session:move(99)
    t.eq(2, session.active_id)
  end)

  t.it("toggle_all inverts visible selections", function()
    local session, source = new_session()
    source.contexts[1].emit({ { id = 1, text = "one" }, { id = 2, text = "two" } })
    session:toggle() -- select 1
    session:toggle_all()
    t.eq({ [2] = true }, session.selected)
  end)

  t.it("assigns ids to items without one", function()
    local session, source = new_session()
    source.contexts[1].emit({ { text = "one" }, { text = "two" } })
    t.ok(session.items[1].id ~= nil)
    t.ok(session.items[1].id ~= session.items[2].id)
  end)

  t.it("returns targets in visible order", function()
    local session, source = new_session()
    source.contexts[1].emit({
      { id = 1, text = "xab" },
      { id = 2, text = "ab" }, -- ranks above "xab" for query "ab"
    })
    source.contexts[1].finish()
    session:toggle_all() -- select both
    session:set_query("ab")
    local order = vim.tbl_map(function(item)
      return item.id
    end, session:targets())
    t.eq({ 2, 1 }, order)
  end)

  t.it("excludes selected items that are filtered out from targets", function()
    local session, source = new_session()
    source.contexts[1].emit({ { id = 1, text = "one" }, { id = 2, text = "two" } })
    session:toggle_all()
    session:set_query("one")
    local order = vim.tbl_map(function(item)
      return item.id
    end, session:targets())
    t.eq({ 1 }, order)
  end)

  t.it("runs function actions with a full context", function()
    local session, source = new_session({ cwd = "/tmp" })
    source.contexts[1].emit({ { id = 1, text = "one" } })
    source.contexts[1].finish()
    session:set_query("on")
    local seen
    session:run_action(function(ctx)
      seen = ctx
    end)
    t.eq(1, seen.current.id)
    t.eq({ 1 }, vim.tbl_map(function(item)
      return item.id
    end, seen.targets))
    t.eq("on", seen.query)
    t.eq("/tmp", seen.cwd)
    t.eq(false, session.closed, "actions keep the picker open by default")
    seen.refresh()
    t.eq(2, source.started)
    seen.close()
    t.eq(true, session.closed)
  end)

  t.it("resolves navigation action names", function()
    local session, source = new_session()
    source.contexts[1].emit({ { id = 1, text = "one" }, { id = 2, text = "two" } })
    session:run_action("next")
    t.eq(2, session.active_id)
    session:run_action("previous")
    t.eq(1, session.active_id)
    source.contexts[1].emit({ { id = 3, text = "three" }, { id = 4, text = "four" } })
    session.config.page_size = 2
    session:run_action("page_down")
    t.eq(3, session.active_id)
    session:run_action("page_up")
    t.eq(1, session.active_id)
    session:run_action("toggle")
    t.eq({ [1] = true }, session.selected)
  end)

  t.it("page_down and page_up move by the configured page size", function()
    local session, source = new_session()
    local items = {}
    for i = 1, 10 do
      items[i] = { id = i, text = "item" .. i }
    end
    source.contexts[1].emit(items)
    session.config.page_size = 4
    session:run_action("page_down")
    t.eq(5, session.active_id)
    session:run_action("page_up")
    t.eq(1, session.active_id)
  end)

  t.it("first and last jump to the ends of the match list", function()
    local session, source = new_session()
    source.contexts[1].emit({
      { id = 1, text = "one" },
      { id = 2, text = "two" },
      { id = 3, text = "three" },
    })
    session:run_action("last")
    t.eq(3, session.active_id)
    session:run_action("first")
    t.eq(1, session.active_id)
  end)

  t.it("scroll moves by 'mousescroll' vertical lines, defaulting to 3", function()
    local session, source = new_session()
    local items = {}
    for i = 1, 10 do
      items[i] = { id = i, text = "item" .. i }
    end
    source.contexts[1].emit(items)

    local saved = vim.o.mousescroll
    vim.o.mousescroll = "ver:2,hor:6"
    session:run_action("scroll_down")
    t.eq(3, session.active_id)
    session:run_action("scroll_up")
    t.eq(1, session.active_id)

    vim.o.mousescroll = "hor:6"
    session:run_action("scroll_down")
    t.eq(4, session.active_id, "falls back to 3 lines when 'mousescroll' lacks ver")
    vim.o.mousescroll = saved
  end)

  t.it("close is idempotent and stops the source", function()
    local session, source = new_session()
    local updates = 0
    session.on_update = function()
      updates = updates + 1
    end
    session:close()
    session:close()
    t.eq(true, session.closed)
    t.eq(1, source.stopped)
    t.eq(1, updates)
    -- post-close calls are ignored
    session:set_query("x")
    session:run_action("next")
    t.eq("", session.query)
  end)
end)

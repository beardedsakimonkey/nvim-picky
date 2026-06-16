---@diagnostic disable: missing-fields
local t = require("helpers")
local frecency = require("picky.frecency")

local DAY = 24 * 60 * 60

---A fresh on-disk file plus an isolated store path for one test.
local function fixture()
  local file = vim.fn.tempname()
  vim.fn.writefile({}, file)
  frecency.setup({ enabled = true, path = vim.fn.tempname() })
  return file
end

local function write_raw(path, data)
  local fd = assert(io.open(path, "wb"))
  fd:write(data)
  fd:close()
end

t.describe("frecency", function()
  t.it("scores 0 for unknown or untracked paths", function()
    fixture()
    t.eq(0, frecency.score("/nope/missing.lua", 0))
    t.eq(0, frecency.bonus({ path = "/nope/missing.lua" }))
    t.eq(0, frecency.bonus({}))
  end)

  t.it("raises a file's score and rewards repeated reads", function()
    local a, b = fixture(), vim.fn.tempname()
    vim.fn.writefile({}, b)
    frecency.record_access(a, 1000)
    frecency.record_access(a, 5000) -- second read, spaced beyond the cooldown
    frecency.record_access(b, 1000)
    t.ok(frecency.score(a, 5000) > frecency.score(b, 5000), "twice-read file should outrank once-read")
  end)

  t.it("rate-limits rapid repeat events per channel", function()
    local a, b = fixture(), vim.fn.tempname()
    vim.fn.writefile({}, b)
    frecency.record_access(a, 1000)
    frecency.record_access(a, 1300) -- within the cooldown: ignored
    frecency.record_access(b, 1000)
    t.eq(frecency.score(b, 1000), frecency.score(a, 1000))
    frecency.record_access(a, 5000) -- beyond the cooldown: counts
    t.ok(frecency.score(a, 5000) > frecency.score(b, 5000), "a read past the cooldown raises the score")
  end)

  t.it("decays an old read below a recent one", function()
    local file = fixture()
    frecency.record_access(file, 1000)
    local fresh = frecency.score(file, 1000)
    local aged = frecency.score(file, 1000 + 6 * DAY)
    t.ok(aged < fresh, "score should decay over time")
    t.ok(aged > 0, "score should not vanish entirely")
  end)

  t.it("tracks reads and writes as separate channels", function()
    local file = fixture()
    frecency.record_access(file, 1000)
    local read_only = frecency.score(file, 1000)
    frecency.record_write(file, 1000)
    t.ok(frecency.score(file, 1000) > read_only, "a write adds to the combined score")
  end)

  t.it("produces a bounded, monotonic bonus", function()
    local a, b = fixture(), vim.fn.tempname()
    vim.fn.writefile({}, b)
    -- Several reads spaced beyond the cooldown so they all count; bonus scores
    -- against os.time(), so anchor them near now.
    local base = os.time()
    frecency.record_access(a, base - 2 * 3600)
    frecency.record_access(a, base - 3600)
    frecency.record_access(a, base)
    frecency.record_access(b, base)
    local many, few = frecency.bonus({ path = a }), frecency.bonus({ path = b })
    t.ok(many > few, "more reads earn a larger bonus")
    t.ok(many < 15, "bonus stays bounded below the configured ceiling")
  end)

  t.it("persists across reloads", function()
    -- Use real-clock timestamps so flush's prune does not treat the entry as
    -- ancient relative to os.time().
    local now = os.time()
    local path = vim.fn.tempname()
    local file = vim.fn.tempname()
    vim.fn.writefile({}, file)
    frecency.setup({ enabled = true, path = path })
    frecency.record_access(file, now)
    frecency.flush()
    frecency.setup({ enabled = true, path = path })
    t.ok(frecency.score(file, now) > 0, "score should survive a reload")
  end)

  t.it("starts fresh from a corrupt store without erroring", function()
    local path = vim.fn.tempname()
    write_raw(path, "not mpack \0\1\2")
    frecency.setup({ enabled = true, path = path })
    t.eq(0, frecency.score("/anything", 0))
  end)

  t.it("merges with the on-disk store on flush", function()
    local now = os.time()
    local path = vim.fn.tempname()
    local mine, theirs = vim.fn.tempname(), vim.fn.tempname()
    vim.fn.writefile({}, mine)
    vim.fn.writefile({}, theirs)

    frecency.setup({ enabled = true, path = path })
    frecency.record_access(mine, now)
    -- A concurrent instance writes only its own entry, clobbering the file.
    write_raw(path, vim.mpack.encode({
      version = 1,
      files = { [vim.fs.normalize(theirs)] = { access = { s = 1, t = now } } },
    }))
    frecency.flush()

    frecency.setup({ enabled = true, path = path })
    t.ok(frecency.score(mine, now) > 0, "our entry should survive the merge")
    t.ok(frecency.score(theirs, now) > 0, "the other instance's entry should survive")
  end)

  t.it("records nothing and scores 0 when disabled", function()
    local file = vim.fn.tempname()
    vim.fn.writefile({}, file)
    frecency.setup({ enabled = false, path = vim.fn.tempname() })
    frecency.record_access(file, 1000)
    t.eq(0, frecency.score(file, 1000))
    t.eq(0, frecency.bonus({ path = file }))
  end)
end)

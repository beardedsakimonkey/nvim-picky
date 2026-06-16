---Frecency tracking for file-bearing sources.
---
---Each tracked path carries two exponentially-decaying scores: an "access" score
---bumped when the file is read into or re-displayed in a window (BufReadPost,
---BufWinEnter) and a "write" score bumped on save (BufWritePost). A per-channel
---cooldown ignores rapid repeats, so window flicker and the read+display pair on
---a fresh open count once. Both decay toward zero with a fixed half-life,
---so a file opened often and recently outranks one touched once long ago. The
---combined score becomes a bounded ranking bonus the matcher adds to a file's
---fuzzy score; on an empty query, where all fuzzy scores are equal, it alone
---orders the list (most-used files float to the top).
---
---State is persisted as a single mpack table and merged with whatever is on
---disk on every flush, so concurrent Neovim instances do not clobber each
---other's history.

local M = {}

-- Internal tunables. Half-lives are in seconds; weights scale each channel's
-- contribution to the combined score; the bonus saturates toward MAX_BONUS so
-- frecency nudges ranking without overturning a clearly better text match
-- (MAX_BONUS is sized to roughly one matcher word-boundary bonus). BONUS_SCALE
-- is the combined score at which the bonus reaches half of MAX_BONUS.
local HALF_LIFE = { access = 3 * 24 * 60 * 60, write = 14 * 24 * 60 * 60 }
local WEIGHT = { access = 1.0, write = 0.5 }
local MAX_BONUS = 15
local BONUS_SCALE = 4
local PRUNE_THRESHOLD = 0.05
local FLUSH_DEBOUNCE = 2000
-- Minimum seconds between counted events on the same path/channel. This is NOT
-- what stops high-frequency events (BufWinEnter) from thrashing the ranking --
-- the saturating bonus curve already does that, since scores of 16 and 80 earn
-- near-identical bonuses. The cooldown earns its place for three smaller reasons:
--   1. It dedups the BufReadPost+BufWinEnter pair a single fresh open fires, so
--      an open counts once rather than twice.
--   2. It makes a counted access mean "a distinct working session" (events at least
--      this far apart) rather than "a window displayed this file" -- a cleaner
--      frequency signal.
--   3. It keeps raw scores modest, so a file hammered in one frantic afternoon
--      decays below the prune threshold sooner instead of lingering in the store.
local COOLDOWN = 10 * 60

local CHANNELS = { "access", "write" }

---@class PickyFrecencyEntry
---@field access { s: number, t: number }?
---@field write { s: number, t: number }?

---@class PickyFrecencyStore
---@field version number
---@field files table<string, PickyFrecencyEntry>

local config = { enabled = false, path = nil }
---@type PickyFrecencyStore?
local store
local dirty = false
local timer

---@return number
local function now()
  return os.time()
end

---@return string
local function store_path()
  return config.path or vim.fs.joinpath(vim.fn.stdpath("state"), "picky", "frecency.mpack")
end

---Decayed value of score `s` last updated `dt` seconds ago.
---@param s number
---@param dt number
---@param half_life number
---@return number
local function decay(s, dt, half_life)
  if s == 0 then
    return 0
  end
  if dt <= 0 then
    return s
  end
  return s * 0.5 ^ (dt / half_life)
end

---@return PickyFrecencyStore
local function empty_store()
  return { version = 1, files = {} }
end

---@param data string?
---@return PickyFrecencyStore?
local function decode(data)
  if not data or data == "" then
    return nil
  end
  local ok, decoded = pcall(vim.mpack.decode, data)
  if ok and type(decoded) == "table" and type(decoded.files) == "table" then
    return decoded
  end
  return nil
end

---@param path string
---@return string?
local function read_file(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local data = fd:read("*a")
  fd:close()
  return data
end

---Load the store from disk on first use; a missing or corrupt file starts
---fresh so a bad write never wedges tracking.
---@return PickyFrecencyStore
local function load()
  if not store then
    store = decode(read_file(store_path())) or empty_store()
  end
  return store
end

---Normalize a path to an absolute, on-disk file path, or nil. Used when
---recording events, where statting the file rejects special/scratch buffers.
---@param path string?
---@return string?
local function trackable_path(path)
  if not path or path == "" then
    return nil
  end
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  if not vim.uv.fs_stat(path) then
    return nil
  end
  return path
end

local function schedule_flush()
  if not timer then
    timer = assert(vim.uv.new_timer())
  end
  timer:stop()
  timer:start(FLUSH_DEBOUNCE, 0, function()
    vim.schedule(function()
      if dirty then
        M.flush()
      end
    end)
  end)
end

---@param channel "access"|"write"
---@param path string?
---@param t number?
local function record(channel, path, t)
  if not config.enabled then
    return
  end
  path = trackable_path(path)
  if not path then
    return
  end
  t = t or now()
  local files = load().files
  local entry = files[path]
  if not entry then
    entry = {}
    files[path] = entry
  end
  local c = entry[channel]
  if c then
    if t - c.t < COOLDOWN then
      return
    end
    c.s = decay(c.s, t - c.t, HALF_LIFE[channel]) + 1
    c.t = t
  else
    entry[channel] = { s = 1, t = t }
  end
  dirty = true
  schedule_flush()
end

---@param path string?
---@param t number?
function M.record_access(path, t)
  record("access", path, t)
end

---@param path string?
---@param t number?
function M.record_write(path, t)
  record("write", path, t)
end

---Combined, decayed frecency score for an absolute path (0 when unknown or
---disabled). Cheap: a normalize and a table lookup, no filesystem access.
---@param path string?
---@param t number?
---@return number
function M.score(path, t)
  if not config.enabled or not path or path == "" then
    return 0
  end
  local entry = load().files[vim.fs.normalize(path)]
  if not entry then
    return 0
  end
  t = t or now()
  local total = 0
  for _, channel in ipairs(CHANNELS) do
    local c = entry[channel]
    if c then
      total = total + WEIGHT[channel] * decay(c.s, t - c.t, HALF_LIFE[channel])
    end
  end
  return total
end

---Bounded ranking bonus for an item, suitable to add to a matcher score.
---@param item PickyItem
---@return number
function M.bonus(item)
  local s = M.score(item and item.path)
  if s <= 0 then
    return 0
  end
  return MAX_BONUS * (1 - 0.5 ^ (s / BONUS_SCALE))
end

---Merge two entries for the same path. For each channel the side with the
---later timestamp wins (its score already encapsulates history up to that
---moment); equal timestamps keep the higher score.
---@param a PickyFrecencyEntry?
---@param b PickyFrecencyEntry?
---@return PickyFrecencyEntry
local function merge_entry(a, b)
  local out = {}
  for _, channel in ipairs(CHANNELS) do
    local x = a and a[channel]
    local y = b and b[channel]
    if x and y then
      if y.t > x.t or (y.t == x.t and y.s > x.s) then
        out[channel] = { s = y.s, t = y.t }
      else
        out[channel] = { s = x.s, t = x.t }
      end
    elseif x then
      out[channel] = { s = x.s, t = x.t }
    elseif y then
      out[channel] = { s = y.s, t = y.t }
    end
  end
  return out
end

---Drop channels (and then paths) whose decayed score is negligible, keeping
---the persisted file small and fast to decode.
---@param files table<string, PickyFrecencyEntry>
---@param t number
local function prune(files, t)
  for path, entry in pairs(files) do
    local alive = false
    for _, channel in ipairs(CHANNELS) do
      local c = entry[channel]
      if c then
        if decay(c.s, t - c.t, HALF_LIFE[channel]) >= PRUNE_THRESHOLD then
          alive = true
        else
          entry[channel] = nil
        end
      end
    end
    if not alive then
      files[path] = nil
    end
  end
end

---Persist the in-memory store, merging with the on-disk copy first so a
---concurrent instance's updates survive.
function M.flush()
  if not store then
    return
  end
  local path = store_path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local disk = decode(read_file(path))
  if disk then
    for p, entry in pairs(disk.files) do
      store.files[p] = merge_entry(store.files[p], entry)
    end
  end
  prune(store.files, now())
  local fd = io.open(path, "wb")
  if fd then
    fd:write(vim.mpack.encode(store))
    fd:close()
  end
  dirty = false
end

---@param buf number
---@return boolean
local function trackable_buf(buf)
  return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == ""
end

---Configure tracking. Installs autocmds when enabled; resets in-memory state
---so repeated calls (and tests) start clean.
---@param opts PickyFrecencyConfig|PickyFrecencyConfigOpts|nil
function M.setup(opts)
  opts = opts or {}
  config.enabled = opts.enabled ~= false
  config.path = opts.path
  store = nil
  dirty = false
  if timer then
    timer:stop()
  end

  local group = vim.api.nvim_create_augroup("picky-frecency", { clear = true })
  if not config.enabled then
    return
  end
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
    group = group,
    callback = function(ev)
      if trackable_buf(ev.buf) then
        M.record_access(vim.api.nvim_buf_get_name(ev.buf))
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      if trackable_buf(ev.buf) then
        M.record_write(vim.api.nvim_buf_get_name(ev.buf))
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      if dirty then
        M.flush()
      end
    end,
  })
end

return M

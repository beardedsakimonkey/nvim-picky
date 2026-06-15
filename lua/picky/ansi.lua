---ANSI/SGR escape-sequence parsing for colorized command output.
---
---`parse` strips the escape codes from a line and returns the clean text plus
---a list of color spans keyed to byte offsets in that text. Each distinct SGR
---state is mapped to a cached `PickyAnsi<N>` highlight group, created on demand.
---Colors 0-15 resolve to the user's `g:terminal_color_<n>` when set (so the
---picker tracks the active theme) and fall back to a standard xterm palette.

local M = {}

-- Standard xterm palette for the 16 base colors, used when the matching
-- g:terminal_color_<n> is unset. Index 0 is color 0.
local fallback = {
  [0] = "#000000",
  "#cd0000",
  "#00cd00",
  "#cdcd00",
  "#0000ee",
  "#cd00cd",
  "#00cdcd",
  "#e5e5e5",
  "#7f7f7f",
  "#ff0000",
  "#00ff00",
  "#ffff00",
  "#5c5cff",
  "#ff00ff",
  "#00ffff",
  "#ffffff",
}

---@param n number color index 0-15
---@return string hex
local function base_color(n)
  return vim.g["terminal_color_" .. n] or fallback[n]
end

---Resolve an xterm 256-color index to a hex string.
---@param n number 0-255
---@return string hex
local function xterm256(n)
  if n < 16 then
    return base_color(n)
  end
  if n < 232 then
    n = n - 16
    local r, g, b = math.floor(n / 36), math.floor((n % 36) / 6), n % 6
    local function ch(v)
      return v == 0 and 0 or 55 + 40 * v
    end
    return ("#%02x%02x%02x"):format(ch(r), ch(g), ch(b))
  end
  local v = 8 + 10 * (n - 232)
  return ("#%02x%02x%02x"):format(v, v, v)
end

local function clamp(v)
  return math.max(0, math.min(255, v or 0))
end

-- State -> highlight group cache. Groups persist for the session; a given
-- visual style is created at most once.
local cache = {}
local counter = 0

local function is_default(s)
  return not (s.fg or s.bg or s.bold or s.italic or s.underline or s.reverse or s.strike)
end

---@return string? group name, or nil when the state is the default style
local function group_for(s)
  if is_default(s) then
    return nil
  end
  local key = table.concat({
    s.fg or "",
    s.bg or "",
    s.bold and "b" or "",
    s.italic and "i" or "",
    s.underline and "u" or "",
    s.reverse and "r" or "",
    s.strike and "s" or "",
  }, "|")
  local group = cache[key]
  if group then
    return group
  end
  counter = counter + 1
  group = "PickyAnsi" .. counter
  vim.api.nvim_set_hl(0, group, {
    fg = s.fg,
    bg = s.bg,
    bold = s.bold,
    italic = s.italic,
    underline = s.underline,
    reverse = s.reverse,
    strikethrough = s.strike,
  })
  cache[key] = group
  return group
end

---Read a `38;…`/`48;…` extended-color argument starting at index `k` (the
---38/48 itself). Returns the resolved hex and how many extra params it spanned.
local function read_extended(nums, k)
  local mode = nums[k + 1]
  if mode == 2 then
    return ("#%02x%02x%02x"):format(clamp(nums[k + 2]), clamp(nums[k + 3]), clamp(nums[k + 4])), 4
  elseif mode == 5 then
    return xterm256(clamp(nums[k + 2])), 2
  end
  return nil, 1
end

---Mutate `state` by the parameters of one SGR (`\27[…m`) sequence.
local function apply_sgr(state, params)
  if params == "" then
    params = "0"
  end
  local nums = {}
  for p in (params .. ";"):gmatch("(%-?%d*);") do
    nums[#nums + 1] = tonumber(p) or 0
  end
  local k = 1
  while k <= #nums do
    local c = nums[k]
    if c == 0 then
      state.fg, state.bg = nil, nil
      state.bold, state.italic, state.underline, state.reverse, state.strike = nil, nil, nil, nil, nil
    elseif c == 1 then
      state.bold = true
    elseif c == 3 then
      state.italic = true
    elseif c == 4 then
      state.underline = true
    elseif c == 7 then
      state.reverse = true
    elseif c == 9 then
      state.strike = true
    elseif c == 22 then
      state.bold = nil
    elseif c == 23 then
      state.italic = nil
    elseif c == 24 then
      state.underline = nil
    elseif c == 27 then
      state.reverse = nil
    elseif c == 29 then
      state.strike = nil
    elseif c >= 30 and c <= 37 then
      state.fg = base_color(c - 30)
    elseif c == 38 then
      local color, consumed = read_extended(nums, k)
      state.fg = color
      k = k + consumed
    elseif c == 39 then
      state.fg = nil
    elseif c >= 40 and c <= 47 then
      state.bg = base_color(c - 40)
    elseif c == 48 then
      local color, consumed = read_extended(nums, k)
      state.bg = color
      k = k + consumed
    elseif c == 49 then
      state.bg = nil
    elseif c >= 90 and c <= 97 then
      state.fg = base_color(c - 90 + 8)
    elseif c >= 100 and c <= 107 then
      state.bg = base_color(c - 100 + 8)
    end
    k = k + 1
  end
end

---Strip ANSI escape sequences from `raw`, returning the clean text and the
---color spans over it.
---@param raw string
---@return string text
---@return { from: number, to: number, hl: string }[] highlights 0-based byte offsets, end-exclusive
function M.parse(raw)
  if not raw:find("\27", 1, true) then
    return raw, {}
  end

  local out = {}
  local outlen = 0
  local spans = {}
  local state = {}
  local pending = nil -- group for the current SGR state
  local active = nil -- group currently open
  local active_start = 0

  local function set_group(g)
    if g == active then
      return
    end
    if active then
      spans[#spans + 1] = { from = active_start, to = outlen, hl = active }
    end
    active = g
    active_start = outlen
  end

  local i, n = 1, #raw
  while i <= n do
    local b = raw:byte(i)
    if b == 27 then
      local nb = raw:byte(i + 1)
      if nb == 0x5B then -- CSI: \27[ ... <final 0x40-0x7E>
        local j = i + 2
        while j <= n do
          local c = raw:byte(j)
          if c >= 0x40 and c <= 0x7E then
            break
          end
          j = j + 1
        end
        if raw:byte(j) == 0x6D then -- 'm' -> SGR
          apply_sgr(state, raw:sub(i + 2, j - 1))
          pending = group_for(state)
        end
        i = j + 1
      elseif nb == 0x5D then -- OSC: \27] ... (BEL or ST)
        local j = i + 2
        while j <= n do
          local c = raw:byte(j)
          if c == 7 then
            j = j + 1
            break
          end
          if c == 27 and raw:byte(j + 1) == 0x5C then
            j = j + 2
            break
          end
          j = j + 1
        end
        i = j
      else
        i = i + 1 -- lone ESC or unsupported two-byte sequence
      end
    else
      set_group(pending)
      out[#out + 1] = raw:sub(i, i)
      outlen = outlen + 1
      i = i + 1
    end
  end
  if active then
    spans[#spans + 1] = { from = active_start, to = outlen, hl = active }
  end

  return table.concat(out), spans
end

return M

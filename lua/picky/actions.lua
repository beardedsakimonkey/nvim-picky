---Built-in actions. Opening actions understand the common item fields
---`bufnr`, `tag`, `path`, `commit`, `lnum`/`col` directly, so sources do not
---implement their own completion callbacks.

---@class PickyActions
local M = {}

local buffer_cmds = {
  edit = "buffer %d",
  split = "sbuffer %d",
  vsplit = "vertical sbuffer %d",
  tabedit = "tab sbuffer %d",
}

---@param path string
---@param cwd string?
---@return string
local function resolve_path(path, cwd)
  if path:sub(1, 1) == "/" or path:sub(1, 1) == "~" or path:match("^%a:[/\\]") then
    return vim.fn.expand(path)
  end
  return vim.fs.joinpath(cwd or assert(vim.uv.cwd()), path)
end

---@param item PickyItem
local function jump_to_position(item)
  if not item.lnum then
    return
  end
  local col = math.max((item.col or 1) - 1, 0)
  pcall(vim.api.nvim_win_set_cursor, 0, { item.lnum, col })
end

---Find or create a scratch buffer holding `git show` output for the commit.
---The buffer is looked up by name so reopening a commit reuses it.
---@param commit string
---@param cwd string?
---@return number? bufnr
local function commit_buffer(commit, cwd)
  local name = "picky://git/" .. commit
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 then
    return existing
  end
  local result = vim.system({ "git", "show", commit }, { cwd = cwd, text = true }):wait()
  if result.code ~= 0 then
    local message = (result.stderr or ""):match("^%s*(.-)%s*$")
    vim.notify(("picky: git show %s failed: %s"):format(commit, message), vim.log.levels.ERROR)
    return nil
  end
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, name)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(result.stdout or "", "\n"))
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = "git"
  return bufnr
end

---@param item PickyItem
---@param cmd "edit"|"split"|"vsplit"|"tabedit"
---@param cwd string?
local function open_item(item, cmd, cwd)
  if item.bufnr and vim.api.nvim_buf_is_valid(item.bufnr) then
    vim.cmd(buffer_cmds[cmd]:format(item.bufnr))
  elseif item.tag then
    local by_cmd = {
      edit = "help %s",
      split = "help %s",
      vsplit = "vertical help %s",
      tabedit = "tab help %s",
    }
    vim.cmd(by_cmd[cmd]:format(vim.fn.fnameescape(item.tag)))
  elseif item.commit then
    local bufnr = commit_buffer(item.commit, cwd)
    if not bufnr then
      return
    end
    vim.cmd(buffer_cmds[cmd]:format(bufnr))
  elseif item.path then
    vim.cmd(("%s %s"):format(cmd, vim.fn.fnameescape(resolve_path(item.path, cwd))))
  else
    return
  end
  jump_to_position(item)
end

---@param cmd "edit"|"split"|"vsplit"|"tabedit"
local function opener(cmd)
  ---@param ctx PickyActionContext
  return function(ctx)
    if #ctx.targets == 0 then
      return
    end
    ctx.close()
    for _, item in ipairs(ctx.targets) do
      open_item(item, cmd, ctx.cwd)
    end
  end
end

M.edit = opener("edit")
M.split = opener("split")
M.vsplit = opener("vsplit")
M.tabedit = opener("tabedit")

---@param ctx PickyActionContext
function M.quickfix(ctx)
  local entries = {}
  for _, item in ipairs(ctx.targets) do
    if item.path or item.bufnr then
      entries[#entries + 1] = {
        filename = item.path and resolve_path(item.path, ctx.cwd) or nil,
        bufnr = not item.path and item.bufnr or nil,
        lnum = item.lnum or 1,
        col = item.col or 1,
        end_lnum = item.end_lnum,
        end_col = item.end_col,
        text = item.text or "",
      }
    end
  end
  if #entries == 0 then
    return
  end
  ctx.close()
  vim.fn.setqflist({}, " ", { title = "picky", items = entries })
  vim.cmd("copen")
end

---@param ctx PickyActionContext
function M.close(ctx)
  ctx.close()
end

return M

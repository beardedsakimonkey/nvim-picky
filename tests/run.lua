---Test entry point: `nvim -l tests/run.lua [name-filter]`.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(script, ":p")))

vim.opt.runtimepath:prepend(root)
package.path = ("%s/tests/?.lua;%s"):format(root, package.path)

local helpers = require("helpers")

local specs = vim.fn.glob(root .. "/tests/*_spec.lua", false, true)
table.sort(specs)
for _, spec in ipairs(specs) do
  dofile(spec)
end

local filter = _G.arg and _G.arg[1] or nil
os.exit(helpers.run(filter) and 0 or 1)

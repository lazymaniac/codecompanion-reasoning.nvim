-- Minimal init script for testing the reasoning extension
local root = vim.fn.fnamemodify(debug.getinfo(1).source:match("@(.*)"), ":h:h")
local deps_path = root .. "/deps"

-- Add test dependencies to runtime path
local deps = {
  "plenary.nvim",
  "mini.nvim",
}

for _, dep in ipairs(deps) do
  local dep_path = deps_path .. "/" .. dep
  if vim.fn.isdirectory(dep_path) == 1 then
    vim.opt.runtimepath:append(dep_path)
  end
end

-- Add the extension itself to runtime path
vim.opt.runtimepath:append(root)

-- Load MiniTest
require("mini.test").setup()
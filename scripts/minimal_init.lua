-- Minimal init script for testing the reasoning extension
local root = vim.fn.fnamemodify(debug.getinfo(1).source:match('@(.*)'), ':h:h')
local deps_path = root .. '/deps'

-- Add test dependencies to runtime path
local deps = {
  'plenary.nvim',
  'mini.nvim',
}

for _, dep in ipairs(deps) do
  local dep_path = deps_path .. '/' .. dep
  if vim.fn.isdirectory(dep_path) == 1 then
    vim.opt.runtimepath:append(dep_path)
  end
end

-- Add the extension itself to runtime path
vim.opt.runtimepath:append(root)

-- Add the base CodeCompanion plugin if available (needed for integration hooks)
local cc_path = os.getenv('CODECOMPANION_PATH') or (deps_path .. '/codecompanion.nvim')
if vim.fn.isdirectory(cc_path) == 1 then
  vim.opt.runtimepath:append(cc_path)
  -- Ensure Lua can require CodeCompanion modules directly
  package.path = table.concat({
    cc_path .. '/lua/?.lua',
    cc_path .. '/lua/?/init.lua',
    package.path,
  }, ';')
end

-- Ensure Lua can require project and tests modules directly
package.path = table.concat({
  root .. '/lua/?.lua',
  root .. '/lua/?/init.lua',
  root .. '/tests/?.lua',
  root .. '/tests/?/init.lua',
  package.path,
}, ';')

-- Load MiniTest
local ok, MiniTest = pcall(require, 'mini.test')
if not ok then
  vim.schedule(function()
    vim.api.nvim_err_writeln('[tests] mini.nvim not found. Run `make deps` to fetch test dependencies.')
  end)
else
  -- Configure MiniTest to discover both `test_*.lua` and `*_test.lua` while skipping tmp fixtures
  MiniTest.setup({
    collect = {
      find_files = function()
        local files = {}
        for _, glob in ipairs({ '**/test_*.lua', '**/*_test.lua' }) do
          vim.list_extend(files, vim.fn.globpath('tests', glob, true, true))
        end
        table.sort(files)

        local unique, previous = {}, nil
        for _, file in ipairs(files) do
          if file ~= previous then
            table.insert(unique, file)
            previous = file
          end
        end
        return unique
      end,
    },
    execute = {
      reporter = MiniTest.gen_reporter.stdout(),
    },
  })
end

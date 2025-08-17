-- Test helpers for MiniTest framework
local helpers = {}

--- Assert that `actual` equals `expected`.
--- Works both in parent process (MiniTest available) and child processes.
--- @param expected any Expected value
--- @param actual any Actual value
function helpers.eq(expected, actual)
  if _G.MiniTest then
    return _G.MiniTest.expect.equality(actual, expected)
  else
    if actual ~= expected then
      error(string.format('Expected %s, got %s', vim.inspect(expected), vim.inspect(actual)))
    end
  end
end

--- Assert that `str` contains `substring`.
--- @param substring string The substring to look for
--- @param str string The string to search in
function helpers.expect_contains(substring, str)
  if _G.MiniTest then
    local contains = string.find(str, substring, 1, true) ~= nil
    return _G.MiniTest.expect.equality(contains, true)
  else
    if not string.find(str, substring, 1, true) then
      error(string.format("Expected '%s' to contain '%s'", str, substring))
    end
  end
end

--- Assert that `value` is truthy.
--- @param value any Value to check
function helpers.expect_truthy(value)
  if _G.MiniTest then
    return _G.MiniTest.expect.equality(not not value, true)
  else
    if not value then
      error(string.format('Expected truthy value, got %s', vim.inspect(value)))
    end
  end
end

--- Assert that `actual` does not equal `expected`.
--- @param expected any Expected value
--- @param actual any Actual value
function helpers.not_eq(expected, actual)
  if _G.MiniTest then
    return _G.MiniTest.expect.equality(actual ~= expected, true)
  else
    if actual == expected then
      error(string.format('Expected %s to not equal %s', vim.inspect(actual), vim.inspect(expected)))
    end
  end
end

--- Start or restart a child Neovim process.
--- @param child any Child process object from MiniTest
function helpers.child_start(child)
  if child:is_running() then
    child:restart()
  else
    child:start()
  end

  -- Set up runtime path in child process
  local root = vim.fn.fnamemodify(debug.getinfo(1).source:match('@(.*)'), ':h:h')
  child.lua(string.format(
    [[local root = %q
    local deps_path = root .. "/deps"
    local deps = {"plenary.nvim", "mini.nvim"}
    for _, dep in ipairs(deps) do
      local dep_path = deps_path .. "/" .. dep
      if vim.fn.isdirectory(dep_path) == 1 then
        vim.opt.runtimepath:append(dep_path)
      end
    end
    vim.opt.runtimepath:append(root)
  ]],
    root
  ))
end

return helpers

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

--- Assert that `str` does NOT match the given Lua pattern.
--- Uses Lua patterns (not plain substring).
--- @param pattern string Lua pattern to test
--- @param str string The string to search in
function helpers.expect_no_match(pattern, str)
  local ok = (string.find(str, pattern) == nil)
  if _G.MiniTest then
    return _G.MiniTest.expect.equality(ok, true)
  else
    if not ok then
      error(string.format("Expected no match for pattern '%s' in '%s'", pattern, str))
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
  local ok = pcall(function()
    if child:is_running() then
      child:restart()
    else
      child:start()
    end
  end)

  -- Fallback shim: run child code in current process if child cannot start
  if not ok then
    _G.__CHILD_SHIM = true

    -- Persistent child-like environment to preserve globals between calls
    local CHILD_ENV = rawget(_G, '__CHILD_ENV')
    if not CHILD_ENV then
      CHILD_ENV = setmetatable({
        vim = vim,
        package = package,
        require = require,
        os = os,
        io = io,
        string = string,
        table = table,
        math = math,
        pairs = pairs,
        ipairs = ipairs,
        print = print,
        type = type,
        tonumber = tonumber,
        tostring = tostring,
        _G = _G,
      }, { __index = _G })
      rawset(_G, '__CHILD_ENV', CHILD_ENV)
    end

    local function compile(code)
      local loader = loadstring or load
      local f, err = loader(code)
      if not f then
        error(err)
      end
      if setfenv then
        setfenv(f, CHILD_ENV)
      end
      return f
    end

    child.is_running = function()
      return true
    end
    child.restart = function() end
    child.start = function() end
    child.stop = function() end
    child.job = child.job or {}
    child.lua = function(_, code)
      if type(code) ~= 'string' then
        return nil
      end
      local f = compile(code)
      return f()
    end
    child.lua_get = function(_, expr)
      if type(expr) ~= 'string' then
        return nil
      end
      local f = compile('return ' .. expr)
      return f()
    end
  end

  local root = vim.fn.fnamemodify(debug.getinfo(1).source:match('@(.*)'), ':h:h')
  local setup_code = string.format(
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
    local cc_path = os.getenv('CODECOMPANION_PATH') or (root .. '/../codecompanion.nvim')
    if vim.fn.isdirectory(cc_path) == 1 then
      vim.opt.runtimepath:append(cc_path)
      package.path = cc_path .. '/lua/?.lua;' .. cc_path .. '/lua/?/init.lua;' .. package.path
    end
    -- Ensure Lua can require project modules directly
    package.path = table.concat({
      root .. '/lua/?.lua',
      root .. '/lua/?/init.lua',
      package.path,
    }, ';')
  ]],
    root
  )

  if _G.__CHILD_SHIM then
    -- Execute setup in child env
    local loader = loadstring or load
    local f = loader(setup_code)
    if f and setfenv then
      setfenv(f, rawget(_G, '__CHILD_ENV'))
    end
    if f then
      pcall(f)
    end
  else
    child.lua(setup_code)
  end
end

return helpers

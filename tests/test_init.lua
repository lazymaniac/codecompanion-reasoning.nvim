-- Basic test to verify the extension loads correctly

local MiniTest = require("mini.test")
local expect = MiniTest.expect

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      -- Reset any global state
    end,
  },
})

T["Extension loads"] = function()
  local ok, extension = pcall(require, "codecompanion._extensions.reasoning")
  expect.truthy(ok)
  expect.truthy(extension.setup)
  expect.truthy(extension.exports)
end

T["Main module loads"] = function()
  local ok, main = pcall(require, "codecompanion-reasoning")
  expect.truthy(ok)
  expect.truthy(main.setup)
  expect.truthy(main.get_tools)
end

T["Extension setup returns tools"] = function()
  local extension = require("codecompanion._extensions.reasoning")
  local result = extension.setup()
  expect.truthy(result.tools)
  expect.truthy(result.enabled)
end

return T
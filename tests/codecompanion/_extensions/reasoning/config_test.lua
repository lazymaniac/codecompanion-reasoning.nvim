local Config = require('codecompanion._extensions.reasoning.config')

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T['uses deep, bounded defaults'] = function()
  local options = Config.setup()
  eq(options.auto_attach, false)
  eq(options.default_depth, 'deep')
  eq(options.limits.max_artifacts, 192)
  eq(options.limits.max_batch_items, 8)
  eq(options.limits.max_text_chars, 2000)
  eq(options.limits.max_array_items, 12)
end

T['returns defensive copies'] = function()
  local first = Config.setup()
  first.limits.max_artifacts = 1
  eq(Config.get().limits.max_artifacts, 192)
end

T['rejects invalid values'] = function()
  MiniTest.expect.error(function()
    Config.setup({ default_depth = 'extreme' })
  end, 'default_depth')
  MiniTest.expect.error(function()
    Config.setup({ limits = { max_artifacts = 0 } })
  end, 'max_artifacts')
  MiniTest.expect.error(function()
    Config.setup({ auto_attach = 'yes' })
  end, 'auto_attach')
end

T['rejects unknown options'] = function()
  MiniTest.expect.error(function()
    Config.setup({ session = true })
  end, 'unknown option')
  MiniTest.expect.error(function()
    Config.setup({ limits = { max_nodes = 10 } })
  end, 'unknown limit')
end

return T

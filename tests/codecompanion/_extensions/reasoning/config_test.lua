local Config = require('codecompanion._extensions.reasoning.config')

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      Config.setup()
    end,
    post_case = function()
      Config.setup()
    end,
  },
})
local eq = MiniTest.expect.equality

T['uses deep, bounded defaults'] = function()
  local options = Config.setup()
  eq(options.auto_attach, false)
  eq(options.default_depth, 'deep')
  eq(options.limits.max_artifacts, 320)
  eq(options.limits.max_batch_items, 8)
  eq(options.limits.max_text_chars, 2000)
  eq(options.limits.max_array_items, 12)
  eq(options.limits.max_children, 6)
  eq(options.limits.max_questions, 64)
  eq(options.limits.max_tree_depth, 4)
  eq(options.limits.frontier_items, 12)
  eq(options.strict_atomicity, true)
  eq(options.require_observation_for_closure, true)
  eq(options.judgment_requires_review, true)
end

T['returns defensive copies'] = function()
  local first = Config.setup()
  first.limits.max_artifacts = 1
  eq(Config.get().limits.max_artifacts, 320)
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

T['resets custom options when setup receives no overrides'] = function()
  Config.setup({ default_depth = 'standard', limits = { max_artifacts = 12 } })
  local reset = Config.setup()
  eq(reset.default_depth, 'deep')
  eq(reset.limits.max_artifacts, 320)
end

T['rejects impossible tree bounds transactionally'] = function()
  Config.setup({ limits = { max_children = 4, max_tree_depth = 2, frontier_items = 5 } })
  MiniTest.expect.error(function()
    Config.setup({ limits = { max_children = 1 } })
  end, 'max_children must be at least 2')
  MiniTest.expect.error(function()
    Config.setup({ limits = { max_tree_depth = 0 } })
  end, 'max_tree_depth')
  MiniTest.expect.error(function()
    Config.setup({ limits = { frontier_items = 0 } })
  end, 'frontier_items')
  MiniTest.expect.error(function()
    Config.setup({ limits = { max_questions = 0 } })
  end, 'max_questions')
  local kept = Config.get().limits
  eq(kept.max_children, 4)
  eq(kept.max_tree_depth, 2)
  eq(kept.frontier_items, 5)
end

T['requires boolean closure switches'] = function()
  for _, name in ipairs({ 'strict_atomicity', 'require_observation_for_closure', 'judgment_requires_review' }) do
    MiniTest.expect.error(function()
      Config.setup({ [name] = 'yes' })
    end, name)
  end
  local options = Config.setup({ strict_atomicity = false, judgment_requires_review = false })
  eq(options.strict_atomicity, false)
  eq(options.require_observation_for_closure, true)
  eq(options.judgment_requires_review, false)
end

T['keeps the previous valid configuration after a rejected update'] = function()
  Config.setup({ default_depth = 'standard' })
  MiniTest.expect.error(function()
    Config.setup({ default_depth = 'extreme' })
  end, 'default_depth')
  eq(Config.get().default_depth, 'standard')
end

T['rejects impossible array maxima transactionally'] = function()
  Config.setup({ limits = { max_array_items = 5 } })
  MiniTest.expect.error(function()
    Config.setup({ limits = { max_array_items = 1 } })
  end, 'max_array_items must be at least 2')
  eq(Config.get().limits.max_array_items, 5)
  eq(Config.setup({ limits = { max_array_items = 2 } }).limits.max_array_items, 2)
end

return T

local M = {}

local defaults = {
  auto_attach = false,
  default_depth = 'deep',
  strict_atomicity = true,
  require_observation_for_closure = true,
  judgment_requires_review = true,
  limits = {
    max_artifacts = 320,
    max_batch_items = 8,
    max_text_chars = 2000,
    max_array_items = 12,
    max_children = 6,
    max_questions = 64,
    max_tree_depth = 4,
    frontier_items = 12,
  },
}

local boolean_options = {
  'auto_attach',
  'strict_atomicity',
  'require_observation_for_closure',
  'judgment_requires_review',
}

local limit_minimums = {
  max_children = 2,
  max_array_items = 2,
}

local options = vim.deepcopy(defaults)

local function validate(candidate)
  local allowed_options = { default_depth = true, limits = true }
  for _, name in ipairs(boolean_options) do
    allowed_options[name] = true
  end
  for name in pairs(candidate) do
    if not allowed_options[name] then
      error('unknown option: ' .. name)
    end
  end
  for _, name in ipairs(boolean_options) do
    if type(candidate[name]) ~= 'boolean' then
      error(name .. ' must be a boolean')
    end
  end
  if candidate.default_depth ~= 'standard' and candidate.default_depth ~= 'deep' then
    error("default_depth must be 'standard' or 'deep'")
  end
  if type(candidate.limits) ~= 'table' then
    error('limits must be a table')
  end
  local allowed_limits = {}
  for name in pairs(defaults.limits) do
    allowed_limits[name] = true
  end
  for name, value in pairs(candidate.limits) do
    if not allowed_limits[name] then
      error('unknown limit: ' .. name)
    end
    if type(value) ~= 'number' or value < 1 or value % 1 ~= 0 then
      error(name .. ' must be a positive integer')
    end
    local minimum = limit_minimums[name]
    if minimum and value < minimum then
      error(('%s must be at least %d'):format(name, minimum))
    end
  end
end

function M.setup(user_options)
  local candidate = vim.tbl_deep_extend('force', vim.deepcopy(defaults), user_options or {})
  validate(candidate)
  options = candidate
  return vim.deepcopy(options)
end

function M.get()
  return vim.deepcopy(options)
end

return M

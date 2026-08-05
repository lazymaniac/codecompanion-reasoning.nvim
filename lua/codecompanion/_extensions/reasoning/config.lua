local M = {}

local defaults = {
  auto_attach = false,
  default_depth = 'deep',
  limits = {
    max_artifacts = 192,
    max_batch_items = 8,
    max_text_chars = 2000,
    max_array_items = 12,
  },
}

local options = vim.deepcopy(defaults)

local function validate(candidate)
  local allowed_options = { auto_attach = true, default_depth = true, limits = true }
  for name in pairs(candidate) do
    if not allowed_options[name] then
      error('unknown option: ' .. name)
    end
  end
  if type(candidate.auto_attach) ~= 'boolean' then
    error('auto_attach must be a boolean')
  end
  if candidate.default_depth ~= 'standard' and candidate.default_depth ~= 'deep' then
    error("default_depth must be 'standard' or 'deep'")
  end
  if type(candidate.limits) ~= 'table' then
    error('limits must be a table')
  end
  local allowed_limits = {
    max_artifacts = true,
    max_batch_items = true,
    max_text_chars = true,
    max_array_items = true,
  }
  for name, value in pairs(candidate.limits) do
    if not allowed_limits[name] then
      error('unknown limit: ' .. name)
    end
    if type(value) ~= 'number' or value < 1 or value % 1 ~= 0 then
      error(name .. ' must be a positive integer')
    end
  end
  if candidate.limits.max_array_items < 2 then
    error('max_array_items must be at least 2')
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

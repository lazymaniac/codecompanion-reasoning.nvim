---@class CodeCompanion.ReasoningConfig
---Central configuration management for the reasoning extension.
local Config = {}

---@type table<string, string>
local TOOL_FUNCTIONALITY_MAP = {
  meta_agent = 'meta_agent',
  chain_of_thoughts_agent = 'reasoning_agents',
  tree_of_thoughts_agent = 'reasoning_agents',
  graph_of_thoughts_agent = 'reasoning_agents',
}

---@type table
Config.defaults = {
  chat_history = {
    auto_save = true,
    auto_load_last_session = true,
    auto_generate_title = true,
    sessions_dir = vim.fn.stdpath('data') .. '/codecompanion-reasoning/sessions',
    max_sessions = 100,
    enable_commands = true,
    picker = 'default',
    continue_last_chat = true,
    title_generation_opts = {
      adapter = nil,
      model = nil,
      refresh_every_n_prompts = 3,
      format_title = nil,
    },
    keymaps = {
      rename = { n = 'r', i = '<M-r>' },
      delete = { n = 'd', i = '<M-d>' },
      duplicate = { n = '<C-y>', i = '<C-y>' },
    },
  },
  functionality_adapters = {},
}

Config._options = vim.deepcopy(Config.defaults)
Config._functionality_adapters = {}

---Merge user configuration into defaults and persist the result.
---@param user_opts? table
---@return table merged
function Config.setup(user_opts)
  user_opts = user_opts or {}
  Config._options = vim.tbl_deep_extend('force', vim.deepcopy(Config.defaults), user_opts)
  Config._functionality_adapters = vim.deepcopy(Config._options.functionality_adapters or {})
  return Config._options
end

---Retrieve the last merged configuration.
---@return table config
function Config.get()
  return vim.deepcopy(Config._options)
end

---Retrieve configuration for a specific functionality.
---@param functionality string
---@return table|nil
function Config.get_functionality_adapter(functionality)
  if not functionality or functionality == '' then
    return nil
  end
  local configured = Config._functionality_adapters[functionality]
  if not configured then
    return nil
  end
  return vim.deepcopy(configured)
end

---Merge functionality configuration with caller overrides.
---@param functionality string
---@param overrides? table
---@return table
function Config.merge_with_functionality(functionality, overrides)
  local base = Config.get_functionality_adapter(functionality) or {}
  local merged = vim.deepcopy(base)
  if overrides and next(overrides) then
    merged = vim.tbl_deep_extend('force', merged, overrides)
  end
  return merged
end

---Retrieve mapped functionality for a tool, if any.
---@param tool_name string
---@return string|nil
function Config.get_tool_functionality(tool_name)
  return TOOL_FUNCTIONALITY_MAP[tool_name]
end

---Return adapter configuration associated with a tool.
---@param tool_name string
---@return table|nil
function Config.get_tool_adapter(tool_name)
  local functionality = Config.get_tool_functionality(tool_name)
  if not functionality then
    return nil
  end
  return Config.get_functionality_adapter(functionality)
end

---Reset configuration (primarily for tests).
function Config.reset()
  Config._options = vim.deepcopy(Config.defaults)
  Config._functionality_adapters = {}
end

return Config

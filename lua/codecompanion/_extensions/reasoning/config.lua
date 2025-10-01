---@class CodeCompanion.ReasoningConfig
---Central configuration management for the reasoning extension.
local Config = {}

---@type table
Config.defaults = {
  project_knowledge_initialization = {
    adapter = nil, -- defaults to chat adapter
    model = nil, -- defaults to chat model
  },
  session_optimizer = {
    adapter = nil, -- defaults to chat adapter
    model = nil, -- defaults to chat model
    summary_max_words = 300, -- maximum words in generated summary
    include_code_snippets = true, -- preserve important code examples
  },
  session_title_generator = {
    adapter = nil, -- defaults to chat adapter
    model = nil, -- defaults to chat model
    refresh_every_n_user_prompts = 3,
    max_words_per_title = 6,
    format_title = nil,
  },
  session_history = {
    auto_save = true,
    auto_generate_title = true,
    continue_last_session = false,
    picker = 'default',
    max_sessions = 100,
    sessions_dir = vim.fn.stdpath('data') .. '/codecompanion-reasoning/sessions',
    session_file_pattern = 'session_%Y%m%d_%H%M%S.lua',
    keymaps = {
      rename = { n = 'r', i = '<M-r>' },
      delete = { n = 'd', i = '<M-d>' },
      duplicate = { n = '<C-y>', i = '<C-y>' },
    },
  },
}

Config._options = vim.deepcopy(Config.defaults)

---Merge user configuration into defaults and persist the result.
---@param user_opts? table
---@return table merged
function Config.setup(user_opts)
  user_opts = vim.deepcopy(user_opts or {})
  Config._options = vim.tbl_deep_extend('force', vim.deepcopy(Config.defaults), user_opts)
  return Config._options
end

---Retrieve the last merged configuration.
---@return table config
function Config.get()
  return Config._options
end

return Config

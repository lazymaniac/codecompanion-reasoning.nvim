---@class CodeCompanion.Reasoning.PickerSpec
---@field module string module name to require
---@field condition? function condition function to check if the picker is available

---@type table<string, CodeCompanion.Reasoning.PickerSpec>
local picker_configs = {
  telescope = {
    module = 'telescope',
  },
  ['fzf-lua'] = {
    module = 'fzf-lua',
  },
  snacks = {
    module = 'snacks',
    condition = function(snacks_module)
      -- Snacks can be installed but the Picker is disabled
      return snacks_module
        and snacks_module.config
        and snacks_module.config.picker
        and snacks_module.config.picker.enabled
    end,
  },
}

---Find the first available picker from a list
---@param providers string[] Provider names to check in order
---@param configs table<string, CodeCompanion.Reasoning.PickerSpec> Provider configs
---@param fallback string Fallback provider name
---@return string available_provider The name of an available provider
local function find_available_picker(providers, configs, fallback)
  for _, key in ipairs(providers) do
    local config = configs[key]
    if config then
      local success, loaded_module = pcall(require, config.module)
      if success then
        if config.condition then
          if config.condition(loaded_module) then
            return key
          end
        else
          return key
        end
      end
    end
  end
  return fallback
end

---Get the best available picker for chat history
---@return string resolved_picker_name
local function get_best_history_picker()
  -- Priority order for history pickers
  local providers = { 'telescope', 'fzf-lua', 'snacks' }
  return find_available_picker(providers, picker_configs, 'default')
end

---Get a picker implementation for the given type
---@param picker_type? string Specific picker type, or auto-detect if nil
---@return table picker_implementation
local function get_picker_implementation(picker_type)
  picker_type = picker_type or get_best_history_picker()

  if picker_type == 'default' then
    -- Use the existing session picker as fallback with adapter
    local session_picker = require('codecompanion._extensions.reasoning.ui.session_picker')
    return {
      new = function(config)
        return {
          browse = function()
            session_picker.show_session_picker(function(selected_session)
              if selected_session and config.handlers and config.handlers.on_select then
                config.handlers.on_select(selected_session)
              end
            end)
          end
        }
      end
    }
  end

  -- Try to load the specific picker implementation
  local picker_module = string.format('codecompanion._extensions.reasoning.ui.pickers.%s', picker_type)

  local success, picker = pcall(require, picker_module)
  if success then
    return picker
  end

  -- Fallback to default with adapter
  vim.notify(string.format('Failed to load picker "%s", falling back to default', picker_type), vim.log.levels.WARN)
  local session_picker = require('codecompanion._extensions.reasoning.ui.session_picker')
  return {
    new = function(config)
      return {
        browse = function()
          session_picker.show_session_picker(function(selected_session)
            if selected_session and config.handlers and config.handlers.on_select then
              config.handlers.on_select(selected_session)
            end
          end)
        end
      }
    end
  }
end

return {
  history = get_best_history_picker(),
  get_implementation = get_picker_implementation,
}


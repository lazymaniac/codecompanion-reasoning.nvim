local DEFAULT_PICKER = 'default'
local default_picker = require('codecompanion._extensions.reasoning.ui.pickers.default')

---Get a picker implementation for the given type
---@param picker_type? string Specific picker type (only 'default' is supported)
---@return table picker_implementation
local function get_picker_implementation(picker_type)
  if picker_type == nil or picker_type == 'auto' or picker_type == DEFAULT_PICKER then
    return default_picker
  end

  vim.notify(
    string.format('Picker "%s" is no longer supported; using default picker', picker_type),
    vim.log.levels.WARN
  )
  return default_picker
end

return {
  history = DEFAULT_PICKER,
  get_implementation = get_picker_implementation,
}

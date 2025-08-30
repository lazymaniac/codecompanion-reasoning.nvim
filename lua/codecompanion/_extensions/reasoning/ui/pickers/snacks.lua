---@class CodeCompanion.Reasoning.SnacksPicker : CodeCompanion.Reasoning.DefaultPicker
local SnacksPicker = setmetatable({}, {
  __index = require('codecompanion._extensions.reasoning.ui.pickers.default'),
})
SnacksPicker.__index = SnacksPicker

---Create new Snacks picker instance
---@param config table Configuration for the picker
---@return CodeCompanion.Reasoning.SnacksPicker
function SnacksPicker.new(config)
  local self = setmetatable({}, SnacksPicker)
  self.config = config
  return self
end

---Browse sessions using Snacks
function SnacksPicker:browse()
  -- Check if snacks is available
  local snacks_ok, snacks = pcall(require, 'snacks')
  if not snacks_ok or not snacks.picker then
    vim.notify('Snacks picker not available, falling back to default picker', vim.log.levels.WARN)
    return require('codecompanion._extensions.reasoning.ui.pickers.default').browse(self)
  end

  -- Debug: Check if we have sessions
  if #self.config.items == 0 then
    vim.notify('No sessions found to display in picker', vim.log.levels.WARN)
    return
  end

  -- Create proper table items for snacks picker
  local items = {}
  for i, session in ipairs(self.config.items) do
    local display_title = self:format_entry(session)
    table.insert(items, {
      text = display_title,
      idx = i, -- Store index to map back to session
      session = session, -- Also store session directly for debugging
    })
  end

  -- Debug: Check if items were created
  vim.notify(string.format('Snacks picker: Created %d items', #items), vim.log.levels.INFO)

  -- Use snacks picker with proper structure
  snacks.picker.pick({
    name = 'chat_sessions',
    prompt = self.config.title or 'Chat Sessions',
    items = items,
    format = function(item)
      -- Explicit format function to ensure display
      return item.text or tostring(item)
    end,
    preview = function(item)
      -- Use stored index to get the original session data
      if item and item.idx and self.config.items[item.idx] then
        local session = self.config.items[item.idx]
        local preview_lines = self:get_preview(session)
        return table.concat(preview_lines or {}, '\n')
      end
      return ''
    end,
    confirm = function(item)
      -- Use stored index to get the original session data
      if item and item.idx and self.config.items[item.idx] and self.config.handlers and self.config.handlers.on_select then
        self.config.handlers.on_select(self.config.items[item.idx])
      end
    end,
  })
end

return SnacksPicker
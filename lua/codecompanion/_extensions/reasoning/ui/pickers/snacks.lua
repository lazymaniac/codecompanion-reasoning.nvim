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
  -- Check if Snacks is available (global)
  if not _G.Snacks or not _G.Snacks.picker then
    vim.notify('Snacks picker not available, falling back to default picker', vim.log.levels.WARN)
    return require('codecompanion._extensions.reasoning.ui.pickers.default').browse(self)
  end

  -- Debug: Check if we have sessions
  if #self.config.items == 0 then
    vim.notify('No sessions found to display in picker', vim.log.levels.WARN)
    return
  end

  -- Create items for snacks picker - items should have properties accessible directly
  local items = {}
  for i, session in ipairs(self.config.items) do
    local display_title = self:format_entry(session)
    table.insert(items, {
      title = display_title,
      session = session,
      session_idx = i,
    })
  end

  -- Try the correct snacks picker API
  local success, err = pcall(function()
    return _G.Snacks.picker.pick({
      name = 'chat_sessions',
      items = items,
      format = function(item)
        -- Return formatted text parts with highlight groups
        return {
          { item.title or tostring(item), 'Normal' }
        }
      end,
      preview = function(item)
        if item and item.session then
          local preview_lines = self:get_preview(item.session)
          return preview_lines and table.concat(preview_lines, '\n') or ''
        end
        return ''
      end,
      confirm = function(picker, item)
        picker:close()
        if item and item.session and self.config.handlers and self.config.handlers.on_select then
          self.config.handlers.on_select(item.session)
        end
      end,
    })
  end)

  -- If failed, fall back to default picker
  if not success then
    vim.notify(string.format('Snacks picker failed: %s', tostring(err)), vim.log.levels.WARN)
    vim.notify('Falling back to default picker', vim.log.levels.WARN)
    return require('codecompanion._extensions.reasoning.ui.pickers.default').browse(self)
  end
end

return SnacksPicker

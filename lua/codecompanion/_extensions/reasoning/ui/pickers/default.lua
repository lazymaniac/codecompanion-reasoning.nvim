---@class CodeCompanion.Reasoning.DefaultPicker
---Base class for all session pickers with common functionality
local DefaultPicker = {}
DefaultPicker.__index = DefaultPicker

---Create new picker instance
---@param config table Configuration for the picker
---@return CodeCompanion.Reasoning.DefaultPicker
function DefaultPicker.new(config)
  local self = setmetatable({}, DefaultPicker)
  self.config = config
  return self
end

---Format a session entry for display
---@param session table Session data
---@return string formatted_display
function DefaultPicker:format_entry(session)
  local title = session.title or session.preview or 'Untitled'
  local date_part = session.created_at or 'Unknown date'
  local model_part = session.model or 'Unknown'
  local msg_count = session.total_messages or 0

  -- Extract just the date part if it's a full datetime string
  if date_part:match('%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d') then
    date_part = date_part:sub(1, 10) -- Just YYYY-MM-DD
  end

  return string.format('%s | %s | %s | %d msgs', title, date_part, model_part, msg_count)
end

---Get the display title for an item
---@param item table Item data (session, summary, etc.)
---@return string title
function DefaultPicker:get_item_title(item)
  return item.title or item.preview or 'Untitled'
end

---Get the unique ID for an item
---@param item table Item data
---@return string id
function DefaultPicker:get_item_id(item)
  return item.filename or item.chat_id or item.save_id or 'unknown'
end

---Get the singular name for the item type
---@return string singular_name
function DefaultPicker:get_item_name_singular()
  return 'session'
end

---Browse items using the default picker (session_picker)
function DefaultPicker:browse()
  local SessionPicker = require('codecompanion._extensions.reasoning.ui.session_picker')
  SessionPicker.show_session_picker(function(action, session)
    if action == 'select' and session then
      self.config.handlers.on_select(session)
    elseif action == 'delete' and session then
      self.config.handlers.on_delete({ session })
    end
  end)
end

---Show a preview of the item
---@param item table Item to preview
---@return string[]? preview_lines Lines to show in preview
function DefaultPicker:get_preview(item)
  if not item then
    return { 'No item selected' }
  end

  local lines = {}

  -- Basic information
  table.insert(lines, '# Session Overview')
  table.insert(lines, '')
  table.insert(lines, string.format('**Title:** %s', item.title or 'Untitled'))
  table.insert(lines, string.format('**Created:** %s', item.created_at or 'Unknown'))
  table.insert(lines, string.format('**Model:** %s', item.model or 'Unknown'))
  table.insert(lines, string.format('**Messages:** %d', item.total_messages or 0))

  if item.token_estimate and item.token_estimate > 0 then
    table.insert(lines, string.format('**Tokens (est.):** %d', item.token_estimate))
  end

  if item.project_root then
    table.insert(lines, string.format('**Project:** %s', item.project_root))
  end

  table.insert(lines, '')

  -- Preview content
  if item.preview and item.preview ~= '' then
    table.insert(lines, '## Preview')
    table.insert(lines, '')
    table.insert(lines, item.preview)
  end

  return lines
end

return DefaultPicker

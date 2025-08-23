--- codecompanion-reasoning.lua
--- Reasoning plugin entry point for CodeCompanion.
--- Provides a thin wrapper around the internal reasoning extension.

---@class CodeCompanion.ReasoningPlugin
local M = {}

M.version = '0.1.0'

---@type table|nil
local _extension

--- Load the internal reasoning extension lazily.
--- @return table|nil ext The loaded extension or nil on failure.
local function load_extension()
  if _extension then
    return _extension
  end
  local ok, ext = pcall(require, 'codecompanion._extensions.reasoning')
  if ok then
    _extension = ext
    return _extension
  else
    vim.notify(
      '[codecompanion-reasoning.nvim] Failed to load reasoning extension: ' .. tostring(ext),
      vim.log.levels.ERROR
    )
    return nil
  end
end

--- Setup the CodeCompanion Reasoning extension.
--- This forwards the configuration to the internal extension.
--- @param opts? table Optional configuration table with the following options:
---   - chat_history.auto_save: boolean (default: true) - Enable auto-saving of chat sessions
---   - chat_history.auto_load_last_session: boolean (default: false) - Automatically load the last session on startup
---   - chat_history.sessions_dir: string - Directory to store sessions (default: stdpath('data')/codecompanion-reasoning/sessions)
---   - chat_history.max_sessions: number (default: 100) - Maximum number of sessions to keep
---   - chat_history.enable_commands: boolean (default: true) - Enable user commands
--- @return table|nil config The extension configuration, or nil if loading failed.
function M.setup(opts)
  local ext = load_extension()
  if not ext then
    return nil
  end

  -- Default configuration
  opts = vim.tbl_deep_extend('force', {
    chat_history = {
      auto_save = true,
      auto_load_last_session = false,
      sessions_dir = vim.fn.stdpath('data') .. '/codecompanion-reasoning/sessions',
      max_sessions = 100,
      enable_commands = true,
    },
  }, opts or {})

  return ext.setup(opts)
end

--- Get the list of available reasoning tools.
--- @return table|nil tools Table of tool descriptors, or nil if loading failed.
function M.get_tools()
  local ext = load_extension()
  if not ext then
    return nil
  end
  return ext.exports.get_tools()
end

--- Show the chat history picker UI.
--- @param callback? function Optional callback function (action, session)
function M.show_chat_history(callback)
  local ok, session_picker = pcall(require, 'codecompanion._extensions.reasoning.ui.session_picker')
  if ok then
    session_picker.show_session_picker(callback or function(action, session)
      if action == 'select' and session then
        -- Actually restore the session instead of just showing notification
        local success = M.restore_session(session.filename)
        if success then
          vim.notify(string.format('Restored session: %s', session.created_at), vim.log.levels.INFO)
        else
          vim.notify(string.format('Failed to restore session: %s', session.created_at), vim.log.levels.ERROR)
        end
      end
    end)
  else
    vim.notify('[codecompanion-reasoning.nvim] Failed to load session picker', vim.log.levels.ERROR)
  end
end

--- List all chat sessions.
--- @return table sessions List of session info objects
function M.list_sessions()
  local ok, session_manager = pcall(require, 'codecompanion._extensions.reasoning.helpers.session_manager')
  if ok then
    return session_manager.list_sessions()
  else
    vim.notify('[codecompanion-reasoning.nvim] Failed to load session manager', vim.log.levels.ERROR)
    return {}
  end
end

--- Save a chat session.
--- @param chat table Chat object to save
--- @return boolean success Whether the save was successful
function M.save_session(chat)
  local ok, session_manager = pcall(require, 'codecompanion._extensions.reasoning.helpers.session_manager')
  if ok and chat then
    local success, result = session_manager.save_session(chat)
    if success then
      vim.notify(string.format('Session saved: %s', result), vim.log.levels.INFO)
      return true
    else
      vim.notify(string.format('Failed to save session: %s', result), vim.log.levels.ERROR)
      return false
    end
  end
  return false
end

--- Load and return session data.
--- @param filename string Session filename to load
--- @return table|nil session_data, string|nil error_message
function M.load_session(filename)
  local ok, session_manager = pcall(require, 'codecompanion._extensions.reasoning.helpers.session_manager')
  if ok then
    return session_manager.load_session(filename)
  end
  return nil, 'Failed to load session manager'
end

--- Delete a session.
--- @param filename string Session filename to delete
--- @return boolean success Whether deletion was successful
function M.delete_session(filename)
  local ok, session_manager = pcall(require, 'codecompanion._extensions.reasoning.helpers.session_manager')
  if ok then
    local success, error_msg = session_manager.delete_session(filename)
    if success then
      vim.notify(string.format('Session deleted: %s', filename), vim.log.levels.INFO)
      return true
    else
      vim.notify(string.format('Failed to delete session: %s', error_msg), vim.log.levels.ERROR)
      return false
    end
  end
  return false
end

--- Get the most recent session filename.
--- @return string|nil filename, string|nil error_message
function M.get_last_session()
  local ok, session_manager = pcall(require, 'codecompanion._extensions.reasoning.helpers.session_manager')
  if ok then
    return session_manager.get_last_session()
  end
  return nil, 'Failed to load session manager'
end

--- Restore a session by creating a new CodeCompanion chat with the session messages.
--- @param filename string Session filename to restore
--- @return boolean success Whether restoration was successful
function M.restore_session(filename)
  local ok, session_manager = pcall(require, 'codecompanion._extensions.reasoning.helpers.session_manager')
  if ok then
    local success, error_msg = session_manager.restore_session(filename)
    if not success then
      vim.notify(string.format('Failed to restore session: %s', error_msg), vim.log.levels.ERROR)
      return false
    end
    return true
  else
    vim.notify('[codecompanion-reasoning.nvim] Failed to load session manager', vim.log.levels.ERROR)
    return false
  end
end

--- Automatically load the last session if enabled.
function M.auto_load_last_session()
  local ok, session_manager = pcall(require, 'codecompanion._extensions.reasoning.helpers.session_manager')
  if ok then
    session_manager.auto_load_last_session()
  else
    vim.notify('[codecompanion-reasoning.nvim] Failed to load session manager for auto-load', vim.log.levels.WARN)
  end
end

--- Prevent accidental modification of the public API after initialization.
setmetatable(M, {
  __newindex = function(_, key, _)
    error(string.format("[codecompanion-reasoning.nvim] Attempt to modify read‑only field '%s'", key), 2)
  end,
})

return M

--- codecompanion-reasoning.lua
--- Reasoning plugin entry point for CodeCompanion.
--- Provides a thin wrapper around the internal reasoning extension.

local M = {}

M.version = '0.2.0'

---@type table|nil
local _extension

local Config = require('codecompanion._extensions.reasoning.config')

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
--- @param opts? table Optional configuration table.
--- @return table|nil config The extension configuration, or nil if loading failed.
function M.setup(opts)
  local ext = load_extension()
  if not ext then
    return nil
  end

  local merged = Config.setup(opts)

  return ext.setup(merged)
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
--- @param filter_opts? table Optional filter options {project_root, adapter, date_range}
function M.show_chat_history(filter_opts)
  local ok, ui = pcall(require, 'codecompanion._extensions.reasoning.ui.session_manager_ui')
  if ok then
    local session_ui = ui.new()
    session_ui:browse_sessions(filter_opts)
  else
    vim.notify('[codecompanion-reasoning.nvim] Failed to load session UI', vim.log.levels.ERROR)
  end
end

--- List all chat sessions.
--- @param filter_opts? table Optional filter options {project_root, adapter, date_range}
--- @return table sessions List of session info objects
function M.list_sessions(filter_opts)
  local ok, session_manager = pcall(require, 'codecompanion._extensions.reasoning.helpers.session_manager')
  if ok then
    return session_manager.list_sessions(filter_opts)
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
--- @param opts? table Optional restore options forwarded to the session manager
--- @return boolean success Whether restoration was successful
function M.restore_session(filename, opts)
  local ok, session_manager = pcall(require, 'codecompanion._extensions.reasoning.helpers.session_manager')
  if ok then
    local success, error_msg = session_manager.restore_session(filename, opts)
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

--- Continue the last session if `chat_history.continue_chat` is set to `"last"`.
function M.continue_last_session()
  local ok, session_manager = pcall(require, 'codecompanion._extensions.reasoning.helpers.session_manager')
  if ok then
    session_manager.continue_last_session()
  else
    vim.notify('[codecompanion-reasoning.nvim] Failed to load session manager for auto-load', vim.log.levels.WARN)
  end
end

--- Show sessions for current project only.
function M.show_project_history()
  local ok, ui = pcall(require, 'codecompanion._extensions.reasoning.ui.session_manager_ui')
  if ok then
    local session_ui = ui.new()
    session_ui:browse_project_sessions()
  else
    vim.notify('[codecompanion-reasoning.nvim] Failed to load session UI', vim.log.levels.ERROR)
  end
end

function M.generate_title(chat, callback)
  local ok, ui = pcall(require, 'codecompanion._extensions.reasoning.ui.session_manager_ui')
  if ok and chat then
    local session_ui = ui.new()
    session_ui:generate_title(chat, callback)
  else
    if callback then
      callback(nil)
    end
  end
end

--- Optimize the current chat session by summarizing messages into a single summary.
--- The summary will be placed as a user message right after the system prompt.
function M.optimize_current_session()
  local ok, commands = pcall(require, 'codecompanion._extensions.reasoning.commands')
  if ok and commands.optimize_current_session then
    commands.optimize_current_session()
  else
    vim.notify('[codecompanion-reasoning.nvim] Failed to load session optimizer', vim.log.levels.ERROR)
  end
end

setmetatable(M, {
  __newindex = function(_, key, _)
    error(string.format("[codecompanion-reasoning.nvim] Attempt to modify read‑only field '%s'", key), 2)
  end,
})

return M

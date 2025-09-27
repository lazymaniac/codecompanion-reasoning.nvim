---@class CodeCompanion.Reasoning.SessionManagerUI
---UI manager for chat session management using the default picker
local SessionManagerUI = {}

local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
local TitleGenerator = require('codecompanion._extensions.reasoning.helpers.title_generator')
local pickers = require('codecompanion._extensions.reasoning.ui.pickers')

---Create new session manager UI instance
---@param opts? table Configuration options
---@return CodeCompanion.Reasoning.SessionManagerUI
function SessionManagerUI.new(opts)
  local self = setmetatable({}, { __index = SessionManagerUI })

  self.opts = vim.tbl_deep_extend('force', {
    picker = 'default', -- only 'default' is supported ('auto' falls back for compatibility)
    auto_save = true,
    auto_generate_title = true,
    continue_last_chat = false,
    keymaps = {
      rename = { n = 'r', i = '<M-r>' },
      delete = { n = 'd', i = '<M-d>' },
      duplicate = { n = '<C-y>', i = '<C-y>' },
    },
  }, opts or {})

  -- Initialize title generator
  self.title_generator = TitleGenerator.new({
    auto_generate_title = self.opts.auto_generate_title,
    title_generation_opts = self.opts.title_generation_opts or {},
  })

  return self
end

---Show session browser with the configured picker
---@param filter_opts? table Optional filter options
function SessionManagerUI:browse_sessions(filter_opts)
  local sessions = SessionManager.list_sessions(filter_opts)

  if #sessions == 0 then
    vim.notify('No chat sessions found', vim.log.levels.INFO)
    return
  end

  -- Get the appropriate picker implementation
  local picker_type = self.opts.picker
  if picker_type == 'auto' then
    picker_type = pickers.history
  end

  local picker_impl = pickers.get_implementation(picker_type)

  -- Create picker configuration
  local config = {
    title = 'Chat Sessions',
    items = sessions,
    keymaps = self.opts.keymaps,
    handlers = {
      on_select = function(session)
        self:restore_session(session)
      end,
      on_delete = function(sessions_to_delete)
        self:delete_sessions(sessions_to_delete)
      end,
      on_rename = function(session)
        self:rename_session(session)
      end,
      on_duplicate = function(session)
        self:duplicate_session(session)
      end,
    },
  }

  local picker = picker_impl.new(config)
  picker:browse()
end

---Restore a chat session
---@param session table Session metadata
function SessionManagerUI:restore_session(session)
  local success, result = SessionManager.restore_session(session.filename)
  if success then
    vim.notify(string.format('Restored session: %s', session.title or session.filename), vim.log.levels.INFO)
  else
    vim.notify(string.format('Failed to restore session: %s', result or 'unknown error'), vim.log.levels.ERROR)
  end
end

---Delete multiple sessions with confirmation
---@param sessions_to_delete table[] Array of session metadata
function SessionManagerUI:delete_sessions(sessions_to_delete)
  if not sessions_to_delete or #sessions_to_delete == 0 then
    return
  end

  local count = #sessions_to_delete
  local confirm_msg

  if count == 1 then
    local session = sessions_to_delete[1]
    confirm_msg =
      string.format('Delete session "%s" from %s?', session.title or 'Untitled', session.created_at or 'unknown date')
  else
    confirm_msg = string.format('Delete %d sessions?', count)
  end

  local choice = vim.fn.confirm(confirm_msg, '&Delete\n&Cancel', 2, 'Question')
  if choice == 1 then
    local deleted_count = 0
    local failed_count = 0

    for _, session in ipairs(sessions_to_delete) do
      local success, err = SessionManager.delete_session(session.filename)
      if success then
        deleted_count = deleted_count + 1
      else
        failed_count = failed_count + 1
        vim.notify(
          string.format('Failed to delete session %s: %s', session.filename, err or 'unknown error'),
          vim.log.levels.ERROR
        )
      end
    end

    if deleted_count > 0 then
      local msg = deleted_count == 1 and '✓ Session deleted'
        or string.format('✓ %d sessions deleted', deleted_count)
      vim.notify(msg, vim.log.levels.INFO)
    end

    if failed_count > 0 then
      vim.notify(string.format('✗ %d sessions failed to delete', failed_count), vim.log.levels.ERROR)
    end

    -- Re-show browser after deletion
    vim.schedule(function()
      self:browse_sessions()
    end)
  end
end

---Rename a session
---@param session table Session metadata
function SessionManagerUI:rename_session(session)
  local current_title = session.title or 'Untitled'

  vim.ui.input({
    prompt = 'New title: ',
    default = current_title,
  }, function(new_title)
    if new_title and new_title ~= '' and new_title ~= current_title then
      -- Load the session data
      local session_data, err = SessionManager.load_session(session.filename)
      if not session_data then
        vim.notify(string.format('Failed to load session: %s', err or 'unknown error'), vim.log.levels.ERROR)
        return
      end

      -- Update the title in the session data
      session_data.title = new_title
      session_data.updated_at = os.time()

      -- Save the updated session
      local success, save_err = SessionManager.save_session_data(session_data, session.filename)
      if success then
        vim.notify(string.format('✓ Renamed to "%s"', new_title), vim.log.levels.INFO)
        -- Re-show browser with updated data
        vim.schedule(function()
          self:browse_sessions()
        end)
      else
        vim.notify(string.format('✗ Failed to rename: %s', save_err or 'unknown error'), vim.log.levels.ERROR)
      end
    end
  end)
end

---Duplicate a session
---@param session table Session metadata
function SessionManagerUI:duplicate_session(session)
  -- Load the original session
  local session_data, err = SessionManager.load_session(session.filename)
  if not session_data then
    vim.notify(string.format('Failed to load session: %s', err or 'unknown error'), vim.log.levels.ERROR)
    return
  end

  -- Generate new session data
  local new_title = (session.title or 'Untitled') .. ' (Copy)'
  local new_filename = SessionManager.generate_session_filename()

  -- Update session data for the copy
  session_data.save_id = SessionManager.generate_save_id()
  session_data.title = new_title
  session_data.created_at = os.date('%Y-%m-%d %H:%M:%S')
  session_data.updated_at = os.time()
  session_data.timestamp = os.time()

  -- Reset title refresh count for new session
  if session_data.metadata then
    session_data.metadata.title_refresh_count = 0
  end

  -- Save the duplicated session
  local success, save_err = SessionManager.save_session_data(session_data, new_filename)
  if success then
    vim.notify(string.format('✓ Duplicated as "%s"', new_title), vim.log.levels.INFO)
    -- Re-show browser with new session included
    vim.schedule(function()
      self:browse_sessions()
    end)
  else
    vim.notify(string.format('✗ Failed to duplicate: %s', save_err or 'unknown error'), vim.log.levels.ERROR)
  end
end

---Show sessions for current project only
function SessionManagerUI:browse_project_sessions()
  local project_root = require('codecompanion._extensions.reasoning.helpers.session_manager').find_project_root()
  self:browse_sessions({ project_root = project_root })
end

---Show startup continuation dialog if enabled
function SessionManagerUI:show_startup_dialog()
  if not self.opts.continue_last_chat then
    return
  end

  local sessions = SessionManager.list_sessions()
  if #sessions == 0 then
    return
  end

  -- Get the most recent session
  local last_session = sessions[1]
  if not last_session then
    return
  end

  -- Show simple confirmation dialog
  local title = last_session.title or 'Previous session'
  local msg =
    string.format('Continue with last session: "%s" from %s?', title, last_session.created_at or 'unknown date')

  vim.schedule(function()
    local choice = vim.fn.confirm(msg, '&Continue\n&Browse All\n&New Session', 3, 'Question')
    if choice == 1 then
      -- Continue with last session
      self:restore_session(last_session)
    elseif choice == 2 then
      -- Browse all sessions
      self:browse_sessions()
    end
    -- Choice 3 (New Session) does nothing - user continues normally
  end)
end

---Generate a title for a chat session
---@param chat table CodeCompanion chat object
---@param callback? function Optional callback for async title generation
function SessionManagerUI:generate_title(chat, callback)
  self.title_generator:generate(chat, callback)
end

---Update configuration
---@param new_opts table New options to merge
function SessionManagerUI:update_config(new_opts)
  self.opts = vim.tbl_deep_extend('force', self.opts, new_opts or {})

  -- Update title generator config
  if self.title_generator then
    self.title_generator:setup({
      auto_generate_title = self.opts.auto_generate_title,
      title_generation_opts = self.opts.title_generation_opts or {},
    })
  end
end

return SessionManagerUI

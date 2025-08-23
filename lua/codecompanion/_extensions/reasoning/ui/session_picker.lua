---@class CodeCompanion.UI.SessionPicker
---Interactive session picker UI for selecting and resuming chat sessions
local SessionPicker = {}

local fmt = string.format
local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')

-- UI Configuration
local UI_CONFIG = {
  colors = {
    border = 'FloatBorder',
    title = 'FloatTitle',
    header = 'Function',
    session_title = 'String',
    session_meta = 'Comment',
    session_preview = 'Normal',
    selected = 'CursorLine',
    selected_border = 'CursorLineBg',
    empty_state = 'Comment',
    action_key = 'Special',
    action_text = 'Normal',
  },
  icons = {
    chat = '💬',
    calendar = '📅',
    model = '🤖',
    messages = '📝',
    size = '📊',
    empty = '📭',
    arrow = '▸',
    selected_arrow = '▶',
  },
  border_style = 'rounded',
  max_width_ratio = 0.8,
  max_height_ratio = 0.8,
  min_width = 60,
  min_height = 10,
}

-- Format session metadata for display
---@param session table Session info object
---@return string[] lines, table[] highlights
local function format_session_entry(session, index, is_selected)
  local lines = {}
  local highlights = {}
  local current_line = 0

  local prefix = is_selected and UI_CONFIG.icons.selected_arrow or UI_CONFIG.icons.arrow
  local session_line = fmt(' %s [%d] %s', prefix, index, session.created_at)
  table.insert(lines, session_line)

  -- Highlight the prefix
  table.insert(highlights, {
    line = current_line,
    col = 1,
    end_col = 3,
    group = is_selected and UI_CONFIG.colors.selected or UI_CONFIG.colors.action_key,
  })

  -- Highlight the session title
  table.insert(highlights, {
    line = current_line,
    col = #fmt(' %s [%d] ', prefix, index) + 1,
    end_col = -1,
    group = is_selected and UI_CONFIG.colors.selected or UI_CONFIG.colors.session_title,
  })
  current_line = current_line + 1

  -- Session metadata line
  local meta_line = fmt(
    '    %s %s  %s %d msgs  %s %s',
    UI_CONFIG.icons.model,
    session.model,
    UI_CONFIG.icons.messages,
    session.total_messages,
    UI_CONFIG.icons.size,
    vim.fn.fnamemodify(tostring(session.file_size), ':.')
  )
  table.insert(lines, meta_line)
  table.insert(highlights, {
    line = current_line,
    col = 0,
    end_col = -1,
    group = is_selected and UI_CONFIG.colors.selected or UI_CONFIG.colors.session_meta,
  })
  current_line = current_line + 1

  -- Preview line
  if session.preview and session.preview ~= '' then
    local preview_line = fmt('    "%s"', session.preview)
    table.insert(lines, preview_line)
    table.insert(highlights, {
      line = current_line,
      col = 0,
      end_col = -1,
      group = is_selected and UI_CONFIG.colors.selected or UI_CONFIG.colors.session_preview,
    })
    current_line = current_line + 1
  end

  -- Add spacing between entries
  table.insert(lines, '')
  current_line = current_line + 1

  return lines, highlights
end

-- Build content for the session picker
---@param sessions table[] List of session info objects
---@param selected_index number Currently selected session index
---@return string[] lines, table[] highlights
local function build_session_picker_content(sessions, selected_index)
  local lines = {}
  local highlights = {}
  local line_offset = 0

  -- Header
  table.insert(lines, '')
  table.insert(lines, fmt('  %s Chat Session History', UI_CONFIG.icons.chat))
  table.insert(highlights, {
    line = line_offset + 1,
    col = 2,
    end_col = -1,
    group = UI_CONFIG.colors.header,
  })
  table.insert(lines, '')
  table.insert(lines, '  Select a session to resume:')
  table.insert(highlights, {
    line = line_offset + 3,
    col = 2,
    end_col = -1,
    group = UI_CONFIG.colors.session_meta,
  })
  table.insert(lines, '')
  line_offset = #lines

  if #sessions == 0 then
    -- Empty state
    table.insert(lines, fmt('  %s No chat sessions found', UI_CONFIG.icons.empty))
    table.insert(highlights, {
      line = line_offset,
      col = 2,
      end_col = -1,
      group = UI_CONFIG.colors.empty_state,
    })
    table.insert(lines, '  Start a new conversation to create your first session!')
    table.insert(highlights, {
      line = line_offset + 1,
      col = 2,
      end_col = -1,
      group = UI_CONFIG.colors.empty_state,
    })
  else
    -- Session list
    for i, session in ipairs(sessions) do
      local is_selected = (i == selected_index)
      local session_lines, session_highlights = format_session_entry(session, i, is_selected)

      -- Adjust highlight line numbers to account for offset
      for _, highlight in ipairs(session_highlights) do
        highlight.line = highlight.line + line_offset
        table.insert(highlights, highlight)
      end

      vim.list_extend(lines, session_lines)
      line_offset = #lines
    end
  end

  -- Instructions
  table.insert(lines, '')
  table.insert(lines, '  Controls:')
  table.insert(highlights, {
    line = #lines - 1,
    col = 2,
    end_col = -1,
    group = UI_CONFIG.colors.header,
  })

  local instructions = {
    '  ↑/↓ or j/k - Navigate sessions',
    '  Enter - Resume selected session',
    '  d - Delete selected session',
    '  Esc - Cancel',
  }

  for _, instruction in ipairs(instructions) do
    table.insert(lines, instruction)
    table.insert(highlights, {
      line = #lines - 1,
      col = 2,
      end_col = -1,
      group = UI_CONFIG.colors.action_text,
    })
  end

  return lines, highlights
end

-- Calculate optimal dimensions for session picker
---@param sessions table[] List of sessions
---@return number width, number height
local function calculate_picker_dimensions(sessions)
  local base_height = 10 -- Header + instructions
  local session_height = math.min(#sessions * 4, 20) -- Max 5 sessions visible (4 lines each)
  local total_height = base_height + session_height

  local max_width = math.floor(vim.o.columns * UI_CONFIG.max_width_ratio)
  local max_height = math.floor(vim.o.lines * UI_CONFIG.max_height_ratio)

  local width = math.max(UI_CONFIG.min_width, math.min(max_width, 80))
  local height = math.max(UI_CONFIG.min_height, math.min(max_height, total_height))

  return width, height
end

-- Create session picker window
---@param lines string[] Content lines
---@param highlights table[] Highlight definitions
---@param width number Window width
---@param height number Window height
---@return number buf, number win
local function create_session_picker_window(lines, highlights, width, height)
  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'codecompanion-sessions'
  vim.bo[buf].modifiable = false

  -- Apply highlights
  local ns_id = vim.api.nvim_create_namespace('session_picker')
  for _, hl in ipairs(highlights) do
    local line_count = vim.api.nvim_buf_line_count(buf)
    if hl.line >= 0 and hl.line < line_count then
      local line_content = vim.api.nvim_buf_get_lines(buf, hl.line, hl.line + 1, false)[1] or ''
      local line_len = #line_content

      if line_len > 0 then
        local start_col = math.min(hl.col, line_len - 1)
        local end_col = hl.end_col == -1 and line_len or math.min(hl.end_col, line_len)

        if start_col >= 0 and end_col > start_col then
          vim.api.nvim_buf_set_extmark(buf, ns_id, hl.line, start_col, {
            end_col = end_col,
            hl_group = hl.group,
            strict = false,
          })
        end
      end
    end
  end

  -- Create window
  local win_opts = {
    relative = 'editor',
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = 'minimal',
    border = UI_CONFIG.border_style,
    title = fmt(' %s Session History %s ', UI_CONFIG.icons.chat, UI_CONFIG.icons.calendar),
    title_pos = 'center',
    zindex = 100,
  }

  local win = vim.api.nvim_open_win(buf, true, win_opts)
  vim.wo[win].winhl = 'FloatBorder:' .. UI_CONFIG.colors.border
  vim.wo[win].cursorline = true

  return buf, win
end

-- Set up key mappings for session picker
---@param buf number Buffer handle
---@param sessions table[] Available sessions
---@param selected_index number Currently selected index
---@param callback function Selection callback
local function setup_picker_mappings(buf, sessions, selected_index, callback)
  local current_selection = selected_index

  local function update_display()
    local lines, highlights = build_session_picker_content(sessions, current_selection)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    -- Reapply highlights
    local ns_id = vim.api.nvim_create_namespace('session_picker')
    vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
    for _, hl in ipairs(highlights) do
      local line_count = vim.api.nvim_buf_line_count(buf)
      if hl.line >= 0 and hl.line < line_count then
        local line_content = vim.api.nvim_buf_get_lines(buf, hl.line, hl.line + 1, false)[1] or ''
        local line_len = #line_content

        if line_len > 0 then
          local start_col = math.min(hl.col, line_len - 1)
          local end_col = hl.end_col == -1 and line_len or math.min(hl.end_col, line_len)

          if start_col >= 0 and end_col > start_col then
            vim.api.nvim_buf_set_extmark(buf, ns_id, hl.line, start_col, {
              end_col = end_col,
              hl_group = hl.group,
              strict = false,
            })
          end
        end
      end
    end
  end

  -- Navigation keys
  local navigation_keys = {
    { 'n', '<Up>' },
    { 'n', 'k' },
    { 'i', '<Up>' },
    { 'n', '<Down>' },
    { 'n', 'j' },
    { 'i', '<Down>' },
  }

  for _, key_config in ipairs(navigation_keys) do
    local mode, key = key_config[1], key_config[2]
    local is_up = key:match('Up') or key == 'k'

    vim.api.nvim_buf_set_keymap(buf, mode, key, '', {
      noremap = true,
      silent = true,
      callback = function()
        if #sessions == 0 then
          return
        end

        if is_up then
          current_selection = current_selection > 1 and current_selection - 1 or #sessions
        else
          current_selection = current_selection < #sessions and current_selection + 1 or 1
        end
        update_display()
      end,
    })
  end

  -- Selection keys
  local select_keys = { { 'n', '<CR>' }, { 'i', '<CR>' } }
  for _, key_config in ipairs(select_keys) do
    vim.api.nvim_buf_set_keymap(buf, key_config[1], key_config[2], '', {
      noremap = true,
      silent = true,
      callback = function()
        if #sessions > 0 and current_selection >= 1 and current_selection <= #sessions then
          callback('select', sessions[current_selection])
        else
          callback('cancel')
        end
      end,
    })
  end

  -- Delete key
  vim.api.nvim_buf_set_keymap(buf, 'n', 'd', '', {
    noremap = true,
    silent = true,
    callback = function()
      if #sessions > 0 and current_selection >= 1 and current_selection <= #sessions then
        callback('delete', sessions[current_selection])
      end
    end,
  })

  -- Cancel keys
  local cancel_keys = { { 'n', '<Esc>' }, { 'i', '<Esc>' }, { 'n', 'q' } }
  for _, key_config in ipairs(cancel_keys) do
    vim.api.nvim_buf_set_keymap(buf, key_config[1], key_config[2], '', {
      noremap = true,
      silent = true,
      callback = function()
        callback('cancel')
      end,
    })
  end
end

-- Main API function to show session picker
---@param callback function Callback function (action, session_or_nil)
function SessionPicker.show_session_picker(callback)
  vim.schedule(function()
    local sessions = SessionManager.list_sessions()
    local selected_index = 1

    local width, height = calculate_picker_dimensions(sessions)
    local lines, highlights = build_session_picker_content(sessions, selected_index)

    local buf, win = create_session_picker_window(lines, highlights, width, height)

    -- Set up auto-close and key mappings
    local function close_picker()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end

    local function picker_callback(action, session)
      close_picker()

      if action == 'select' and session then
        callback('select', session)
      elseif action == 'delete' and session then
        -- Confirm deletion
        local confirm_msg = fmt('Delete session "%s"?', session.created_at)
        local choice = vim.fn.confirm(confirm_msg, '&Yes\n&No', 2)
        if choice == 1 then
          local success, err = SessionManager.delete_session(session.filename)
          if success then
            vim.notify(fmt('Deleted session: %s', session.created_at), vim.log.levels.INFO)
          else
            vim.notify(fmt('Failed to delete session: %s', err), vim.log.levels.ERROR)
          end
        end
        -- Re-show picker after deletion
        SessionPicker.show_session_picker(callback)
      else
        callback('cancel')
      end
    end

    setup_picker_mappings(buf, sessions, selected_index, picker_callback)
  end)
end

return SessionPicker

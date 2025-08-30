---@class CodeCompanion.UI.SessionPicker
---Modern split-pane session picker UI for selecting and resuming chat sessions
local SessionPicker = {}

local fmt = string.format
local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')

-- Modern UI Configuration
local UI_CONFIG = {
  colors = {
    -- Main interface colors
    border = 'FloatBorder',
    border_focus = 'DiagnosticInfo',
    title = 'Title',
    subtitle = 'DiagnosticHint',

    -- List pane colors
    list_header = '@text.title',
    list_item = 'Normal',
    list_selected = 'CursorLine',
    list_selected_text = 'CursorLineNr',
    list_meta = '@text.note',
    list_date = '@string.special',
    list_model = '@type',

    -- Preview pane colors
    preview_header = '@text.title',
    preview_label = '@property',
    preview_value = '@string',
    preview_content = 'Normal',
    preview_message_user = '@text.emphasis',
    preview_message_assistant = '@text.strong',
    preview_separator = '@punctuation.delimiter',

    -- Status and accents
    accent_primary = 'DiagnosticInfo',
    accent_secondary = '@constant',
    empty_state = '@text.note',
    action_key = '@keyword',
    action_desc = '@text',
  },

  icons = {
    -- Modern minimalist icons
    session = '●',
    selected = '▸',
    calendar = '',
    model = '',
    messages = '',
    size = '',
    user = '',
    assistant = '🤖',
    empty = '∅',
    preview = '▶',
    separator = '│',
  },

  layout = {
    border_style = 'rounded',
    list_width_ratio = 0.4,
    preview_width_ratio = 0.6,
    max_width_ratio = 0.9,
    max_height_ratio = 0.85,
    min_width = 100,
    min_height = 20,
    padding = 1,
  },

  typography = {
    list_indent = '  ',
    preview_indent = '    ',
    section_spacing = 2,
  },
}

-- Format session entry for the list pane (clean, minimal design)
---@param session table Session info object
---@param index number Session index
---@param is_selected boolean Whether this session is selected
---@return string[] lines, table[] highlights
local function format_session_list_entry(session, index, is_selected)
  local lines = {}
  local highlights = {}

  local indent = UI_CONFIG.typography.list_indent
  local prefix = is_selected and UI_CONFIG.icons.selected or UI_CONFIG.icons.session

  -- Main session line: "▸ Session 1"
  local session_title = fmt('%s%s Session %d', indent, prefix, index)
  table.insert(lines, session_title)

  -- Highlight prefix
  table.insert(highlights, {
    line = 0,
    col = #indent,
    end_col = #indent + #prefix,
    group = is_selected and UI_CONFIG.colors.accent_primary or UI_CONFIG.colors.list_item,
  })

  -- Highlight session title
  table.insert(highlights, {
    line = 0,
    col = #indent + #prefix + 1,
    end_col = -1,
    group = is_selected and UI_CONFIG.colors.list_selected_text or UI_CONFIG.colors.list_item,
  })

  -- Date line (more compact)
  local date_parts = vim.split(session.created_at or '', ' ')
  local date_display = #date_parts >= 2 and (date_parts[1] .. ' ' .. date_parts[2]) or session.created_at
  local date_line = fmt('%s%s %s', indent, UI_CONFIG.icons.calendar, date_display)
  table.insert(lines, date_line)
  table.insert(highlights, {
    line = 1,
    col = 0,
    end_col = -1,
    group = is_selected and UI_CONFIG.colors.list_selected or UI_CONFIG.colors.list_date,
  })

  -- Model and message count (compact)
  local stats_line = fmt(
    '%s%s %s  %s %d',
    indent,
    UI_CONFIG.icons.model,
    session.model,
    UI_CONFIG.icons.messages,
    session.total_messages
  )
  table.insert(lines, stats_line)
  table.insert(highlights, {
    line = 2,
    col = 0,
    end_col = -1,
    group = is_selected and UI_CONFIG.colors.list_selected or UI_CONFIG.colors.list_meta,
  })

  return lines, highlights
end

-- Build detailed preview for the right pane
---@param session table Session info object
---@return string[] lines, table[] highlights
local function build_session_preview(session)
  if not session then
    return { '  No session selected' }, { { line = 0, col = 0, end_col = -1, group = UI_CONFIG.colors.empty_state } }
  end

  local lines = {}
  local highlights = {}
  local line_num = 0

  local function add_line(text, hl_group)
    table.insert(lines, text)
    if hl_group then
      table.insert(highlights, {
        line = line_num,
        col = 0,
        end_col = -1,
        group = hl_group,
      })
    end
    line_num = line_num + 1
  end

  local function add_header(text)
    add_line('', nil)
    add_line('  ' .. text, UI_CONFIG.colors.preview_header)
    add_line('  ' .. string.rep('─', #text), UI_CONFIG.colors.preview_separator)
    line_num = line_num + 1
  end

  local function add_field(label, value, value_hl)
    local field_line = fmt('    %s: %s', label, value)
    table.insert(lines, field_line)
    -- Label highlight
    table.insert(highlights, {
      line = line_num,
      col = 4,
      end_col = 4 + #label,
      group = UI_CONFIG.colors.preview_label,
    })
    -- Value highlight
    table.insert(highlights, {
      line = line_num,
      col = 4 + #label + 2,
      end_col = -1,
      group = value_hl or UI_CONFIG.colors.preview_value,
    })
    line_num = line_num + 1
  end

  -- Session Overview
  add_header('Session Overview')
  add_field('Created', session.created_at or 'Unknown', UI_CONFIG.colors.list_date)
  add_field('Model', session.model or 'Unknown', UI_CONFIG.colors.list_model)
  add_field('Messages', tostring(session.total_messages or 0), UI_CONFIG.colors.accent_secondary)
  add_field('File Size', vim.fn.fnamemodify(tostring(session.file_size or 0), ':.'), UI_CONFIG.colors.list_meta)

  -- Session Preview
  if session.preview and session.preview ~= '' then
    add_header('Session Preview')
    local preview_text = session.preview:gsub('\n', ' ')
    if #preview_text > 200 then
      preview_text = preview_text:sub(1, 197) .. '...'
    end
    local wrapped_lines = {}
    local max_width = 50
    local words = vim.split(preview_text, ' ')
    local current_line = '    '

    for _, word in ipairs(words) do
      if #current_line + #word + 1 > max_width then
        table.insert(wrapped_lines, current_line)
        current_line = '    ' .. word
      else
        current_line = current_line .. ' ' .. word
      end
    end
    if current_line ~= '    ' then
      table.insert(wrapped_lines, current_line)
    end

    for _, line in ipairs(wrapped_lines) do
      add_line(line, UI_CONFIG.colors.preview_content)
    end
  end

  -- Quick Actions
  add_header('Quick Actions')
  add_line('    Enter  Resume session', UI_CONFIG.colors.action_desc)
  add_line('    d      Delete session', UI_CONFIG.colors.action_desc)
  add_line('    Esc    Cancel', UI_CONFIG.colors.action_desc)

  return lines, highlights
end

-- Build content for the session list pane (left side)
---@param sessions table[] List of session info objects
---@param selected_index number Currently selected session index
---@return string[] lines, table[] highlights
local function build_session_list_content(sessions, selected_index)
  local lines = {}
  local highlights = {}
  local line_offset = 0

  -- Header
  table.insert(lines, '')
  table.insert(lines, '  Sessions')
  table.insert(highlights, {
    line = line_offset + 1,
    col = 2,
    end_col = -1,
    group = UI_CONFIG.colors.list_header,
  })
  table.insert(lines, '  ' .. string.rep('─', 15))
  table.insert(highlights, {
    line = line_offset + 2,
    col = 2,
    end_col = -1,
    group = UI_CONFIG.colors.preview_separator,
  })
  table.insert(lines, '')
  line_offset = #lines

  if #sessions == 0 then
    -- Empty state
    table.insert(lines, fmt('  %s No sessions found', UI_CONFIG.icons.empty))
    table.insert(highlights, {
      line = line_offset,
      col = 2,
      end_col = -1,
      group = UI_CONFIG.colors.empty_state,
    })
    table.insert(lines, '  Start a conversation first!')
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
      local session_lines, session_highlights = format_session_list_entry(session, i, is_selected)

      -- Apply selection background
      if is_selected then
        for j = 0, #session_lines - 1 do
          table.insert(highlights, {
            line = line_offset + j,
            col = 0,
            end_col = -1,
            group = UI_CONFIG.colors.list_selected,
          })
        end
      end

      -- Adjust highlight line numbers to account for offset
      for _, highlight in ipairs(session_highlights) do
        highlight.line = highlight.line + line_offset
        table.insert(highlights, highlight)
      end

      vim.list_extend(lines, session_lines)
      table.insert(lines, '') -- spacing between sessions
      line_offset = #lines
    end
  end

  return lines, highlights
end

-- Calculate optimal dimensions for the split-pane layout
---@param sessions table[] List of sessions
---@return table dimensions Layout dimensions
local function calculate_picker_dimensions(sessions)
  local max_width = math.floor(vim.o.columns * UI_CONFIG.layout.max_width_ratio)
  local max_height = math.floor(vim.o.lines * UI_CONFIG.layout.max_height_ratio)

  local total_width = math.max(UI_CONFIG.layout.min_width, math.min(max_width, 120))
  local total_height = math.max(UI_CONFIG.layout.min_height, math.min(max_height, 35))

  local list_width = math.floor(total_width * UI_CONFIG.layout.list_width_ratio) - 1
  local preview_width = total_width - list_width - 1 -- -1 for separator

  return {
    total_width = total_width,
    total_height = total_height,
    list_width = list_width,
    preview_width = preview_width,
    col = math.floor((vim.o.columns - total_width) / 2),
    row = math.floor((vim.o.lines - total_height) / 2),
  }
end

-- Create and apply highlights to a buffer
---@param buf number Buffer handle
---@param highlights table[] Highlight definitions
---@param namespace_suffix string Namespace suffix
local function apply_highlights(buf, highlights, namespace_suffix)
  local ns_id = vim.api.nvim_create_namespace('session_picker_' .. namespace_suffix)
  vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)

  for _, hl in ipairs(highlights) do
    local line_count = vim.api.nvim_buf_line_count(buf)
    if hl.line >= 0 and hl.line < line_count then
      local line_content = vim.api.nvim_buf_get_lines(buf, hl.line, hl.line + 1, false)[1] or ''
      local line_len = #line_content

      if line_len > 0 then
        local start_col = math.max(0, math.min(hl.col, line_len))
        local end_col = hl.end_col == -1 and line_len or math.min(hl.end_col, line_len)

        if start_col < end_col then
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

-- Create the modern split-pane session picker windows
---@param sessions table[] Available sessions
---@param selected_index number Currently selected index
---@param dims table Layout dimensions
---@return table windows Window handles and buffers
local function create_session_picker_windows(sessions, selected_index, dims)
  -- Create list pane (left side)
  local list_buf = vim.api.nvim_create_buf(false, true)
  local list_lines, list_highlights = build_session_list_content(sessions, selected_index)
  vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, list_lines)
  vim.bo[list_buf].bufhidden = 'wipe'
  vim.bo[list_buf].filetype = 'codecompanion-sessions-list'
  vim.bo[list_buf].modifiable = false

  apply_highlights(list_buf, list_highlights, 'list')

  local list_win_opts = {
    relative = 'editor',
    width = dims.list_width,
    height = dims.total_height,
    col = dims.col,
    row = dims.row,
    style = 'minimal',
    border = UI_CONFIG.layout.border_style,
    title = ' Sessions ',
    title_pos = 'left',
    zindex = 100,
  }

  local list_win = vim.api.nvim_open_win(list_buf, true, list_win_opts)
  vim.wo[list_win].winhl = 'FloatBorder:' .. UI_CONFIG.colors.border_focus
  vim.wo[list_win].cursorline = false

  -- Create preview pane (right side)
  local preview_buf = vim.api.nvim_create_buf(false, true)
  local selected_session = sessions[selected_index]
  local preview_lines, preview_highlights = build_session_preview(selected_session)
  vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, preview_lines)
  vim.bo[preview_buf].bufhidden = 'wipe'
  vim.bo[preview_buf].filetype = 'codecompanion-sessions-preview'
  vim.bo[preview_buf].modifiable = false

  apply_highlights(preview_buf, preview_highlights, 'preview')

  local preview_win_opts = {
    relative = 'editor',
    width = dims.preview_width,
    height = dims.total_height,
    col = dims.col + dims.list_width + 1,
    row = dims.row,
    style = 'minimal',
    border = UI_CONFIG.layout.border_style,
    title = ' Preview ',
    title_pos = 'left',
    zindex = 100,
  }

  local preview_win = vim.api.nvim_open_win(preview_buf, false, preview_win_opts)
  vim.wo[preview_win].winhl = 'FloatBorder:' .. UI_CONFIG.colors.border

  return {
    list = { buf = list_buf, win = list_win },
    preview = { buf = preview_buf, win = preview_win },
  }
end

-- Set up key mappings for the modern split-pane picker
---@param windows table Window handles
---@param sessions table[] Available sessions
---@param selected_index number Initially selected index
---@param callback function Selection callback
local function setup_picker_mappings(windows, sessions, selected_index, callback)
  local current_selection = selected_index
  local list_buf = windows.list.buf
  local preview_buf = windows.preview.buf

  local function update_display()
    -- Update list pane
    local list_lines, list_highlights = build_session_list_content(sessions, current_selection)
    vim.bo[list_buf].modifiable = true
    vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, list_lines)
    vim.bo[list_buf].modifiable = false
    apply_highlights(list_buf, list_highlights, 'list')

    -- Update preview pane
    local selected_session = sessions[current_selection]
    local preview_lines, preview_highlights = build_session_preview(selected_session)
    vim.bo[preview_buf].modifiable = true
    vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, preview_lines)
    vim.bo[preview_buf].modifiable = false
    apply_highlights(preview_buf, preview_highlights, 'preview')
  end

  -- Navigation keys (only for list buffer)
  local navigation_keys = {
    { 'n', '<Up>' },
    { 'n', 'k' },
    { 'n', '<Down>' },
    { 'n', 'j' },
  }

  for _, key_config in ipairs(navigation_keys) do
    local mode, key = key_config[1], key_config[2]
    local is_up = key:match('Up') or key == 'k'

    vim.api.nvim_buf_set_keymap(list_buf, mode, key, '', {
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
  local select_keys = { { 'n', '<CR>' }, { 'n', '<Space>' } }
  for _, key_config in ipairs(select_keys) do
    vim.api.nvim_buf_set_keymap(list_buf, key_config[1], key_config[2], '', {
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
  vim.api.nvim_buf_set_keymap(list_buf, 'n', 'd', '', {
    noremap = true,
    silent = true,
    callback = function()
      if #sessions > 0 and current_selection >= 1 and current_selection <= #sessions then
        callback('delete', sessions[current_selection])
      end
    end,
  })

  -- Cancel keys
  local cancel_keys = { { 'n', '<Esc>' }, { 'n', 'q' } }
  for _, key_config in ipairs(cancel_keys) do
    vim.api.nvim_buf_set_keymap(list_buf, key_config[1], key_config[2], '', {
      noremap = true,
      silent = true,
      callback = function()
        callback('cancel')
      end,
    })
  end
end

-- Main API function to show the modern split-pane session picker
---@param callback function Callback function (action, session_or_nil)
function SessionPicker.show_session_picker(callback)
  vim.schedule(function()
    local sessions = SessionManager.list_sessions()
    local selected_index = math.min(1, #sessions)

    local dims = calculate_picker_dimensions(sessions)
    local windows = create_session_picker_windows(sessions, selected_index, dims)

    -- Set up auto-close function
    local function close_picker()
      for _, win_data in pairs(windows) do
        if vim.api.nvim_win_is_valid(win_data.win) then
          vim.api.nvim_win_close(win_data.win, true)
        end
      end
    end

    local function picker_callback(action, session)
      close_picker()

      if action == 'select' and session then
        callback('select', session)
      elseif action == 'delete' and session then
        -- Modern confirmation dialog
        local confirm_msg = fmt('Delete session from %s?', session.created_at or 'unknown date')
        local choice = vim.fn.confirm(confirm_msg, '&Delete\n&Cancel', 2, 'Question')
        if choice == 1 then
          local success, err = SessionManager.delete_session(session.filename)
          if success then
            vim.notify('✓ Session deleted', vim.log.levels.INFO)
          else
            vim.notify('✗ Failed to delete session: ' .. err, vim.log.levels.ERROR)
          end
        end
        -- Re-show picker after deletion attempt
        SessionPicker.show_session_picker(callback)
      else
        callback('cancel')
      end
    end

    setup_picker_mappings(windows, sessions, selected_index, picker_callback)

    -- Focus the list window
    vim.api.nvim_set_current_win(windows.list.win)
  end)
end

return SessionPicker
